import { ErrorRequestHandler } from 'express';
import { ZodError } from 'zod';
import { AppError, ValidationError } from '../utils/errors';
import { logger } from '../utils/logger';

/**
 * Global error handler middleware.
 * Must be registered LAST in the Express middleware chain.
 *
 * - AppError subclasses → structured JSON with their status code
 * - ZodError → 400 validation_error with field-level details
 * - Unhandled errors → 500 internal_error (stack trace never leaked in production)
 */
// eslint-disable-next-line @typescript-eslint/no-unused-vars
export const errorHandler: ErrorRequestHandler = (err, _req, res, _next) => {
  if (err instanceof ValidationError) {
    res.status(err.statusCode).json({
      error: err.errorCode,
      message: err.message,
      ...(err.details ? { details: err.details } : {}),
    });
    return;
  }

  if (err instanceof AppError) {
    if (err.statusCode >= 500) {
      logger.error({ event: 'app_error', err }, err.message);
    }
    res.status(err.statusCode).json({
      error: err.errorCode,
      message: err.message,
    });
    return;
  }

  if (err instanceof ZodError) {
    const details = err.errors.map((e) => ({
      field: e.path.join('.'),
      message: e.message,
    }));
    res.status(400).json({
      error: 'validation_error',
      message: 'Request validation failed',
      details,
    });
    return;
  }

  // Unhandled — log with full details internally, return generic message externally
  logger.error({ event: 'unhandled_error', err }, 'Unhandled server error');

  res.status(500).json({
    error: 'internal_error',
    message: 'An unexpected error occurred',
  });
};
