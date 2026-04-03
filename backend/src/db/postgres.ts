import { Pool, PoolClient } from 'pg';
import { config } from '../config';
import { logger } from '../utils/logger';

export const pool = new Pool({
  connectionString: config.databaseUrl,
  min: config.databasePoolMin,
  max: config.databasePoolMax,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000,
  statement_timeout: 5000,
});

pool.on('error', (err) => {
  logger.error({ event: 'pg_pool_error', err }, 'Unexpected PostgreSQL pool error');
});

pool.on('connect', () => {
  logger.debug({ event: 'pg_connect' }, 'New PostgreSQL connection established');
});

/**
 * Execute a single query with automatic connection management.
 */
export async function query<T extends Record<string, unknown>>(
  text: string,
  params?: unknown[],
): Promise<{ rows: T[]; rowCount: number }> {
  const result = await pool.query<T>(text, params);
  return { rows: result.rows, rowCount: result.rowCount ?? 0 };
}

/**
 * Run multiple operations in a transaction.
 * Automatically commits or rolls back.
 */
export async function withTransaction<T>(
  fn: (client: PoolClient) => Promise<T>,
): Promise<T> {
  const client = await pool.connect();
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

export async function testConnection(): Promise<void> {
  const result = await query<{ now: string }>('SELECT NOW() AS now');
  logger.info({ event: 'pg_connected', serverTime: result.rows[0]?.now }, 'PostgreSQL connected');
}

export async function closePool(): Promise<void> {
  await pool.end();
}
