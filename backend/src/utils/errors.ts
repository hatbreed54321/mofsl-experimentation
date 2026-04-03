export class AppError extends Error {
  constructor(
    public readonly statusCode: number,
    public readonly errorCode: string,
    message: string,
  ) {
    super(message);
    this.name = 'AppError';
    // Maintains proper stack trace in V8
    Error.captureStackTrace(this, this.constructor);
  }
}

export class NotFoundError extends AppError {
  constructor(entity: string, id: string) {
    super(404, 'not_found', `${entity} with id '${id}' not found`);
    this.name = 'NotFoundError';
  }
}

export class ConflictError extends AppError {
  constructor(message: string) {
    super(409, 'conflict', message);
    this.name = 'ConflictError';
  }
}

export class ValidationError extends AppError {
  constructor(
    message: string,
    public readonly details?: { field: string; message: string }[],
  ) {
    super(400, 'validation_error', message);
    this.name = 'ValidationError';
  }
}

export class UnauthorizedError extends AppError {
  constructor(message = 'Invalid or missing credentials') {
    super(401, 'unauthorized', message);
    this.name = 'UnauthorizedError';
  }
}

export class PayloadTooLargeError extends AppError {
  constructor(message: string) {
    super(413, 'payload_too_large', message);
    this.name = 'PayloadTooLargeError';
  }
}
