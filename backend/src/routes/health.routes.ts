import { Router } from 'express';
import { pool } from '../db/postgres';
import { redis } from '../db/redis';
import { logger } from '../utils/logger';

export const healthRouter = Router();

healthRouter.get('/', async (_req, res) => {
  const checks: Record<string, string> = {};
  let isHealthy = true;

  // PostgreSQL
  try {
    await pool.query('SELECT 1');
    checks['postgres'] = 'ok';
  } catch (err) {
    logger.error({ event: 'health_check_postgres_failed', err });
    checks['postgres'] = 'error';
    isHealthy = false;
  }

  // Redis
  try {
    await redis.ping();
    checks['redis'] = 'ok';
  } catch (err) {
    logger.error({ event: 'health_check_redis_failed', err });
    checks['redis'] = 'error';
    isHealthy = false;
  }

  const status = isHealthy ? 200 : 503;

  res.status(status).json({
    status: isHealthy ? 'healthy' : 'degraded',
    version: process.env['npm_package_version'] ?? '0.1.0',
    uptime: Math.floor(process.uptime()),
    checks,
  });
});
