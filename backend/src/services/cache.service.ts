import { Redis } from 'ioredis';
import { logger } from '../utils/logger';

// Redis key constants — centralised to prevent key collisions
const CONFIG_KEY = (clientCode: string) => `config:v1:${clientCode}`;
const CONFIG_VERSION_KEY = (applicationId: string) => `config:version:${applicationId}`;
const IDEMPOTENCY_KEY = (key: string) => `idemp:${key}`;

const CONFIG_TTL_SECONDS = 300; // 5 minutes
const IDEMPOTENCY_TTL_SECONDS = 86400; // 24 hours

/**
 * CacheService — Redis cache operations for config serving and idempotency.
 *
 * Rules from backend/CLAUDE.md:
 * - Always use SET ... EX (never SET + separate EXPIRE)
 * - Never cache in Node.js process memory — use Redis
 */
export class CacheService {
  constructor(private readonly redis: Redis) {}

  // ------------------------------------------------------------------
  // Config cache
  // ------------------------------------------------------------------

  async getConfig(clientCode: string): Promise<string | null> {
    return this.redis.get(CONFIG_KEY(clientCode));
  }

  async setConfig(clientCode: string, payload: string): Promise<void> {
    await this.redis.set(CONFIG_KEY(clientCode), payload, 'EX', CONFIG_TTL_SECONDS);
  }

  async invalidateConfig(clientCode: string): Promise<void> {
    await this.redis.del(CONFIG_KEY(clientCode));
  }

  /**
   * Invalidate all cached configs for clients in a given experiment.
   *
   * In Phase 1 this is done by pattern-scanning the key space.
   * At scale (Phase 2) we'd maintain a set of active clientCodes per experiment.
   * For now, flush all config keys when eligibility changes — safe but broad.
   */
  async invalidateConfigsForExperiment(experimentId: string): Promise<void> {
    try {
      let cursor = '0';
      let deleted = 0;
      do {
        const [nextCursor, keys] = await this.redis.scan(
          cursor,
          'MATCH',
          'config:v1:*',
          'COUNT',
          200,
        );
        cursor = nextCursor;
        if (keys.length > 0) {
          await this.redis.del(...keys);
          deleted += keys.length;
        }
      } while (cursor !== '0');

      logger.info(
        { event: 'cache_invalidated', experimentId, deletedKeys: deleted },
        'Config cache invalidated for experiment eligibility change',
      );
    } catch (err) {
      logger.error(
        { event: 'cache_invalidation_failed', experimentId, err },
        'Failed to invalidate config cache',
      );
    }
  }

  // ------------------------------------------------------------------
  // Config version (ETag)
  // ------------------------------------------------------------------

  async getConfigVersion(applicationId: string): Promise<string | null> {
    return this.redis.get(CONFIG_VERSION_KEY(applicationId));
  }

  async setConfigVersion(applicationId: string, versionHash: string): Promise<void> {
    await this.redis.set(CONFIG_VERSION_KEY(applicationId), versionHash);
  }

  // ------------------------------------------------------------------
  // Idempotency
  // ------------------------------------------------------------------

  async isIdempotencyKeyUsed(key: string): Promise<boolean> {
    const result = await this.redis.exists(IDEMPOTENCY_KEY(key));
    return result === 1;
  }

  async markIdempotencyKey(key: string): Promise<void> {
    await this.redis.set(IDEMPOTENCY_KEY(key), '1', 'EX', IDEMPOTENCY_TTL_SECONDS);
  }
}
