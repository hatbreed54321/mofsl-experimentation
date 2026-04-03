// Load .env before any other imports — dotenv must run before config.ts reads env vars.
// In production (ECS) there is no .env file, so this is a no-op.
import 'dotenv/config';
import express from 'express';
import helmet from 'helmet';
import cors from 'cors';
import compression from 'compression';
import pinoHttp from 'pino-http';

import { config } from './config';
import { logger } from './utils/logger';
import { testConnection, closePool } from './db/postgres';
import { connectRedis, closeRedis } from './db/redis';
import { errorHandler } from './middleware/error-handler.middleware';
import { healthRouter } from './routes/health.routes';
import { eligibilityRouter } from './routes/eligibility.routes';

const app = express();

// Security headers
app.use(helmet());

// CORS — dashboard origin only
app.use(
  cors({
    origin: config.nodeEnv === 'production' ? false : true,
    methods: ['GET', 'POST', 'DELETE', 'OPTIONS'],
    allowedHeaders: ['Content-Type', 'Authorization', 'X-API-Key'],
  }),
);

// gzip compression
app.use(compression());

// Structured request logging
app.use(
  pinoHttp({
    logger,
    customLogLevel: (_req, res) => (res.statusCode >= 500 ? 'error' : 'info'),
    customSuccessMessage: (req, res) =>
      `${req.method} ${req.url} ${res.statusCode}`,
    redact: ['req.headers["x-api-key"]', 'req.headers.authorization'],
  }),
);

// Body parsing
app.use(express.json({ limit: '1mb' }));
app.use(express.urlencoded({ extended: false }));

// Routes
app.use('/health', healthRouter);
app.use('/api/v1', eligibilityRouter);

// Global error handler — must be last
app.use(errorHandler);

async function start(): Promise<void> {
  try {
    await testConnection();
    await connectRedis();

    app.listen(config.port, () => {
      logger.info(
        { event: 'server_started', port: config.port, env: config.nodeEnv },
        `Server listening on port ${config.port}`,
      );
    });
  } catch (err) {
    logger.fatal({ event: 'server_start_failed', err }, 'Failed to start server');
    process.exit(1);
  }
}

// Graceful shutdown
async function shutdown(signal: string): Promise<void> {
  logger.info({ event: 'shutdown', signal }, 'Shutting down');
  await closePool();
  await closeRedis();
  process.exit(0);
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

// Only start the HTTP listener when this file is run directly (not when imported by tests)
if (require.main === module) {
  start();
}

export { app };
