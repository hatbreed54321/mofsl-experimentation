export type AuditEntityType =
  | 'experiment'
  | 'flag'
  | 'variation'
  | 'targeting_rule'
  | 'eligible_clients'
  | 'forced_variation'
  | 'metric'
  | 'api_key';

export type AuditAction = 'created' | 'updated' | 'deleted' | 'status_changed' | 'uploaded';

export interface AuditLogEntry {
  id: string;
  entityType: AuditEntityType;
  entityId: string;
  action: AuditAction;
  changes: Record<string, { old: unknown; new: unknown }> | null;
  metadata: Record<string, unknown> | null;
  actorId: string | null;
  actorEmail: string | null;
  createdAt: Date;
}

export interface CreateAuditEntry {
  entityType: AuditEntityType;
  entityId: string;
  action: AuditAction;
  changes?: Record<string, { old: unknown; new: unknown }>;
  metadata?: Record<string, unknown>;
  actorId?: string;
  actorEmail?: string;
}
