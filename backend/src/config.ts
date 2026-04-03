import { z } from 'zod';

const configSchema = z.object({
  nodeEnv: z.enum(['development', 'staging', 'production', 'test']).default('development'),
  port: z.coerce.number().int().positive().default(3000),
  logLevel: z.enum(['trace', 'debug', 'info', 'warn', 'error', 'fatal', 'silent']).default('info'),

  // PostgreSQL
  databaseUrl: z.string().url(),
  databasePoolMin: z.coerce.number().int().min(1).default(2),
  databasePoolMax: z.coerce.number().int().min(1).default(20),

  // Redis
  redisHost: z.string().min(1).default('localhost'),
  redisPort: z.coerce.number().int().positive().default(6379),
  redisPassword: z.string().optional(),

  // Kafka (optional in dev — empty string disables it)
  kafkaBrokers: z.string().default(''),
  kafkaClientId: z.string().default('experimentation-backend'),

  // S3
  s3Bucket: z.string().min(1),
  s3Region: z.string().min(1).default('ap-south-1'),
  s3Endpoint: z.string().optional(), // set for LocalStack in dev

  // Auth
  jwtSecret: z.string().min(16),
  jwtExpiry: z.string().default('8h'),
});

function loadConfig() {
  const result = configSchema.safeParse({
    nodeEnv: process.env['NODE_ENV'],
    port: process.env['PORT'],
    logLevel: process.env['LOG_LEVEL'],
    databaseUrl: process.env['DATABASE_URL'],
    databasePoolMin: process.env['DATABASE_POOL_MIN'],
    databasePoolMax: process.env['DATABASE_POOL_MAX'],
    redisHost: process.env['REDIS_HOST'],
    redisPort: process.env['REDIS_PORT'],
    redisPassword: process.env['REDIS_PASSWORD'],
    kafkaBrokers: process.env['KAFKA_BROKERS'],
    kafkaClientId: process.env['KAFKA_CLIENT_ID'],
    s3Bucket: process.env['S3_BUCKET'],
    s3Region: process.env['S3_REGION'],
    s3Endpoint: process.env['S3_ENDPOINT'],
    jwtSecret: process.env['JWT_SECRET'],
    jwtExpiry: process.env['JWT_EXPIRY'],
  });

  if (!result.success) {
    const missing = result.error.errors
      .map((e) => `${e.path.join('.')}: ${e.message}`)
      .join('\n  ');
    throw new Error(`Invalid environment configuration:\n  ${missing}`);
  }

  return result.data;
}

export const config = loadConfig();
export type Config = typeof config;
