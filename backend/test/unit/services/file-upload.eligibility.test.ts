import { FileUploadEligibilityService } from '../../../src/services/eligibility/file-upload.eligibility';
import { Pool } from 'pg';

// Build a minimal Pool mock that replaces the .query() method
function makePoolMock(queryFn: (text: string, params?: unknown[]) => Promise<unknown>): Pool {
  return { query: queryFn } as unknown as Pool;
}

describe('FileUploadEligibilityService.isEligible', () => {
  it('returns true when experiment has no eligibility list', async () => {
    const pool = makePoolMock(async () => ({
      rows: [{ has_list: false, is_eligible: false }],
    }));
    const svc = new FileUploadEligibilityService(pool);

    const result = await svc.isEligible('AB1234', 'exp-uuid');
    expect(result).toBe(true);
  });

  it('returns true when experiment has a list and client is in it', async () => {
    const pool = makePoolMock(async () => ({
      rows: [{ has_list: true, is_eligible: true }],
    }));
    const svc = new FileUploadEligibilityService(pool);

    const result = await svc.isEligible('AB1234', 'exp-uuid');
    expect(result).toBe(true);
  });

  it('returns false when experiment has a list and client is NOT in it', async () => {
    const pool = makePoolMock(async () => ({
      rows: [{ has_list: true, is_eligible: false }],
    }));
    const svc = new FileUploadEligibilityService(pool);

    const result = await svc.isEligible('AB1234', 'exp-uuid');
    expect(result).toBe(false);
  });

  it('returns true when query returns no rows (defensive fallback)', async () => {
    const pool = makePoolMock(async () => ({ rows: [] }));
    const svc = new FileUploadEligibilityService(pool);

    const result = await svc.isEligible('AB1234', 'exp-uuid');
    expect(result).toBe(true);
  });
});

describe('FileUploadEligibilityService.bulkCheckEligibility', () => {
  it('returns an empty Map for an empty input', async () => {
    const pool = makePoolMock(async () => ({ rows: [] }));
    const svc = new FileUploadEligibilityService(pool);

    const result = await svc.bulkCheckEligibility('AB1234', []);
    expect(result.size).toBe(0);
  });

  it('marks experiments without a list as eligible', async () => {
    const pool = makePoolMock(async () => ({
      rows: [
        { experiment_id: 'exp-1', has_list: false, has_match: false },
        { experiment_id: 'exp-2', has_list: true, has_match: true },
        { experiment_id: 'exp-3', has_list: true, has_match: false },
      ],
    }));
    const svc = new FileUploadEligibilityService(pool);

    const result = await svc.bulkCheckEligibility('AB1234', ['exp-1', 'exp-2', 'exp-3']);

    expect(result.get('exp-1')).toBe(true);  // no list = open
    expect(result.get('exp-2')).toBe(true);  // has list + in list
    expect(result.get('exp-3')).toBe(false); // has list + NOT in list
  });

  it('marks missing experiment IDs as ineligible', async () => {
    // DB returns rows for exp-1 and exp-2 only; exp-3 was deleted
    const pool = makePoolMock(async () => ({
      rows: [
        { experiment_id: 'exp-1', has_list: false, has_match: false },
        { experiment_id: 'exp-2', has_list: false, has_match: false },
      ],
    }));
    const svc = new FileUploadEligibilityService(pool);

    const result = await svc.bulkCheckEligibility('AB1234', ['exp-1', 'exp-2', 'exp-3']);

    expect(result.get('exp-1')).toBe(true);
    expect(result.get('exp-2')).toBe(true);
    expect(result.get('exp-3')).toBe(false);
  });

  it('uses a single DB query regardless of how many experiment IDs are passed', async () => {
    let queryCount = 0;
    const pool = makePoolMock(async () => {
      queryCount++;
      return { rows: [] };
    });
    const svc = new FileUploadEligibilityService(pool);

    await svc.bulkCheckEligibility('AB1234', ['exp-1', 'exp-2', 'exp-3', 'exp-4', 'exp-5']);

    expect(queryCount).toBe(1);
  });
});

