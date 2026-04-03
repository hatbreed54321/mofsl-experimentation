import path from 'path';
import { v4 as uuidv4 } from 'uuid';
import { parse as parseCsvBuffer } from 'csv-parse/sync';
import * as XLSX from 'xlsx';
import { Pool, PoolClient } from 'pg';

import { uploadToS3 } from '../utils/s3';
import { logger } from '../utils/logger';
import { AppError, PayloadTooLargeError, ValidationError } from '../utils/errors';
import { AuditService } from './audit.service';
import { CacheService } from './cache.service';
import { UploadResult } from '../models/eligible-client.model';

const MAX_ROWS = 1_000_000;
const BATCH_SIZE = 5_000;

// ------------------------------------------------------------------
// Parsing
// ------------------------------------------------------------------

/**
 * Parse a CSV or Excel file buffer into a flat list of raw client code strings.
 * Only the first column is read. Header row is auto-detected and skipped.
 * BOM is stripped automatically by csv-parse.
 */
export function parseFile(buffer: Buffer, filename: string): string[] {
  const ext = path.extname(filename).toLowerCase();

  if (ext === '.csv') {
    return parseCsvFile(buffer);
  }

  if (ext === '.xlsx' || ext === '.xls') {
    return parseExcelFile(buffer);
  }

  throw new AppError(400, 'unsupported_format', 'Only .csv, .xlsx and .xls files are supported');
}

function parseCsvFile(buffer: Buffer): string[] {
  let records: string[][];
  try {
    records = parseCsvBuffer(buffer, {
      skip_empty_lines: true,
      trim: true,
      bom: true, // strip byte-order mark
      relax_column_count: true,
    }) as string[][];
  } catch {
    throw new AppError(400, 'parse_error', 'Unable to parse CSV file — check file format');
  }

  if (records.length === 0) {
    throw new ValidationError('File is empty');
  }

  // If the first value looks like a header (non-alphanumeric), skip it
  const allRows = records.map((row) => String(row[0] ?? '').trim());
  const firstValue = allRows[0] ?? '';
  const isHeader = firstValue !== '' && !/^[A-Za-z0-9]{1,50}$/.test(firstValue);

  return isHeader ? allRows.slice(1) : allRows;
}

function parseExcelFile(buffer: Buffer): string[] {
  let workbook: XLSX.WorkBook;
  try {
    workbook = XLSX.read(buffer, { type: 'buffer' });
  } catch {
    throw new AppError(400, 'parse_error', 'Unable to parse Excel file — file may be corrupt');
  }

  const sheetName = workbook.SheetNames[0];
  if (!sheetName) {
    throw new ValidationError('Excel file has no sheets');
  }

  const sheet = workbook.Sheets[sheetName];
  if (!sheet) {
    throw new ValidationError('Excel sheet is empty');
  }

  // Convert first column to array of strings
  const rows: unknown[][] = XLSX.utils.sheet_to_json(sheet, { header: 1, defval: '' });

  if (rows.length === 0) {
    throw new ValidationError('File is empty');
  }

  const allValues = rows.map((row) => String(row[0] ?? '').trim());

  // Skip header if first row looks like a label
  const firstValue = allValues[0] ?? '';
  const isHeader = firstValue !== '' && !/^[A-Za-z0-9]{1,50}$/.test(firstValue);

  return isHeader ? allValues.slice(1) : allValues;
}

// ------------------------------------------------------------------
// Validation
// ------------------------------------------------------------------

export interface ValidationResult {
  valid: string[];
  duplicates: string[];
  invalid: string[];
}

const CLIENT_CODE_REGEX = /^[A-Za-z0-9]{1,50}$/;

/**
 * Validate a list of raw client code strings.
 * Rules:
 * - Must be 1–50 alphanumeric characters
 * - Empty strings are silently skipped
 * - Duplicate codes within the file are collected separately
 */
export function validateClientCodes(rawCodes: string[]): ValidationResult {
  const valid: string[] = [];
  const duplicates: string[] = [];
  const invalid: string[] = [];
  const seen = new Set<string>();

  for (const rawCode of rawCodes) {
    const code = rawCode.trim();

    // Skip blank rows silently
    if (code === '') continue;

    if (!CLIENT_CODE_REGEX.test(code)) {
      invalid.push(code);
      continue;
    }

    if (seen.has(code.toUpperCase())) {
      duplicates.push(code);
      continue;
    }

    seen.add(code.toUpperCase());
    valid.push(code);
  }

  return { valid, duplicates, invalid };
}

// ------------------------------------------------------------------
// Bulk insert
// ------------------------------------------------------------------

/**
 * Insert client codes into eligible_clients in batches of BATCH_SIZE.
 * Uses ON CONFLICT DO NOTHING — duplicate codes already in the DB are silently skipped.
 * This means re-running the same upload is safe.
 */
async function bulkInsertEligibleClients(
  client: PoolClient,
  experimentId: string,
  uploadBatchId: string,
  clientCodes: string[],
): Promise<void> {
  for (let i = 0; i < clientCodes.length; i += BATCH_SIZE) {
    const batch = clientCodes.slice(i, i + BATCH_SIZE);

    // Build parameterised VALUES list: ($1,$2,$3), ($4,$5,$6), ...
    const valuePlaceholders = batch
      .map((_, idx) => {
        const base = idx * 4;
        return `($${base + 1}, $${base + 2}, $${base + 3}, $${base + 4})`;
      })
      .join(', ');

    const params = batch.flatMap((code) => [uuidv4(), experimentId, code, uploadBatchId]);

    await client.query(
      `INSERT INTO eligible_clients (id, experiment_id, client_code, upload_batch_id)
       VALUES ${valuePlaceholders}
       ON CONFLICT (experiment_id, client_code) DO NOTHING`,
      params,
    );

    logger.debug(
      { event: 'bulk_insert_batch', experimentId, batchSize: batch.length, offset: i },
      'Eligible clients batch inserted',
    );
  }
}

// ------------------------------------------------------------------
// Upload orchestration
// ------------------------------------------------------------------

export interface ProcessUploadOptions {
  experimentId: string;
  file: { buffer: Buffer; originalname: string; size: number; mimetype: string };
  userId: string | null;
  userEmail: string | null;
  mode: 'replace' | 'append';
  db: Pool;
  auditService: AuditService;
  cacheService: CacheService;
}

export async function processUpload(options: ProcessUploadOptions): Promise<UploadResult> {
  const { experimentId, file, userId, userEmail, mode, db, auditService, cacheService } = options;

  logger.info(
    { event: 'upload_started', experimentId, fileName: file.originalname, mode },
    'Processing client list upload',
  );

  // --- Size gate before any processing ---
  const rawCodes = parseFile(file.buffer, file.originalname);

  if (rawCodes.length > MAX_ROWS) {
    throw new PayloadTooLargeError(
      `File exceeds the maximum of ${MAX_ROWS.toLocaleString()} rows (got ${rawCodes.length.toLocaleString()})`,
    );
  }

  const { valid, duplicates, invalid } = validateClientCodes(rawCodes);

  if (valid.length === 0) {
    throw new ValidationError(
      `No valid client codes found in file. ` +
        `${invalid.length} invalid, ${duplicates.length} duplicate rows.`,
    );
  }

  // --- S3 upload (audit trail) ---
  const s3Key = `uploads/${experimentId}/${Date.now()}_${file.originalname}`;
  await uploadToS3(s3Key, file.buffer, file.mimetype);

  logger.info(
    { event: 'upload_s3_stored', experimentId, s3Key },
    'Raw upload file stored in S3',
  );

  // --- Transactional DB writes ---
  const uploadBatchId = uuidv4();

  const result = await runInTransaction(db, async (client) => {
    // Record upload metadata
    await client.query(
      `INSERT INTO client_list_uploads
         (id, experiment_id, file_name, file_size_bytes, s3_key,
          total_rows, valid_rows, duplicate_rows, invalid_rows,
          status, uploaded_by)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, 'processing', $10)`,
      [
        uploadBatchId,
        experimentId,
        file.originalname,
        file.size,
        s3Key,
        rawCodes.length,
        valid.length,
        duplicates.length,
        invalid.length,
        userId,
      ],
    );

    // If replace mode, delete the existing eligibility list first
    if (mode === 'replace') {
      const deleted = await client.query(
        'DELETE FROM eligible_clients WHERE experiment_id = $1',
        [experimentId],
      );
      logger.info(
        { event: 'eligibility_list_cleared', experimentId, deletedRows: deleted.rowCount },
        'Existing eligibility list cleared for replace upload',
      );
    }

    // Bulk insert valid codes
    await bulkInsertEligibleClients(client, experimentId, uploadBatchId, valid);

    // Mark upload as completed
    await client.query(
      `UPDATE client_list_uploads
       SET status = 'completed', completed_at = NOW()
       WHERE id = $1`,
      [uploadBatchId],
    );

    return {
      uploadId: uploadBatchId,
      totalRows: rawCodes.length,
      validRows: valid.length,
      duplicateRows: duplicates.length,
      invalidRows: invalid.length,
      s3Key,
    } satisfies UploadResult;
  });

  // --- Audit log ---
  await auditService.log({
    entityType: 'eligible_clients',
    entityId: experimentId,
    action: 'uploaded',
    metadata: {
      uploadId: uploadBatchId,
      mode,
      fileName: file.originalname,
      s3Key,
      totalRows: result.totalRows,
      validRows: result.validRows,
      duplicateRows: result.duplicateRows,
      invalidRows: result.invalidRows,
    },
    actorId: userId ?? undefined,
    actorEmail: userEmail ?? undefined,
  });

  // --- Invalidate config cache (eligibility changed) ---
  await cacheService.invalidateConfigsForExperiment(experimentId);

  logger.info(
    { event: 'upload_completed', experimentId, uploadId: uploadBatchId, validRows: result.validRows },
    'Client list upload completed',
  );

  return result;
}

// ------------------------------------------------------------------
// Helpers
// ------------------------------------------------------------------

async function runInTransaction<T>(db: Pool, fn: (client: PoolClient) => Promise<T>): Promise<T> {
  const client = await db.connect();
  try {
    await client.query('BEGIN');
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (err) {
    await client.query('ROLLBACK');
    throw err;
  } finally {
    client.release();
  }
}
