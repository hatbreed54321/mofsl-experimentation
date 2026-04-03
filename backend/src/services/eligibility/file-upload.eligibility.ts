import { Pool } from 'pg';
import { EligibilityService } from './eligibility.interface';
import { logger } from '../../utils/logger';

/**
 * Phase 1 EligibilityService implementation backed by PostgreSQL eligible_clients table.
 *
 * Key rule: if an experiment has zero rows in eligible_clients, ALL users are eligible.
 * Targeting is opt-in. Only experiments with an uploaded list are restricted.
 *
 * See: skills/file-based-targeting.md
 */
export class FileUploadEligibilityService implements EligibilityService {
  constructor(private readonly db: Pool) {}

  async isEligible(clientCode: string, experimentId: string): Promise<boolean> {
    // Single query: check if a list exists AND if the client is in it
    const result = await this.db.query<{ has_list: boolean; is_eligible: boolean }>(
      `SELECT
         EXISTS(
           SELECT 1 FROM eligible_clients WHERE experiment_id = $1 LIMIT 1
         ) AS has_list,
         EXISTS(
           SELECT 1 FROM eligible_clients WHERE experiment_id = $1 AND client_code = $2
         ) AS is_eligible`,
      [experimentId, clientCode],
    );

    const row = result.rows[0];
    if (!row) return true;

    // No list = open to everyone
    if (!row.has_list) return true;

    return row.is_eligible;
  }

  async getEligibleExperimentIds(clientCode: string): Promise<string[]> {
    // Return experiments where:
    //   (a) the experiment has no eligibility list (open to all), OR
    //   (b) the client is explicitly listed
    const result = await this.db.query<{ id: string }>(
      `SELECT e.id
       FROM experiments e
       WHERE e.status IN ('running', 'paused')
         AND (
           -- No targeting list exists for this experiment
           NOT EXISTS (
             SELECT 1 FROM eligible_clients ec WHERE ec.experiment_id = e.id LIMIT 1
           )
           OR
           -- Client is in the targeting list
           EXISTS (
             SELECT 1 FROM eligible_clients ec
             WHERE ec.experiment_id = e.id AND ec.client_code = $1
           )
         )`,
      [clientCode],
    );

    return result.rows.map((r) => r.id);
  }

  async bulkCheckEligibility(
    clientCode: string,
    experimentIds: string[],
  ): Promise<Map<string, boolean>> {
    if (experimentIds.length === 0) {
      return new Map();
    }

    // Single query for all experiments at once
    const result = await this.db.query<{
      experiment_id: string;
      has_list: boolean;
      has_match: boolean;
    }>(
      `SELECT
         e.id AS experiment_id,
         EXISTS(
           SELECT 1 FROM eligible_clients WHERE experiment_id = e.id LIMIT 1
         ) AS has_list,
         EXISTS(
           SELECT 1 FROM eligible_clients WHERE experiment_id = e.id AND client_code = $1
         ) AS has_match
       FROM experiments e
       WHERE e.id = ANY($2::uuid[])`,
      [clientCode, experimentIds],
    );

    const eligibilityMap = new Map<string, boolean>();

    for (const row of result.rows) {
      // No list = open to all = eligible. Has list = must be in it.
      eligibilityMap.set(row.experiment_id, !row.has_list || row.has_match);
    }

    // Experiments not returned by the query (e.g., deleted) → not eligible
    for (const id of experimentIds) {
      if (!eligibilityMap.has(id)) {
        eligibilityMap.set(id, false);
      }
    }

    logger.debug(
      { event: 'bulk_eligibility_check', clientCode, experimentCount: experimentIds.length },
      'Bulk eligibility check complete',
    );

    return eligibilityMap;
  }
}
