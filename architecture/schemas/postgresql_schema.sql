-- =============================================================================
-- MOFSL Experimentation Platform — PostgreSQL Schema
-- =============================================================================
-- Database: experimentation
-- Engine: PostgreSQL 15+ on AWS RDS
-- Encoding: UTF-8
-- =============================================================================

-- Enable UUID generation
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- =============================================================================
-- 1. APPLICATIONS (multi-tenant: Riise is the first app)
-- =============================================================================

CREATE TABLE applications (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    key             VARCHAR(50)  NOT NULL UNIQUE,       -- e.g., 'riise'
    name            VARCHAR(200) NOT NULL,               -- e.g., 'Riise Trading App'
    description     TEXT,
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE applications IS 'Client applications that integrate with the experimentation platform. Riise is the first.';

-- =============================================================================
-- 2. API KEYS (authentication for SDK and event ingestion)
-- =============================================================================

CREATE TABLE api_keys (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    application_id  UUID         NOT NULL REFERENCES applications(id),
    key_prefix      VARCHAR(12)  NOT NULL,               -- first 12 chars of key, for display (e.g., 'mk_live_a1b2')
    key_hash        VARCHAR(128) NOT NULL,               -- bcrypt hash of full API key
    environment     VARCHAR(20)  NOT NULL DEFAULT 'production',  -- 'production', 'staging', 'development'
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE,
    last_used_at    TIMESTAMPTZ,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    revoked_at      TIMESTAMPTZ,

    CONSTRAINT chk_environment CHECK (environment IN ('production', 'staging', 'development'))
);

CREATE INDEX idx_api_keys_prefix ON api_keys(key_prefix) WHERE is_active = TRUE;
CREATE INDEX idx_api_keys_application ON api_keys(application_id);

COMMENT ON TABLE api_keys IS 'API keys for SDK and event ingestion authentication. Keys are hashed with bcrypt; only the prefix is stored in plain text for identification.';

-- =============================================================================
-- 3. USERS (dashboard users — MOFSL employees)
-- =============================================================================

CREATE TABLE users (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    email           VARCHAR(255) NOT NULL UNIQUE,
    name            VARCHAR(200) NOT NULL,
    role            VARCHAR(20)  NOT NULL DEFAULT 'admin',  -- Phase 1: all users are admin. Phase 2: 'viewer', 'editor', 'admin'
    sso_subject_id  VARCHAR(255) UNIQUE,                     -- Subject ID from SSO IdP
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE,
    last_login_at   TIMESTAMPTZ,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_role CHECK (role IN ('viewer', 'editor', 'admin'))
);

COMMENT ON TABLE users IS 'Dashboard users (MOFSL employees). Authenticated via internal SSO. Phase 1: all users have admin role.';

-- =============================================================================
-- 4. EXPERIMENTS
-- =============================================================================

CREATE TYPE experiment_status AS ENUM ('draft', 'running', 'paused', 'completed', 'archived');

CREATE TABLE experiments (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    application_id  UUID            NOT NULL REFERENCES applications(id),
    key             VARCHAR(100)    NOT NULL,
    name            VARCHAR(200)    NOT NULL,
    description     TEXT,
    hypothesis      TEXT,
    status          experiment_status NOT NULL DEFAULT 'draft',
    
    -- Traffic allocation
    coverage        DECIMAL(5,4)    NOT NULL DEFAULT 1.0,   -- 0.0000 to 1.0000 (fraction of eligible users)
    
    -- Hash configuration
    hash_attribute  VARCHAR(50)     NOT NULL DEFAULT 'clientCode',
    hash_version    SMALLINT        NOT NULL DEFAULT 1,      -- 1 = MurmurHash3 x86 32-bit
    seed            VARCHAR(100),                             -- Hash seed; defaults to experiment key if NULL
    
    -- Lifecycle timestamps
    started_at      TIMESTAMPTZ,
    paused_at       TIMESTAMPTZ,
    completed_at    TIMESTAMPTZ,
    archived_at     TIMESTAMPTZ,
    
    -- Ownership
    created_by      UUID            REFERENCES users(id),
    updated_by      UUID            REFERENCES users(id),
    
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_experiment_key_app UNIQUE (application_id, key),
    CONSTRAINT chk_coverage CHECK (coverage >= 0 AND coverage <= 1)
);

CREATE INDEX idx_experiments_status ON experiments(status) WHERE status IN ('running', 'paused');
CREATE INDEX idx_experiments_app ON experiments(application_id);
CREATE INDEX idx_experiments_key ON experiments(key);

COMMENT ON TABLE experiments IS 'Core experiment definitions. Each experiment belongs to one application and has a unique key within that application.';

-- =============================================================================
-- 5. VARIATIONS
-- =============================================================================

CREATE TABLE variations (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    experiment_id   UUID         NOT NULL REFERENCES experiments(id) ON DELETE CASCADE,
    key             VARCHAR(100) NOT NULL,               -- e.g., 'control', 'treatment', 'variant_a'
    name            VARCHAR(200) NOT NULL,               -- Display name
    description     TEXT,
    value           JSONB        NOT NULL,               -- The value returned to SDK (can be boolean, string, number, or JSON object)
    weight          DECIMAL(5,4) NOT NULL DEFAULT 0.5,   -- Traffic weight (0.0000 to 1.0000); all weights for an experiment must sum to 1.0
    sort_order      SMALLINT     NOT NULL DEFAULT 0,     -- Display order; also determines bucket assignment order
    is_control      BOOLEAN      NOT NULL DEFAULT FALSE,
    
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_variation_key_exp UNIQUE (experiment_id, key),
    CONSTRAINT chk_weight CHECK (weight >= 0 AND weight <= 1)
);

CREATE INDEX idx_variations_experiment ON variations(experiment_id);

COMMENT ON TABLE variations IS 'Experiment variations. Each experiment has 2+ variations. Weights must sum to 1.0. Value is the actual value delivered to the SDK.';

-- =============================================================================
-- 6. FEATURE FLAGS
-- =============================================================================

CREATE TABLE feature_flags (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    application_id  UUID         NOT NULL REFERENCES applications(id),
    key             VARCHAR(100) NOT NULL,
    name            VARCHAR(200) NOT NULL,
    description     TEXT,
    type            VARCHAR(20)  NOT NULL DEFAULT 'boolean',  -- 'boolean', 'string', 'integer', 'json'
    value           JSONB        NOT NULL,                     -- Current flag value
    default_value   JSONB        NOT NULL,                     -- Default value if flag is disabled
    is_enabled      BOOLEAN      NOT NULL DEFAULT FALSE,
    
    created_by      UUID         REFERENCES users(id),
    updated_by      UUID         REFERENCES users(id),
    
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_flag_key_app UNIQUE (application_id, key),
    CONSTRAINT chk_flag_type CHECK (type IN ('boolean', 'string', 'integer', 'json'))
);

CREATE INDEX idx_flags_app ON feature_flags(application_id);
CREATE INDEX idx_flags_enabled ON feature_flags(is_enabled) WHERE is_enabled = TRUE;

COMMENT ON TABLE feature_flags IS 'Feature flags independent of experiments. Simple on/off or value flags evaluated by the SDK.';

-- =============================================================================
-- 7. TARGETING RULES (attribute-based conditions)
-- =============================================================================

CREATE TABLE targeting_rules (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    experiment_id   UUID         REFERENCES experiments(id) ON DELETE CASCADE,
    flag_id         UUID         REFERENCES feature_flags(id) ON DELETE CASCADE,
    
    attribute       VARCHAR(100) NOT NULL,               -- e.g., 'platform', 'app_version', 'city'
    operator        VARCHAR(20)  NOT NULL,               -- e.g., 'eq', 'neq', 'gt', 'gte', 'lt', 'lte', 'in', 'not_in', 'contains', 'regex'
    value           JSONB        NOT NULL,               -- Target value(s); array for 'in'/'not_in' operators
    sort_order      SMALLINT     NOT NULL DEFAULT 0,     -- Evaluation order within experiment/flag
    
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

    -- Must belong to exactly one of experiment or flag
    CONSTRAINT chk_targeting_owner CHECK (
        (experiment_id IS NOT NULL AND flag_id IS NULL) OR
        (experiment_id IS NULL AND flag_id IS NOT NULL)
    ),
    CONSTRAINT chk_operator CHECK (operator IN ('eq', 'neq', 'gt', 'gte', 'lt', 'lte', 'in', 'not_in', 'contains', 'regex'))
);

CREATE INDEX idx_targeting_experiment ON targeting_rules(experiment_id) WHERE experiment_id IS NOT NULL;
CREATE INDEX idx_targeting_flag ON targeting_rules(flag_id) WHERE flag_id IS NOT NULL;

COMMENT ON TABLE targeting_rules IS 'Attribute-based targeting rules. Applied AFTER eligibility check. All rules for an experiment/flag are ANDed (Phase 1). Phase 2 adds OR logic.';

-- =============================================================================
-- 8. ELIGIBLE CLIENTS (file-upload targeting)
-- =============================================================================

CREATE TABLE eligible_clients (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    experiment_id   UUID         NOT NULL REFERENCES experiments(id) ON DELETE CASCADE,
    client_code     VARCHAR(50)  NOT NULL,
    
    upload_batch_id UUID         NOT NULL,                -- Groups all clients from a single upload
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_eligible_client UNIQUE (experiment_id, client_code)
);

-- Covering index for the primary lookup: "is this client eligible for this experiment?"
CREATE INDEX idx_eligible_client_lookup ON eligible_clients(client_code, experiment_id);

-- Index for batch operations (delete all clients from an upload)
CREATE INDEX idx_eligible_batch ON eligible_clients(upload_batch_id);

-- Index for experiment-scoped queries (list all eligible clients for an experiment)
CREATE INDEX idx_eligible_experiment ON eligible_clients(experiment_id);

COMMENT ON TABLE eligible_clients IS 'Client codes eligible for each experiment. Populated via CSV/Excel upload. Phase 2: also populated by data lake connector.';

-- =============================================================================
-- 9. CLIENT LIST UPLOADS (metadata for CSV/Excel uploads)
-- =============================================================================

CREATE TABLE client_list_uploads (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),  -- also used as upload_batch_id in eligible_clients
    experiment_id   UUID         NOT NULL REFERENCES experiments(id) ON DELETE CASCADE,
    
    file_name       VARCHAR(255) NOT NULL,
    file_size_bytes BIGINT       NOT NULL,
    s3_key          VARCHAR(500) NOT NULL,               -- S3 object key for the uploaded file
    
    total_rows      INTEGER      NOT NULL,
    valid_rows      INTEGER      NOT NULL,
    duplicate_rows  INTEGER      NOT NULL DEFAULT 0,
    invalid_rows    INTEGER      NOT NULL DEFAULT 0,
    
    status          VARCHAR(20)  NOT NULL DEFAULT 'pending',  -- 'pending', 'processing', 'completed', 'failed'
    error_message   TEXT,
    
    uploaded_by     UUID         REFERENCES users(id),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    completed_at    TIMESTAMPTZ,

    CONSTRAINT chk_upload_status CHECK (status IN ('pending', 'processing', 'completed', 'failed'))
);

CREATE INDEX idx_uploads_experiment ON client_list_uploads(experiment_id);

COMMENT ON TABLE client_list_uploads IS 'Metadata for each CSV/Excel upload of eligible client codes. Tracks validation results and S3 storage location.';

-- =============================================================================
-- 10. METRICS (PM-defined conversion metrics for experiments)
-- =============================================================================

CREATE TABLE metrics (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    application_id  UUID         NOT NULL REFERENCES applications(id),
    key             VARCHAR(100) NOT NULL,               -- Must match metricKey in conversion events
    name            VARCHAR(200) NOT NULL,
    description     TEXT,
    type            VARCHAR(20)  NOT NULL,               -- 'binary' or 'continuous'
    
    -- For sample size calculation
    minimum_detectable_effect  DECIMAL(10,6),            -- MDE as a proportion (e.g., 0.05 = 5% lift)
    
    created_by      UUID         REFERENCES users(id),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_metric_key_app UNIQUE (application_id, key),
    CONSTRAINT chk_metric_type CHECK (type IN ('binary', 'continuous'))
);

COMMENT ON TABLE metrics IS 'Reusable metric definitions. The metricKey in conversion events must match a metric key here for the stats engine to process it.';

-- =============================================================================
-- 11. EXPERIMENT METRICS (which metrics are tracked for which experiment)
-- =============================================================================

CREATE TABLE experiment_metrics (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    experiment_id   UUID         NOT NULL REFERENCES experiments(id) ON DELETE CASCADE,
    metric_id       UUID         NOT NULL REFERENCES metrics(id),
    is_primary      BOOLEAN      NOT NULL DEFAULT FALSE,  -- Primary success metric
    is_guardrail    BOOLEAN      NOT NULL DEFAULT FALSE,  -- Guardrail metric (must not regress)
    
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_experiment_metric UNIQUE (experiment_id, metric_id)
);

CREATE INDEX idx_exp_metrics_experiment ON experiment_metrics(experiment_id);

COMMENT ON TABLE experiment_metrics IS 'Associates metrics with experiments. Each experiment has one primary metric and zero or more guardrail metrics.';

-- =============================================================================
-- 12. FORCED VARIATIONS (QA overrides)
-- =============================================================================

CREATE TABLE forced_variations (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    experiment_id   UUID         NOT NULL REFERENCES experiments(id) ON DELETE CASCADE,
    client_code     VARCHAR(50)  NOT NULL,
    variation_key   VARCHAR(100) NOT NULL,               -- Must match a variation key in the experiment
    
    created_by      UUID         REFERENCES users(id),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_forced_variation UNIQUE (experiment_id, client_code)
);

CREATE INDEX idx_forced_experiment ON forced_variations(experiment_id);
CREATE INDEX idx_forced_client ON forced_variations(client_code);

COMMENT ON TABLE forced_variations IS 'QA overrides: force a specific client code into a specific variation. Bypasses normal hashing. Included in SDK config as forcedVariations map.';

-- =============================================================================
-- 13. AUDIT LOG
-- =============================================================================

CREATE TABLE audit_log (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    
    -- What changed
    entity_type     VARCHAR(50)  NOT NULL,               -- 'experiment', 'flag', 'variation', 'targeting_rule', 'eligible_clients', 'forced_variation', 'metric', 'api_key'
    entity_id       UUID         NOT NULL,
    action          VARCHAR(20)  NOT NULL,               -- 'created', 'updated', 'deleted', 'status_changed', 'uploaded'
    
    -- Change details
    changes         JSONB,                               -- { field: { old: value, new: value } }
    metadata        JSONB,                               -- Additional context (e.g., { "oldStatus": "draft", "newStatus": "running" })
    
    -- Who changed it
    actor_id        UUID         REFERENCES users(id),
    actor_email     VARCHAR(255),                        -- Denormalized for quick display
    
    -- When
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- Partition by month for performance (audit log grows indefinitely)
-- Note: Implement partitioning via pg_partman or manual PARTITION BY RANGE on created_at

CREATE INDEX idx_audit_entity ON audit_log(entity_type, entity_id);
CREATE INDEX idx_audit_actor ON audit_log(actor_id);
CREATE INDEX idx_audit_created ON audit_log(created_at);
CREATE INDEX idx_audit_action ON audit_log(entity_type, action);

COMMENT ON TABLE audit_log IS 'Immutable audit log of all changes to experiments, flags, targeting rules, and eligibility lists. Retained indefinitely.';

-- =============================================================================
-- 14. CONFIG VERSIONS (tracks config state for ETag versioning)
-- =============================================================================

CREATE TABLE config_versions (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    application_id  UUID         NOT NULL REFERENCES applications(id),
    version_hash    VARCHAR(64)  NOT NULL,               -- SHA-256 hash of serialized config state
    generated_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    trigger_entity  VARCHAR(50),                         -- What caused the version change
    trigger_id      UUID                                 -- ID of the entity that changed
);

CREATE INDEX idx_config_versions_app ON config_versions(application_id, generated_at DESC);

COMMENT ON TABLE config_versions IS 'History of config version changes. Current version is the most recent row per application. Also cached in Redis.';

-- =============================================================================
-- 15. HELPER FUNCTIONS
-- =============================================================================

-- Function to automatically update updated_at on row modification
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply to all tables with updated_at
CREATE TRIGGER trg_applications_updated_at BEFORE UPDATE ON applications FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER trg_users_updated_at BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER trg_experiments_updated_at BEFORE UPDATE ON experiments FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER trg_variations_updated_at BEFORE UPDATE ON variations FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER trg_flags_updated_at BEFORE UPDATE ON feature_flags FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER trg_targeting_updated_at BEFORE UPDATE ON targeting_rules FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER trg_metrics_updated_at BEFORE UPDATE ON metrics FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- =============================================================================
-- 16. SEED DATA
-- =============================================================================

-- Default application for Riise
INSERT INTO applications (key, name, description) VALUES 
('riise', 'Riise Trading App', 'MOFSL flagship mobile trading application (formerly MO Investor). Flutter-based, 40L+ customers.');
