# Skill: File-Based Targeting & Eligibility Service

> **Purpose:** This file teaches Claude Code how the eligibility system works — how PMs upload CSV files of client codes, how the backend validates and stores them, how the config server checks eligibility at serving time, and how the interface is designed for Phase 2 data lake swap.

---

## The Problem

PMs need to run experiments on specific user segments. Example: "Run this new order flow only for users in Mumbai who trade F&O." In Phase 1, we don't have a data lake connector, so PMs export a list of client codes from their internal tools and upload it as a CSV/Excel file.

---

## Eligibility Service Interface

This is the central abstraction. The config generator depends ONLY on this interface — never on the implementation.

```typescript
interface EligibilityService {
  /**
   * Check if a single client is eligible for a specific experiment.
   * Returns true if eligible, false if not.
   * Returns true if the experiment has NO eligibility list (open to all).
   */
  isEligible(clientCode: string, experimentId: string): Promise<boolean>;
  
  /**
   * Get all experiment IDs that a client is eligible for.
   * Includes experiments with no eligibility list (open to all).
   */
  getEligibleExperimentIds(clientCode: string): Promise<string[]>;
  
  /**
   * Check eligibility for multiple experiments in one call.
   * Used by config generator to batch the eligibility check.
   */
  bulkCheckEligibility(
    clientCode: string,
    experimentIds: string[]
  ): Promise<Map<string, boolean>>;
}
```

### Critical Rule: No Eligibility List = Open to All

If an experiment has ZERO rows in the `eligible_clients` table, it means the PM did not upload a targeting list. In this case, ALL users are eligible. This is the default — targeting is opt-in, not opt-out.

```typescript
// In FileUploadEligibilityService:
async isEligible(clientCode: string, experimentId: string): Promise<boolean> {
  // Check if this experiment has any eligibility list at all
  const hasEligibilityList = await this.db.query(
    'SELECT EXISTS(SELECT 1 FROM eligible_clients WHERE experiment_id = $1) AS has_list',
    [experimentId]
  );
  
  // No list means open to everyone
  if (!hasEligibilityList.rows[0].has_list) return true;
  
  // Has a list — check if this client is in it
  const result = await this.db.query(
    'SELECT EXISTS(SELECT 1 FROM eligible_clients WHERE experiment_id = $1 AND client_code = $2) AS eligible',
    [experimentId, clientCode]
  );
  
  return result.rows[0].eligible;
}
```

---

## CSV Upload Pipeline

### Step 1: File Upload (Dashboard → Backend)

1. PM clicks "Upload Client List" in the experiment settings page
2. Dashboard shows drag-and-drop zone accepting `.csv`, `.xlsx`, `.xls`
3. Client-side preview: parse first 100 rows, show in table
4. PM clicks "Upload"
5. File is sent to `POST /api/v1/experiments/:id/eligible-clients/upload` as `multipart/form-data`

### Step 2: Server-Side Processing

```typescript
// In upload.service.ts

async processUpload(experimentId: string, file: Express.Multer.File, userId: string) {
  // 1. Upload raw file to S3 for audit trail
  const s3Key = `uploads/${experimentId}/${Date.now()}_${file.originalname}`;
  await s3.upload(s3Key, file.buffer);
  
  // 2. Create upload record
  const upload = await db.query(
    `INSERT INTO client_list_uploads 
     (id, experiment_id, file_name, file_size_bytes, s3_key, total_rows, valid_rows, status, uploaded_by)
     VALUES ($1, $2, $3, $4, $5, 0, 0, 'processing', $6)
     RETURNING id`,
    [uuid(), experimentId, file.originalname, file.size, s3Key, userId]
  );
  const uploadId = upload.rows[0].id;
  
  // 3. Parse file
  const clientCodes = await parseFile(file); // handles CSV and Excel
  
  // 4. Validate
  const { valid, duplicates, invalid } = validate(clientCodes);
  
  // 5. Bulk insert valid codes
  await bulkInsertEligibleClients(experimentId, uploadId, valid);
  
  // 6. Update upload record with results
  await db.query(
    `UPDATE client_list_uploads 
     SET total_rows = $1, valid_rows = $2, duplicate_rows = $3, invalid_rows = $4, 
         status = 'completed', completed_at = NOW()
     WHERE id = $5`,
    [clientCodes.length, valid.length, duplicates.length, invalid.length, uploadId]
  );
  
  // 7. Audit log
  await auditService.log({ entityType: 'eligible_clients', entityId: experimentId, action: 'uploaded', ... });
  
  // 8. Invalidate Redis config cache (eligibility changed)
  await cacheService.invalidateConfigsForExperiment(experimentId);
  
  return { totalRows: clientCodes.length, validRows: valid.length, ... };
}
```

### Step 3: File Parsing

```typescript
async function parseFile(file: Express.Multer.File): Promise<string[]> {
  const ext = path.extname(file.originalname).toLowerCase();
  
  if (ext === '.csv') {
    return parseCsv(file.buffer);
  } else if (ext === '.xlsx' || ext === '.xls') {
    return parseExcel(file.buffer);
  }
  
  throw new AppError(400, 'unsupported_format', 'Only CSV and Excel files are supported');
}

function parseCsv(buffer: Buffer): string[] {
  // Use csv-parse library
  // Accept single column (just client codes) or multi-column (first column is client code)
  // Skip header row if detected
  // Trim whitespace from each value
  // Return array of client code strings
}

function parseExcel(buffer: Buffer): string[] {
  // Use xlsx library
  // Read first sheet only
  // Same rules as CSV: first column, skip header, trim
}
```

### Step 4: Validation

```typescript
interface ValidationResult {
  valid: string[];
  duplicates: string[];
  invalid: string[];
}

function validate(clientCodes: string[]): ValidationResult {
  const valid: string[] = [];
  const duplicates: string[] = [];
  const invalid: string[] = [];
  const seen = new Set<string>();
  
  for (const raw of clientCodes) {
    const code = raw.trim();
    
    // Empty after trim
    if (!code) continue;
    
    // Format validation: alphanumeric, 1-50 chars
    if (!/^[A-Za-z0-9]{1,50}$/.test(code)) {
      invalid.push(code);
      continue;
    }
    
    // Duplicate within this file
    if (seen.has(code)) {
      duplicates.push(code);
      continue;
    }
    
    seen.add(code);
    valid.push(code);
  }
  
  return { valid, duplicates, invalid };
}
```

**Validation rules:**
- Client code must be 1–50 characters, alphanumeric only
- Empty rows are silently skipped
- Duplicate codes within the same file are flagged and skipped
- Duplicate codes that already exist in the database for this experiment are handled by the `UNIQUE (experiment_id, client_code)` constraint — use `ON CONFLICT DO NOTHING`
- Max 1,000,000 rows per upload

### Step 5: Bulk Insert

```typescript
async function bulkInsertEligibleClients(
  experimentId: string, 
  uploadBatchId: string, 
  clientCodes: string[]
): Promise<void> {
  // Batch insert in chunks of 5000 to avoid query size limits
  const BATCH_SIZE = 5000;
  
  for (let i = 0; i < clientCodes.length; i += BATCH_SIZE) {
    const batch = clientCodes.slice(i, i + BATCH_SIZE);
    
    // Generate VALUES clause
    const values = batch.map((code, idx) => {
      const offset = idx * 3;
      return `($${offset + 1}, $${offset + 2}, $${offset + 3})`;
    }).join(', ');
    
    const params = batch.flatMap(code => [uuid(), experimentId, code]);
    // Note: uploadBatchId should be included — adjust params accordingly
    
    await db.query(
      `INSERT INTO eligible_clients (id, experiment_id, client_code, upload_batch_id)
       VALUES ${values}
       ON CONFLICT (experiment_id, client_code) DO NOTHING`,
      params
    );
  }
}
```

---

## PostgreSQL Schema (Reference)

```sql
CREATE TABLE eligible_clients (
    id              UUID PRIMARY KEY,
    experiment_id   UUID NOT NULL REFERENCES experiments(id) ON DELETE CASCADE,
    client_code     VARCHAR(50) NOT NULL,
    upload_batch_id UUID NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_eligible_client UNIQUE (experiment_id, client_code)
);

CREATE INDEX idx_eligible_client_lookup ON eligible_clients(client_code, experiment_id);
CREATE INDEX idx_eligible_batch ON eligible_clients(upload_batch_id);
CREATE INDEX idx_eligible_experiment ON eligible_clients(experiment_id);
```

Key index: `idx_eligible_client_lookup` on `(client_code, experiment_id)` — this is the primary lookup path used by the config generator ("is client X eligible for experiment Y?").

---

## Config Generator Integration

When the config server builds a config payload for a client:

```typescript
// In config-generator.service.ts
async generateConfig(clientCode: string, attributes: Record<string, any>, appId: string) {
  // 1. Get all active experiments for this application
  const experiments = await experimentRepo.findActiveByAppId(appId);
  
  // 2. Bulk check eligibility for ALL experiments at once (single query)
  const experimentIds = experiments.map(e => e.id);
  const eligibility = await eligibilityService.bulkCheckEligibility(clientCode, experimentIds);
  
  // 3. Filter to eligible experiments
  const eligible = experiments.filter(e => eligibility.get(e.id));
  
  // 4. For eligible experiments, evaluate targeting rules
  const targeted = eligible.filter(e => 
    targetingService.evaluateRules(e.targetingRules, attributes)
  );
  
  // 5. Build config payload (variations, weights, coverage, etc.)
  return buildPayload(targeted, clientCode);
}
```

The `bulkCheckEligibility` call is optimized to be a single SQL query:

```sql
SELECT experiment_id, 
       EXISTS(SELECT 1 FROM eligible_clients WHERE experiment_id = e.id AND client_code = $1) AS has_match,
       EXISTS(SELECT 1 FROM eligible_clients WHERE experiment_id = e.id LIMIT 1) AS has_list
FROM experiments e
WHERE e.id = ANY($2)
```

Logic: If `has_list` is false → eligible (open experiment). If `has_list` is true and `has_match` is true → eligible. Otherwise → not eligible.

---

## Replacing/Updating an Eligibility List

When a PM uploads a new list for an experiment that already has one:

**Option A (Replace — default):** Delete all existing eligible clients for this experiment, then insert the new list. This is a single transaction:

```sql
BEGIN;
DELETE FROM eligible_clients WHERE experiment_id = $1;
INSERT INTO eligible_clients (id, experiment_id, client_code, upload_batch_id) VALUES ...;
COMMIT;
```

**Option B (Append):** Add new client codes without removing existing ones. The `ON CONFLICT DO NOTHING` handles duplicates.

The dashboard should let the PM choose "Replace existing list" or "Add to existing list."

---

## Phase 2: Data Lake Swap

In Phase 2, the `FileUploadEligibilityService` will be supplemented (not replaced) by a `DataLakeEligibilityService`. The swap is clean because:

1. Both implement the same `EligibilityService` interface
2. The config generator depends only on the interface
3. Each experiment can be configured to use either source:
   - File upload: `eligibility_source = 'file'` (Phase 1, continues to work)
   - Data lake: `eligibility_source = 'data_lake'` (Phase 2)
   - None: `eligibility_source = null` (open to all users)

```typescript
// Phase 2 factory pattern
function getEligibilityService(experiment: Experiment): EligibilityService {
  switch (experiment.eligibilitySource) {
    case 'file': return new FileUploadEligibilityService(db);
    case 'data_lake': return new DataLakeEligibilityService(dataLakeClient);
    default: return new OpenEligibilityService(); // always returns true
  }
}
```

To prepare for this in Phase 1:
- Keep the `EligibilityService` interface clean and stable
- Never reference `eligible_clients` table directly outside of `FileUploadEligibilityService`
- Never add file-upload-specific methods to the interface

---

## Edge Cases to Handle

| Scenario | Expected Behavior |
|---|---|
| Upload with 0 valid rows | Return error, don't clear existing list |
| Upload with >1M rows | Return 413 error before processing |
| CSV with BOM (byte order mark) | Strip BOM before parsing |
| Excel with multiple sheets | Read first sheet only, ignore others |
| Excel with merged cells | Unmerge and read individual cells |
| Client code with leading/trailing spaces | Trim automatically |
| Client code with special characters | Reject (alphanumeric only) |
| Empty file | Return error with "file is empty" message |
| Corrupt Excel file | Return error with "unable to parse file" message |
| Upload during active experiment | Allow — new list takes effect on next config refresh |
| Delete experiment | `ON DELETE CASCADE` removes all eligible clients |
