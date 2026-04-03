import { RequestHandler } from 'express';
import bcrypt from 'bcrypt';
import { pool } from '../db/postgres';
import { redis } from '../db/redis';
import { UnauthorizedError } from '../utils/errors';
import { logger } from '../utils/logger';

interface ApiKeyRow {
  id: string;
  application_id: string;
  key_hash: string;
  environment: string;
}

interface CachedApiKey {
  id: string;
  applicationId: string;
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

// bcrypt is intentionally slow (~100ms). Calling it on every request at 5K req/s
// would make the config server non-functional. After the first successful bcrypt
// validation, we cache the result in Redis for 5 minutes.
// Cache key: apikey:validated:{key_prefix}  → JSON({ id, applicationId })
const API_KEY_CACHE_TTL = 300; // 5 minutes
const API_KEY_CACHE_PREFIX = 'apikey:validated:';

export const requireApiKey: RequestHandler = async (req, _res, next) => {
  const apiKey = req.headers['x-api-key'];

  if (!apiKey || typeof apiKey !== 'string') {
    return next(new UnauthorizedError('X-API-Key header is required'));
  }

  if (apiKey.length < 12) {
    return next(new UnauthorizedError('Invalid API key format'));
  }

  const keyPrefix = apiKey.slice(0, 12);
  const cacheKey = `${API_KEY_CACHE_PREFIX}${keyPrefix}`;

  try {
    // --- Fast path: Redis cache hit ---
    const cached = await redis.get(cacheKey);
    if (cached) {
      const parsed = JSON.parse(cached) as CachedApiKey;
      req.applicationId = parsed.applicationId;
      req.apiKeyId = parsed.id;
      return next();
    }

    // --- Slow path: DB lookup + bcrypt ---
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

    // Cache the validated result so subsequent requests skip bcrypt
    const cacheValue: CachedApiKey = { id: row.id, applicationId: row.application_id };
    redis
      .set(cacheKey, JSON.stringify(cacheValue), 'EX', API_KEY_CACHE_TTL)
      .catch((err) => logger.warn({ event: 'api_key_cache_set_failed', err }));

    req.applicationId = row.application_id;
    req.apiKeyId = row.id;

    // Update last_used_at (best-effort, debounced naturally by the cache TTL)
    pool
      .query('UPDATE api_keys SET last_used_at = NOW() WHERE id = $1', [row.id])
      .catch((err) =>
        logger.warn({ event: 'api_key_last_used_update_failed', err }),
      );

    return next();
  } catch (err) {
    logger.error({ event: 'api_key_validation_error', err }, 'Error validating API key');
    return next(new UnauthorizedError('Invalid or missing API key'));
  }
};
