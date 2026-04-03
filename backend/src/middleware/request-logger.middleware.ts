import { RequestHandler } from 'express';
import { v4 as uuidv4 } from 'uuid';

/**
 * Attaches a unique requestId to every incoming request.
 * The requestId propagates to all log entries via pino-http.
 */
export const requestId: RequestHandler = (req, res, next) => {
  const id = (req.headers['x-request-id'] as string | undefined) ?? uuidv4();
  req.headers['x-request-id'] = id;
  res.setHeader('x-request-id', id);
  next();
};
