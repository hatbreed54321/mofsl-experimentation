// Load test environment variables before any test module is imported
import 'dotenv/config';

// Default test env vars — overridden by a real .env if present
process.env['NODE_ENV'] = process.env['NODE_ENV'] ?? 'test';
process.env['DATABASE_URL'] =
  process.env['DATABASE_URL'] ?? 'postgresql://experimentation:secret@localhost:5432/experimentation';
process.env['REDIS_HOST'] = process.env['REDIS_HOST'] ?? 'localhost';
process.env['REDIS_PORT'] = process.env['REDIS_PORT'] ?? '6379';
process.env['S3_BUCKET'] = process.env['S3_BUCKET'] ?? 'mofsl-experimentation-uploads';
process.env['S3_REGION'] = process.env['S3_REGION'] ?? 'ap-south-1';
process.env['S3_ENDPOINT'] = process.env['S3_ENDPOINT'] ?? 'http://localhost:4566';
process.env['JWT_SECRET'] = process.env['JWT_SECRET'] ?? 'test-jwt-secret-min-16-chars';
process.env['LOG_LEVEL'] = 'silent'; // suppress logs during tests
