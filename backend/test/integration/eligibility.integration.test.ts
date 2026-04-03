/**
 * Integration tests for the full eligibility upload pipeline.
 *
 * Prerequisites:
 *   docker-compose up -d && npm run migrate
 *
 * These tests connect to the real PostgreSQL and Redis instances started by
 * docker-compose. They use isolated UUIDs per test run so they can run
 * concurrently without colliding with each other or existing data.
 *
 * The S3 upload is skipped in CI (mocked below) — real S3/LocalStack tests
 * are run manually via docker-compose.
 */
import supertest from 'supertest';
import jwt from 'jsonwebtoken';
import { v4 as uuidv4 } from 'uuid';
import { Pool } from 'pg';
import path from 'path';
import fs from 'fs';

// We mock S3 so integration tests don't need LocalStack running
jest.mock('../../src/utils/s3', () => ({
  uploadToS3: jest.fn().mockResolvedValue(undefined),
  downloadFromS3: jest.fn(),
}));

// Import app AFTER the mock is in place
import { app } from '../../src/server';

const TEST_DB_URL =
  process.env['DATABASE_URL'] ?? 'postgresql://experimentation:secret@localhost:5432/experimentation';
const JWT_SECRET = process.env['JWT_SECRET'] ?? 'test-jwt-secret-min-16-chars';

// Create a test-scoped pool (separate from the app's pool to insert seed data)
let testPool: Pool;

// Generate a valid dev JWT for authenticated requests
function makeDevToken(userId = uuidv4()): string {
  return jwt.sign(
    { sub: userId, email: `test-${userId}@mofsl.com`, role: 'admin' },
    JWT_SECRET,
    { expiresIn: '1h' },
  );
}

// Seed: create a minimal application + experiment row for test isolation
async function seedExperiment(applicationId: string): Promise<string> {
  const experimentId = uuidv4();
  await testPool.query(
    `INSERT INTO experiments
       (id, application_id, key, name, status, coverage, hash_attribute, hash_version)
     VALUES ($1, $2, $3, $4, 'draft', 1.0, 'clientCode', 1)`,
    [experimentId, applicationId, `test_exp_${experimentId.slice(0, 8)}`, 'Test Experiment'],
  );
  return experimentId;
}

async function seedApplication(): Promise<string> {
  const appId = uuidv4();
  await testPool.query(
    `INSERT INTO applications (id, key, name) VALUES ($1, $2, $3)`,
    [appId, `test-app-${appId.slice(0, 8)}`, 'Test Application'],
  );
  return appId;
}

beforeAll(async () => {
  testPool = new Pool({ connectionString: TEST_DB_URL });
  // Verify connection
  await testPool.query('SELECT 1');
});

afterAll(async () => {
  await testPool.end();
});

// ------------------------------------------------------------------
// Upload tests
// ------------------------------------------------------------------
describe('POST /api/v1/experiments/:id/eligible-clients/upload', () => {
  let appId: string;
  let experimentId: string;
  let token: string;

  beforeEach(async () => {
    appId = await seedApplication();
    experimentId = await seedExperiment(appId);
    token = makeDevToken();
  });

  afterEach(async () => {
    // Clean up in reverse FK order
    await testPool.query('DELETE FROM eligible_clients WHERE experiment_id = $1', [experimentId]);
    await testPool.query('DELETE FROM client_list_uploads WHERE experiment_id = $1', [experimentId]);
    await testPool.query('DELETE FROM audit_log WHERE entity_id = $1', [experimentId]);
    await testPool.query('DELETE FROM experiments WHERE id = $1', [experimentId]);
    await testPool.query('DELETE FROM applications WHERE id = $1', [appId]);
  });

  it('returns 201 and inserts valid client codes from a CSV upload', async () => {
    const csvBuffer = Buffer.from('client_code\nABC001\nABC002\nABC003\n');

    const response = await supertest(app)
      .post(`/api/v1/experiments/${experimentId}/eligible-clients/upload`)
      .set('Authorization', `Bearer ${token}`)
      .attach('file', csvBuffer, { filename: 'test.csv', contentType: 'text/csv' });

    expect(response.status).toBe(201);
    expect(response.body.validRows).toBe(3);
    expect(response.body.totalRows).toBe(3);
    expect(response.body.duplicateRows).toBe(0);
    expect(response.body.invalidRows).toBe(0);
    expect(response.body.uploadId).toBeTruthy();

    // Verify DB state
    const rows = await testPool.query(
      'SELECT client_code FROM eligible_clients WHERE experiment_id = $1 ORDER BY client_code',
      [experimentId],
    );
    expect(rows.rows.map((r: { client_code: string }) => r.client_code)).toEqual([
      'ABC001',
      'ABC002',
      'ABC003',
    ]);
  });

  it('correctly reports duplicate and invalid rows', async () => {
    const csvBuffer = Buffer.from('client_code\nABC001\nABC001\nbad code!\nABC002\n');

    const response = await supertest(app)
      .post(`/api/v1/experiments/${experimentId}/eligible-clients/upload`)
      .set('Authorization', `Bearer ${token}`)
      .attach('file', csvBuffer, { filename: 'test.csv', contentType: 'text/csv' });

    expect(response.status).toBe(201);
    expect(response.body.validRows).toBe(2);
    expect(response.body.duplicateRows).toBe(1);
    expect(response.body.invalidRows).toBe(1);
  });

  it('replace mode clears existing list before inserting new one', async () => {
    // First upload: ABC001, ABC002
    const first = Buffer.from('client_code\nABC001\nABC002\n');
    await supertest(app)
      .post(`/api/v1/experiments/${experimentId}/eligible-clients/upload?mode=replace`)
      .set('Authorization', `Bearer ${token}`)
      .attach('file', first, { filename: 'first.csv', contentType: 'text/csv' });

    // Second upload (replace): XYZ001 only
    const second = Buffer.from('client_code\nXYZ001\n');
    const response = await supertest(app)
      .post(`/api/v1/experiments/${experimentId}/eligible-clients/upload?mode=replace`)
      .set('Authorization', `Bearer ${token}`)
      .attach('file', second, { filename: 'second.csv', contentType: 'text/csv' });

    expect(response.status).toBe(201);

    const rows = await testPool.query(
      'SELECT client_code FROM eligible_clients WHERE experiment_id = $1',
      [experimentId],
    );
    // Only XYZ001 should remain
    expect(rows.rows).toHaveLength(1);
    expect(rows.rows[0].client_code).toBe('XYZ001');
  });

  it('append mode adds new codes without removing existing ones', async () => {
    const first = Buffer.from('client_code\nABC001\nABC002\n');
    await supertest(app)
      .post(`/api/v1/experiments/${experimentId}/eligible-clients/upload?mode=append`)
      .set('Authorization', `Bearer ${token}`)
      .attach('file', first, { filename: 'first.csv', contentType: 'text/csv' });

    const second = Buffer.from('client_code\nXYZ001\n');
    await supertest(app)
      .post(`/api/v1/experiments/${experimentId}/eligible-clients/upload?mode=append`)
      .set('Authorization', `Bearer ${token}`)
      .attach('file', second, { filename: 'second.csv', contentType: 'text/csv' });

    const rows = await testPool.query(
      'SELECT client_code FROM eligible_clients WHERE experiment_id = $1 ORDER BY client_code',
      [experimentId],
    );
    const codes = rows.rows.map((r: { client_code: string }) => r.client_code);
    expect(codes).toContain('ABC001');
    expect(codes).toContain('ABC002');
    expect(codes).toContain('XYZ001');
  });

  it('writes an audit log entry on successful upload', async () => {
    const csvBuffer = Buffer.from('client_code\nABC001\n');

    await supertest(app)
      .post(`/api/v1/experiments/${experimentId}/eligible-clients/upload`)
      .set('Authorization', `Bearer ${token}`)
      .attach('file', csvBuffer, { filename: 'test.csv', contentType: 'text/csv' });

    const audit = await testPool.query(
      `SELECT action, entity_type FROM audit_log
       WHERE entity_id = $1 AND entity_type = 'eligible_clients'`,
      [experimentId],
    );
    expect(audit.rows.length).toBeGreaterThanOrEqual(1);
    expect(audit.rows[0].action).toBe('uploaded');
  });

  it('returns 401 when no Authorization header is provided', async () => {
    const csvBuffer = Buffer.from('ABC001\n');

    const response = await supertest(app)
      .post(`/api/v1/experiments/${experimentId}/eligible-clients/upload`)
      .attach('file', csvBuffer, { filename: 'test.csv', contentType: 'text/csv' });

    expect(response.status).toBe(401);
  });

  it('returns 404 for a non-existent experiment', async () => {
    const csvBuffer = Buffer.from('client_code\nABC001\n');
    const fakeId = uuidv4();

    const response = await supertest(app)
      .post(`/api/v1/experiments/${fakeId}/eligible-clients/upload`)
      .set('Authorization', `Bearer ${token}`)
      .attach('file', csvBuffer, { filename: 'test.csv', contentType: 'text/csv' });

    expect(response.status).toBe(404);
  });

  it('returns 400 when no file is attached', async () => {
    const response = await supertest(app)
      .post(`/api/v1/experiments/${experimentId}/eligible-clients/upload`)
      .set('Authorization', `Bearer ${token}`);

    expect(response.status).toBe(400);
  });

  it('returns 400 when all rows are invalid', async () => {
    const csvBuffer = Buffer.from('bad code!\nanother bad!\n');

    const response = await supertest(app)
      .post(`/api/v1/experiments/${experimentId}/eligible-clients/upload`)
      .set('Authorization', `Bearer ${token}`)
      .attach('file', csvBuffer, { filename: 'test.csv', contentType: 'text/csv' });

    expect(response.status).toBe(400);
  });
});

// ------------------------------------------------------------------
// GET tests
// ------------------------------------------------------------------
describe('GET /api/v1/experiments/:id/eligible-clients', () => {
  let appId: string;
  let experimentId: string;
  let token: string;

  beforeEach(async () => {
    appId = await seedApplication();
    experimentId = await seedExperiment(appId);
    token = makeDevToken();
  });

  afterEach(async () => {
    await testPool.query('DELETE FROM eligible_clients WHERE experiment_id = $1', [experimentId]);
    await testPool.query('DELETE FROM client_list_uploads WHERE experiment_id = $1', [experimentId]);
    await testPool.query('DELETE FROM audit_log WHERE entity_id = $1', [experimentId]);
    await testPool.query('DELETE FROM experiments WHERE id = $1', [experimentId]);
    await testPool.query('DELETE FROM applications WHERE id = $1', [appId]);
  });

  it('returns upload history and total eligible client count', async () => {
    // Upload some clients first
    const csvBuffer = Buffer.from('client_code\nABC001\nABC002\n');
    await supertest(app)
      .post(`/api/v1/experiments/${experimentId}/eligible-clients/upload`)
      .set('Authorization', `Bearer ${token}`)
      .attach('file', csvBuffer, { filename: 'test.csv', contentType: 'text/csv' });

    const response = await supertest(app)
      .get(`/api/v1/experiments/${experimentId}/eligible-clients`)
      .set('Authorization', `Bearer ${token}`);

    expect(response.status).toBe(200);
    expect(response.body.totalEligibleClients).toBe(2);
    expect(response.body.uploads).toHaveLength(1);
    expect(response.body.pagination.hasMore).toBe(false);
  });

  it('returns 404 for a non-existent experiment', async () => {
    const response = await supertest(app)
      .get(`/api/v1/experiments/${uuidv4()}/eligible-clients`)
      .set('Authorization', `Bearer ${token}`);

    expect(response.status).toBe(404);
  });
});

// ------------------------------------------------------------------
// DELETE tests
// ------------------------------------------------------------------
describe('DELETE /api/v1/experiments/:id/eligible-clients', () => {
  let appId: string;
  let experimentId: string;
  let token: string;

  beforeEach(async () => {
    appId = await seedApplication();
    experimentId = await seedExperiment(appId);
    token = makeDevToken();
  });

  afterEach(async () => {
    await testPool.query('DELETE FROM eligible_clients WHERE experiment_id = $1', [experimentId]);
    await testPool.query('DELETE FROM client_list_uploads WHERE experiment_id = $1', [experimentId]);
    await testPool.query('DELETE FROM audit_log WHERE entity_id = $1', [experimentId]);
    await testPool.query('DELETE FROM experiments WHERE id = $1', [experimentId]);
    await testPool.query('DELETE FROM applications WHERE id = $1', [appId]);
  });

  it('deletes all eligible clients for an experiment', async () => {
    // Seed eligible clients directly
    const batchId = uuidv4();
    await testPool.query(
      `INSERT INTO eligible_clients (id, experiment_id, client_code, upload_batch_id)
       VALUES ($1, $2, 'ABC001', $3), ($4, $2, 'ABC002', $3)`,
      [uuidv4(), experimentId, batchId, uuidv4()],
    );

    const response = await supertest(app)
      .delete(`/api/v1/experiments/${experimentId}/eligible-clients`)
      .set('Authorization', `Bearer ${token}`)
      .send({});

    expect(response.status).toBe(200);
    expect(response.body.deletedCount).toBe(2);

    const count = await testPool.query(
      'SELECT COUNT(*) AS count FROM eligible_clients WHERE experiment_id = $1',
      [experimentId],
    );
    expect(parseInt(count.rows[0].count, 10)).toBe(0);
  });

  it('writes an audit log entry on delete', async () => {
    const response = await supertest(app)
      .delete(`/api/v1/experiments/${experimentId}/eligible-clients`)
      .set('Authorization', `Bearer ${token}`)
      .send({});

    expect(response.status).toBe(200);

    const audit = await testPool.query(
      `SELECT action FROM audit_log
       WHERE entity_id = $1 AND entity_type = 'eligible_clients' AND action = 'deleted'`,
      [experimentId],
    );
    expect(audit.rows.length).toBeGreaterThanOrEqual(1);
  });
});

// ------------------------------------------------------------------
// EligibilityService integration tests (direct service layer)
// ------------------------------------------------------------------
describe('FileUploadEligibilityService — integration', () => {
  let appId: string;
  let experimentId: string;

  beforeEach(async () => {
    appId = await seedApplication();
    experimentId = await seedExperiment(appId);
  });

  afterEach(async () => {
    await testPool.query('DELETE FROM eligible_clients WHERE experiment_id = $1', [experimentId]);
    await testPool.query('DELETE FROM experiments WHERE id = $1', [experimentId]);
    await testPool.query('DELETE FROM applications WHERE id = $1', [appId]);
  });

  it('returns true for any client when experiment has no eligibility list', async () => {
    const { FileUploadEligibilityService } = await import(
      '../../src/services/eligibility/file-upload.eligibility'
    );
    const svc = new FileUploadEligibilityService(testPool);

    expect(await svc.isEligible('ANYCLIENT', experimentId)).toBe(true);
    expect(await svc.isEligible('OTHERCLIENT', experimentId)).toBe(true);
  });

  it('returns true only for listed clients when a list exists', async () => {
    // Insert an eligibility list
    const batchId = uuidv4();
    await testPool.query(
      `INSERT INTO eligible_clients (id, experiment_id, client_code, upload_batch_id)
       VALUES ($1, $2, 'LISTED001', $3)`,
      [uuidv4(), experimentId, batchId],
    );

    const { FileUploadEligibilityService } = await import(
      '../../src/services/eligibility/file-upload.eligibility'
    );
    const svc = new FileUploadEligibilityService(testPool);

    expect(await svc.isEligible('LISTED001', experimentId)).toBe(true);
    expect(await svc.isEligible('NOTLISTED', experimentId)).toBe(false);
  });

  it('bulkCheckEligibility handles mixed open + restricted experiments', async () => {
    // Seed a second experiment with a list
    const exp2Id = await seedExperiment(appId);
    const batchId = uuidv4();
    await testPool.query(
      `INSERT INTO eligible_clients (id, experiment_id, client_code, upload_batch_id)
       VALUES ($1, $2, 'CLIENT001', $3)`,
      [uuidv4(), exp2Id, batchId],
    );

    const { FileUploadEligibilityService } = await import(
      '../../src/services/eligibility/file-upload.eligibility'
    );
    const svc = new FileUploadEligibilityService(testPool);

    const map = await svc.bulkCheckEligibility('CLIENT001', [experimentId, exp2Id]);

    expect(map.get(experimentId)).toBe(true);  // no list = open
    expect(map.get(exp2Id)).toBe(true);         // has list + in list

    const map2 = await svc.bulkCheckEligibility('OTHERCLIENT', [experimentId, exp2Id]);
    expect(map2.get(experimentId)).toBe(true);  // open
    expect(map2.get(exp2Id)).toBe(false);        // has list + NOT in list

    // Cleanup exp2
    await testPool.query('DELETE FROM eligible_clients WHERE experiment_id = $1', [exp2Id]);
    await testPool.query('DELETE FROM experiments WHERE id = $1', [exp2Id]);
  });
});
