import { Router, Request, Response, NextFunction } from 'express';
import multer from 'multer';

import { pool } from '../db/postgres';
import { redis } from '../db/redis';
import { requireAuth } from '../middleware/auth.middleware';
import { logger } from '../utils/logger';
import { NotFoundError, ValidationError } from '../utils/errors';
import { processUpload } from '../services/upload.service';
import { AuditService } from '../services/audit.service';
import { CacheService } from '../services/cache.service';
import {
  uploadQuerySchema,
  deleteEligibleClientsBodySchema,
  listQuerySchema,
} from '../validators/upload.validator';

export const eligibilityRouter = Router();

// Multer: store file in memory (max 50 MB).
// Files larger than MAX_ROWS rows will be caught in processUpload.
const upload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: 50 * 1024 * 1024 }, // 50 MB
  fileFilter: (_req, file, cb) => {
    const allowed = [
      'text/csv',
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'application/vnd.ms-excel',
      'application/octet-stream', // some browsers send this for .csv
    ];
    if (allowed.includes(file.mimetype) || file.originalname.match(/\.(csv|xlsx|xls)$/i)) {
      cb(null, true);
    } else {
      cb(new ValidationError('Only .csv, .xlsx and .xls files are accepted'));
    }
  },
});

// ------------------------------------------------------------------
// POST /api/v1/experiments/:experimentId/eligible-clients/upload
// Upload a CSV or Excel file of eligible client codes.
// ------------------------------------------------------------------
eligibilityRouter.post(
  '/experiments/:experimentId/eligible-clients/upload',
  requireAuth,
  upload.single('file'),
  async (req: Request, res: Response, next: NextFunction) => {
    try {
      const { experimentId } = req.params;

      if (!req.file) {
        throw new ValidationError('A file must be uploaded as multipart field "file"');
      }

      // Validate query params
      const queryParsed = uploadQuerySchema.safeParse(req.query);
      if (!queryParsed.success) {
        throw new ValidationError('Invalid query parameters', [
          { field: 'mode', message: 'Must be "replace" or "append"' },
        ]);
      }
      const { mode } = queryParsed.data;

      // Verify experiment exists
      const expResult = await pool.query<{ id: string }>(
        'SELECT id FROM experiments WHERE id = $1',
        [experimentId],
      );
      if (expResult.rows.length === 0) {
        throw new NotFoundError('Experiment', experimentId);
      }

      const result = await processUpload({
        experimentId,
        file: {
          buffer: req.file.buffer,
          originalname: req.file.originalname,
          size: req.file.size,
          mimetype: req.file.mimetype,
        },
        userId: req.user?.id ?? null,
        userEmail: req.user?.email ?? null,
        mode,
        db: pool,
        auditService: new AuditService(pool),
        cacheService: new CacheService(redis),
      });

      logger.info(
        {
          event: 'eligible_clients_uploaded',
          experimentId,
          uploadId: result.uploadId,
          validRows: result.validRows,
          actor: req.user?.email,
        },
        'Eligible clients upload completed',
      );

      res.status(201).json({
        uploadId: result.uploadId,
        totalRows: result.totalRows,
        validRows: result.validRows,
        duplicateRows: result.duplicateRows,
        invalidRows: result.invalidRows,
        s3Key: result.s3Key,
        mode,
      });
    } catch (err) {
      next(err);
    }
  },
);

// ------------------------------------------------------------------
// GET /api/v1/experiments/:experimentId/eligible-clients
// List upload batches (not individual client codes) with pagination.
// ------------------------------------------------------------------
eligibilityRouter.get(
  '/experiments/:experimentId/eligible-clients',
  requireAuth,
  async (req: Request, res: Response, next: NextFunction) => {
    try {
      const { experimentId } = req.params;

      const queryParsed = listQuerySchema.safeParse(req.query);
      if (!queryParsed.success) {
        throw new ValidationError('Invalid query parameters');
      }
      const { cursor, limit } = queryParsed.data;

      // Verify experiment exists
      const expResult = await pool.query<{ id: string }>(
        'SELECT id FROM experiments WHERE id = $1',
        [experimentId],
      );
      if (expResult.rows.length === 0) {
        throw new NotFoundError('Experiment', experimentId);
      }

      // Cursor-based pagination on uploads
      const rows = await pool.query<{
        id: string;
        file_name: string;
        file_size_bytes: string;
        total_rows: number;
        valid_rows: number;
        duplicate_rows: number;
        invalid_rows: number;
        status: string;
        error_message: string | null;
        uploaded_by: string | null;
        created_at: Date;
        completed_at: Date | null;
      }>(
        `SELECT id, file_name, file_size_bytes, total_rows, valid_rows,
                duplicate_rows, invalid_rows, status, error_message,
                uploaded_by, created_at, completed_at
         FROM client_list_uploads
         WHERE experiment_id = $1
           ${cursor ? 'AND id < $3' : ''}
         ORDER BY created_at DESC
         LIMIT $2`,
        cursor ? [experimentId, limit + 1, cursor] : [experimentId, limit + 1],
      );

      const hasMore = rows.rows.length > limit;
      const items = hasMore ? rows.rows.slice(0, limit) : rows.rows;
      const nextCursor = hasMore ? items[items.length - 1]?.id : undefined;

      // Also return total eligible client count for this experiment
      const countResult = await pool.query<{ count: string }>(
        'SELECT COUNT(*) AS count FROM eligible_clients WHERE experiment_id = $1',
        [experimentId],
      );
      const totalEligibleClients = parseInt(countResult.rows[0]?.count ?? '0', 10);

      res.json({
        uploads: items,
        totalEligibleClients,
        pagination: {
          hasMore,
          nextCursor: nextCursor ?? null,
          limit,
        },
      });
    } catch (err) {
      next(err);
    }
  },
);

// ------------------------------------------------------------------
// DELETE /api/v1/experiments/:experimentId/eligible-clients
// Remove eligible clients for an experiment.
// Pass { uploadBatchId } to remove a specific batch, or omit to clear all.
// ------------------------------------------------------------------
eligibilityRouter.delete(
  '/experiments/:experimentId/eligible-clients',
  requireAuth,
  async (req: Request, res: Response, next: NextFunction) => {
    try {
      const { experimentId } = req.params;

      const bodyParsed = deleteEligibleClientsBodySchema.safeParse(req.body);
      if (!bodyParsed.success) {
        throw new ValidationError('Invalid request body');
      }
      const { uploadBatchId } = bodyParsed.data;

      // Verify experiment exists
      const expResult = await pool.query<{ id: string }>(
        'SELECT id FROM experiments WHERE id = $1',
        [experimentId],
      );
      if (expResult.rows.length === 0) {
        throw new NotFoundError('Experiment', experimentId);
      }

      let deletedCount: number;

      if (uploadBatchId) {
        const result = await pool.query(
          'DELETE FROM eligible_clients WHERE experiment_id = $1 AND upload_batch_id = $2',
          [experimentId, uploadBatchId],
        );
        deletedCount = result.rowCount ?? 0;

        // Mark the upload record as deleted
        await pool.query(
          `UPDATE client_list_uploads SET status = 'failed', error_message = 'Deleted by user'
           WHERE id = $1`,
          [uploadBatchId],
        );
      } else {
        const result = await pool.query(
          'DELETE FROM eligible_clients WHERE experiment_id = $1',
          [experimentId],
        );
        deletedCount = result.rowCount ?? 0;
      }

      // Audit log
      const auditService = new AuditService(pool);
      await auditService.log({
        entityType: 'eligible_clients',
        entityId: experimentId,
        action: 'deleted',
        metadata: { uploadBatchId: uploadBatchId ?? 'all', deletedCount },
        actorId: req.user?.id,
        actorEmail: req.user?.email,
      });

      // Invalidate config cache
      const cacheService = new CacheService(redis);
      await cacheService.invalidateConfigsForExperiment(experimentId);

      logger.info(
        {
          event: 'eligible_clients_deleted',
          experimentId,
          uploadBatchId: uploadBatchId ?? 'all',
          deletedCount,
          actor: req.user?.email,
        },
        'Eligible clients deleted',
      );

      res.json({ deletedCount });
    } catch (err) {
      next(err);
    }
  },
);
