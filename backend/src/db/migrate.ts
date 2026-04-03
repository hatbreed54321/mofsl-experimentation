/**
 * Database migration runner.
 * Reads SQL files from src/db/migrations/ in filename order and executes
 * each one against PostgreSQL. Tracks applied migrations in a migrations table.
 *
 * Usage: npm run migrate
 */
import 'dotenv/config';
import fs from 'fs';
import path from 'path';
import { Pool } from 'pg';
import { config } from '../config';

const MIGRATIONS_DIR = path.join(__dirname, 'migrations');

async function migrate(): Promise<void> {
  const pool = new Pool({ connectionString: config.databaseUrl });

  try {
    // Ensure migrations tracking table exists
    await pool.query(`
      CREATE TABLE IF NOT EXISTS schema_migrations (
        filename   VARCHAR(255) PRIMARY KEY,
        applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    `);

    // Read migration files sorted by name
    const files = fs
      .readdirSync(MIGRATIONS_DIR)
      .filter((f) => f.endsWith('.sql'))
      .sort();

    if (files.length === 0) {
      console.log('No migration files found.');
      return;
    }

    for (const filename of files) {
      // Check if already applied
      const { rows } = await pool.query(
        'SELECT filename FROM schema_migrations WHERE filename = $1',
        [filename],
      );

      if (rows.length > 0) {
        console.log(`[SKIP] ${filename} — already applied`);
        continue;
      }

      const filePath = path.join(MIGRATIONS_DIR, filename);
      const sql = fs.readFileSync(filePath, 'utf8');

      console.log(`[RUN]  ${filename} ...`);

      await pool.query('BEGIN');
      try {
        await pool.query(sql);
        await pool.query('INSERT INTO schema_migrations (filename) VALUES ($1)', [filename]);
        await pool.query('COMMIT');
        console.log(`[OK]   ${filename}`);
      } catch (err) {
        await pool.query('ROLLBACK');
        console.error(`[FAIL] ${filename}:`, err);
        throw err;
      }
    }

    console.log('\nAll migrations applied successfully.');
  } finally {
    await pool.end();
  }
}

migrate().catch((err) => {
  console.error('Migration failed:', err);
  process.exit(1);
});
