/**
 * EligibilityService — the central abstraction for experiment targeting.
 *
 * Phase 1 implementation: FileUploadEligibilityService (queries eligible_clients table).
 * Phase 2 implementation: DataLakeEligibilityService (queries data lake).
 *
 * The config generator depends ONLY on this interface — never on the implementation.
 * See: skills/file-based-targeting.md, ADR-002.
 */
export interface EligibilityService {
  /**
   * Check if a single client is eligible for a specific experiment.
   *
   * Returns true if:
   * - The experiment has NO eligibility list (open to all users), OR
   * - The client code is present in the experiment's eligibility list.
   *
   * Returns false if:
   * - The experiment has an eligibility list AND the client is not in it.
   */
  isEligible(clientCode: string, experimentId: string): Promise<boolean>;

  /**
   * Get all experiment IDs that a client is eligible for.
   * Includes experiments with no eligibility list (open to all).
   */
  getEligibleExperimentIds(clientCode: string): Promise<string[]>;

  /**
   * Efficiently check eligibility for multiple experiments in a single call.
   * Used by config generator to batch the eligibility check.
   *
   * Returns a Map<experimentId, isEligible>.
   */
  bulkCheckEligibility(
    clientCode: string,
    experimentIds: string[],
  ): Promise<Map<string, boolean>>;
}
