import { Pool, PoolClient } from 'pg';
import { v4 as uuidv4 } from 'uuid';
import { CreateAuditEntry } from '../models/audit.model';
import { logger } from '../utils/logger';

/**
 * AuditService — append-only audit log.
 *
 * Every mutation to experiments, flags, targeting rules, eligibility lists,
 * and forced variations MUST call this service. The audit log is never updated
 * or deleted.
 */
export class AuditService {
  constructor(private readonly db: Pool | PoolClient) {}

  async log(entry: CreateAuditEntry): Promise<void> {
    const id = uuidv4();
    try {
      await this.db.query(
        `INSERT INTO audit_log
           (id, entity_type, entity_id, action, changes, metadata, actor_id, actor_email)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`,
        [
          id,
          entry.entityType,
          entry.entityId,
          entry.action,
          entry.changes ? JSON.stringify(entry.changes) : null,
          entry.metadata ? JSON.stringify(entry.metadata) : null,
          // actor_id references users(id) — user rows don't exist until Phase 8 SSO.
          // Track actor via actor_email (denormalized text) instead.
          null,
          entry.actorEmail ?? null,
        ],
      );

      logger.info(
        {
          event: 'audit_logged',
          auditId: id,
          entityType: entry.entityType,
          entityId: entry.entityId,
          action: entry.action,
          actorEmail: entry.actorEmail,
        },
        'Audit log entry created',
      );
    } catch (err) {
      // Audit failures are logged but do not propagate — we never let an audit
      // write failure roll back the primary operation.
      logger.error(
        { event: 'audit_log_failed', entityType: entry.entityType, entityId: entry.entityId, err },
        'Failed to write audit log entry',
      );
    }
  }
}
