import pino from 'pino';
import { config } from '../config';

export const logger = pino({
  level: config.logLevel,
  // Pretty-print in development, JSON in production
  ...(config.nodeEnv === 'development'
    ? {
        transport: {
          target: 'pino-pretty',
          options: { colorize: true, translateTime: 'SYS:standard', ignore: 'pid,hostname' },
        },
      }
    : {}),
  base: { service: 'experimentation-backend' },
  timestamp: pino.stdTimeFunctions.isoTime,
  // Redact sensitive fields from all log output
  redact: {
    paths: ['req.headers["x-api-key"]', 'req.headers.authorization'],
    censor: '[REDACTED]',
  },
});
