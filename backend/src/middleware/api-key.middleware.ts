import { RequestHandler } from 'express';
import bcrypt from 'bcrypt';
import { pool } from '../db/postgres';
import { UnauthorizedError } from '../utils/errors';
import { logger } from '../utils/logger';

interface ApiKeyRow {
  id: string;
  application_id: string;
  key_hash: string;
  environment: string;
}

declare global {
  // eslint-disable-next-line @typescript-eslint/no-namespace
  namespace Express {
    interface Request {
      applicationId?: string;
      apiKeyId?: string;
    }
  }
}

/**
 * API key authentication middleware for SDK-facing routes (config, events).
 *
 * Reads X-API-Key header. Looks up the key_prefix in api_keys table,
 * then bcrypt-compares the full key against the stored hash.
 *
 * Sets req.applicationId and req.apiKeyId on success.
 *
 * Note: bcrypt compare is intentionally slow (~100ms). At high SDK traffic volumes
 * this is cached per key_prefix using a short-lived in-memory TTL (Phase 8 improvement).
 */
export const requireApiKey: RequestHandler = async (req, _res, next) => {
  const apiKey = req.headers['x-api-key'];

  if (!apiKey || typeof apiKey !== 'string') {
    return next(new UnauthorizedError('X-API-Key header is required'));
  }

  if (apiKey.length < 12) {
    return next(new UnauthorizedError('Invalid API key format'));
  }

  // First 12 chars are the prefix stored in plain text
  const keyPrefix = apiKey.slice(0, 12);

  try {
    const result = await pool.query<ApiKeyRow>(
      `SELECT id, application_id, key_hash, environment
       FROM api_keys
       WHERE key_prefix = $1 AND is_active = TRUE`,
      [keyPrefix],
    );

    if (result.rows.length === 0) {
      return next(new UnauthorizedError('Invalid or missing API key'));
    }

    const row = result.rows[0]!;
    const isValid = await bcrypt.compare(apiKey, row.key_hash);

    if (!isValid) {
      return next(new UnauthorizedError('Invalid or missing API key'));
    }

    req.applicationId = row.application_id;
    req.apiKeyId = row.id;

    // Update last_used_at (best-effort, don't block the request)
    pool
      .query('UPDATE api_keys SET last_used_at = NOW() WHERE id = $1', [row.id])
      .catch((err) =>
        logger.warn({ event: 'api_key_last_used_update_failed', err }, 'Failed to update last_used_at'),
      );

    return next();
  } catch (err) {
    logger.error({ event: 'api_key_validation_error', err }, 'Error validating API key');
    return next(new UnauthorizedError('Invalid or missing API key'));
  }
};
