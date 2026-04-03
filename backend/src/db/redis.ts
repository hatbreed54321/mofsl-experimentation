import Redis from 'ioredis';
import { config } from '../config';
import { logger } from '../utils/logger';

export const redis = new Redis({
  host: config.redisHost,
  port: config.redisPort,
  password: config.redisPassword || undefined,
  lazyConnect: true,
  maxRetriesPerRequest: 3,
  enableReadyCheck: true,
  // Reconnect with exponential backoff, max 10s
  reconnectOnError: () => true,
  retryStrategy: (times) => Math.min(times * 200, 10000),
});

redis.on('connect', () => {
  logger.info({ event: 'redis_connect' }, 'Redis connected');
});

redis.on('error', (err) => {
  logger.error({ event: 'redis_error', err }, 'Redis connection error');
});

redis.on('reconnecting', () => {
  logger.warn({ event: 'redis_reconnecting' }, 'Redis reconnecting');
});

export async function connectRedis(): Promise<void> {
  await redis.connect();
}

export async function closeRedis(): Promise<void> {
  await redis.quit();
}
