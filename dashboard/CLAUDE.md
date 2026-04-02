# CLAUDE.md — Internal Dashboard Module

> **This file is read automatically by Claude Code** when working in the `/dashboard` directory.
> Read the root `/CLAUDE.md` first for project-wide conventions.

---

## What This Module Is

A Next.js (App Router) internal dashboard for MOFSL Product Managers to manage experiments, feature flags, client targeting lists, and view experiment results. This is an internal tool — only MOFSL employees access it via SSO.

---

## Project Structure

```
dashboard/
├── CLAUDE.md                          ← you are here
├── src/
│   ├── app/
│   │   ├── layout.tsx                 ← root layout (sidebar, auth provider)
│   │   ├── page.tsx                   ← dashboard home / overview
│   │   ├── login/
│   │   │   └── page.tsx               ← SSO redirect page
│   │   ├── experiments/
│   │   │   ├── page.tsx               ← experiment list
│   │   │   ├── new/
│   │   │   │   └── page.tsx           ← creation wizard
│   │   │   └── [id]/
│   │   │       ├── page.tsx           ← experiment detail + live results
│   │   │       ├── settings/
│   │   │       │   └── page.tsx       ← experiment settings (targeting, traffic)
│   │   │       └── results/
│   │   │           └── page.tsx       ← full results page
│   │   ├── flags/
│   │   │   ├── page.tsx               ← flag list
│   │   │   └── [id]/
│   │   │       └── page.tsx           ← flag detail
│   │   ├── metrics/
│   │   │   └── page.tsx               ← metric definitions
│   │   ├── audit-log/
│   │   │   └── page.tsx               ← audit log viewer
│   │   └── docs/
│   │       ├── page.tsx               ← SDK docs landing
│   │       ├── getting-started/
│   │       ├── api-reference/
│   │       ├── integration-guide/
│   │       └── changelog/
│   ├── components/
│   │   ├── ui/                        ← base UI components (shadcn/ui)
│   │   │   ├── button.tsx
│   │   │   ├── input.tsx
│   │   │   ├── select.tsx
│   │   │   ├── table.tsx
│   │   │   ├── badge.tsx
│   │   │   ├── card.tsx
│   │   │   ├── dialog.tsx
│   │   │   ├── toast.tsx
│   │   │   └── ...
│   │   ├── layout/
│   │   │   ├── sidebar.tsx
│   │   │   ├── header.tsx
│   │   │   └── breadcrumb.tsx
│   │   ├── experiments/
│   │   │   ├── experiment-list.tsx
│   │   │   ├── experiment-card.tsx
│   │   │   ├── creation-wizard.tsx
│   │   │   ├── status-badge.tsx
│   │   │   ├── traffic-allocation.tsx
│   │   │   └── variation-editor.tsx
│   │   ├── flags/
│   │   │   ├── flag-list.tsx
│   │   │   ├── flag-toggle.tsx
│   │   │   └── flag-value-editor.tsx
│   │   ├── targeting/
│   │   │   ├── client-upload.tsx
│   │   │   ├── upload-preview.tsx
│   │   │   ├── targeting-rules.tsx
│   │   │   └── rule-builder.tsx
│   │   ├── results/
│   │   │   ├── results-summary.tsx
│   │   │   ├── significance-badge.tsx
│   │   │   ├── time-series-chart.tsx
│   │   │   ├── metric-card.tsx
│   │   │   └── winner-banner.tsx
│   │   └── audit/
│   │       └── audit-log-table.tsx
│   ├── lib/
│   │   ├── api.ts                     ← API client (fetch wrapper)
│   │   ├── auth.ts                    ← SSO auth helpers
│   │   ├── hooks/
│   │   │   ├── use-experiments.ts     ← SWR hook for experiments
│   │   │   ├── use-flags.ts
│   │   │   ├── use-results.ts
│   │   │   └── use-audit-log.ts
│   │   ├── types/
│   │   │   ├── experiment.ts          ← TypeScript types (shared with backend models)
│   │   │   ├── flag.ts
│   │   │   ├── results.ts
│   │   │   └── api.ts
│   │   └── utils/
│   │       ├── format.ts              ← Number/date formatting
│   │       └── constants.ts           ← Status labels, color mappings
│   └── styles/
│       └── globals.css                ← Tailwind base + custom variables
├── public/
│   └── ...
├── Dockerfile
├── next.config.js
├── tailwind.config.ts
├── tsconfig.json
├── package.json
└── .env.example
```

---

## Tech Stack

| Tool | Purpose |
|---|---|
| Next.js 14+ (App Router) | Framework |
| React 18 | UI library |
| TypeScript | Type safety |
| Tailwind CSS | Styling |
| shadcn/ui | Base component library (copy-paste, not npm — fully customizable) |
| SWR | Data fetching + caching (mutations, revalidation) |
| Recharts | Charts for results visualization |
| zod | Client-side form validation |
| react-hook-form | Form state management |
| date-fns | Date formatting |
| papaparse | CSV preview on upload |

---

## Pages Inventory

| Page | Path | Description |
|---|---|---|
| Dashboard Home | `/` | Overview: active experiments count, recent changes, quick actions |
| Experiment List | `/experiments` | Filterable table (status, date range, search by key/name) |
| Create Experiment | `/experiments/new` | Multi-step wizard |
| Experiment Detail | `/experiments/[id]` | Status, variations, targeting, live results summary |
| Experiment Results | `/experiments/[id]/results` | Full results: significance, time-series, per-metric breakdown, CSV export |
| Experiment Settings | `/experiments/[id]/settings` | Edit targeting, traffic, upload client list |
| Flag List | `/flags` | All flags with toggle switches |
| Flag Detail | `/flags/[id]` | Edit value, targeting rules, evaluation preview |
| Metrics | `/metrics` | Define reusable metrics |
| Audit Log | `/audit-log` | Searchable, filterable log of all changes |
| SDK Docs | `/docs/*` | Getting started, API reference, integration guide, sample app, changelog |

---

## Experiment Creation Wizard (Multi-Step)

**Step 1 — Basics:**
- Key (auto-generated from name, editable, validated: lowercase + underscores only)
- Name
- Description (optional)
- Hypothesis (optional)

**Step 2 — Variations:**
- Minimum 2 variations
- First variation auto-labeled "control" with `isControl: true`
- Each variation: key, name, value (type depends on experiment), weight
- Weight sliders with visual bar — must sum to 100%
- "Split evenly" button

**Step 3 — Metrics:**
- Select primary metric (required, exactly one)
- Select guardrail metrics (optional, zero or more)
- Metrics are selected from the global metrics list (created in `/metrics`)

**Step 4 — Targeting:**
- Traffic allocation slider (0–100% → coverage field)
- Client list upload (CSV/Excel) — optional
- Attribute targeting rules (optional)

**Step 5 — Review & Launch:**
- Summary of all settings
- "Save as Draft" or "Launch" buttons
- Confirm dialog before launching

---

## API Integration

All API calls go through a centralized client in `lib/api.ts`:

```typescript
const api = {
  async get<T>(path: string): Promise<T> {
    const res = await fetch(`${API_BASE_URL}${path}`, {
      headers: { 'Authorization': `Bearer ${getToken()}` },
    });
    if (!res.ok) throw new ApiError(res.status, await res.json());
    return res.json();
  },
  async post<T>(path: string, body: unknown): Promise<T> { ... },
  async put<T>(path: string, body: unknown): Promise<T> { ... },
  async delete(path: string): Promise<void> { ... },
};
```

**Data fetching:** Use SWR hooks for all read operations. SWR handles caching, revalidation, and loading states.

```typescript
function useExperiments(filters?: ExperimentFilters) {
  return useSWR(
    ['/api/v1/experiments', filters],
    ([url, f]) => api.get(url, { params: f })
  );
}
```

**Mutations:** Use SWR's `mutate` for optimistic updates after writes.

---

## Authentication Flow

1. User visits dashboard → `auth.ts` middleware checks for valid session cookie
2. No session → redirect to MOFSL SSO login page
3. User authenticates with SSO → redirected back to `/login?code={authCode}`
4. `/login` page exchanges auth code for JWT → stores JWT in HTTP-only cookie
5. All subsequent API calls include `Authorization: Bearer {jwt}` header
6. JWT expiry → redirect to SSO for re-authentication

**Never store tokens in localStorage or sessionStorage.** Use HTTP-only, secure, SameSite cookies only.

---

## Results Visualization

The results page is the most complex UI. It displays:

**Summary cards (per variation):**
- Unique users (sample size)
- Metric value (conversion rate or mean)
- Relative lift vs control (with CI)
- P-value
- Significance badge: "Significant" (green), "Not Significant" (gray), "Insufficient Data" (yellow)

**Winner banner:** Shown only when primary metric is statistically significant AND minimum sample size is reached.

**Time-series chart (Recharts):**
- X-axis: date
- Y-axis: metric value
- One line per variation
- Tooltip with daily values

**Per-metric breakdown:** Table with all metrics (primary + guardrails), each showing variation values, lift, CI, p-value.

**CSV export button:** Downloads raw per-variation metrics as CSV.

---

## Status Badge Colors

| Status | Color | Label |
|---|---|---|
| `draft` | Gray | Draft |
| `running` | Green | Running |
| `paused` | Yellow/Amber | Paused |
| `completed` | Blue | Completed |
| `archived` | Gray (muted) | Archived |

---

## File Upload Component

For CSV/Excel upload of client codes:

1. Drag-and-drop zone or file picker
2. Client-side preview: parse first 100 rows with `papaparse`, show in table
3. Show validation summary: total rows, valid, duplicates, invalid
4. "Confirm Upload" button → sends file to backend
5. Progress bar during upload
6. Success/error state after completion

**Accepted formats:** `.csv`, `.xlsx`, `.xls`
**Max file size:** 50 MB
**Max rows:** 1,000,000

---

## Design Principles

- **Clean, data-dense UI** — this is a PM tool, not a consumer app. Prioritize information density over white space.
- **No onboarding flows** — all users are MOFSL employees who will be trained
- **Fast navigation** — sidebar always visible, breadcrumbs for deep pages
- **Confirmation dialogs** for destructive actions (launch, pause, complete, delete)
- **Toast notifications** for success/error feedback
- **Loading skeletons** over spinners (use SWR's `isLoading` state)
- **Empty states** with clear CTAs ("No experiments yet. Create your first experiment.")

---

## What NOT To Do in This Module

- **Never store auth tokens in localStorage/sessionStorage** — use HTTP-only cookies
- **Never call ClickHouse or Kafka directly** — all data flows through the backend API
- **Never implement business logic in the frontend** — experiment lifecycle validation, stats computation, and eligibility checking all happen in the backend
- **Never use client-side routing for auth** — SSO redirects must be server-side
- **Never embed SDK documentation as static markdown** — use MDX or a docs framework that supports versioning and search
- **Never skip loading/error states** — every API call must handle loading, success, and error
- **Never hardcode API URLs** — use environment variables (`NEXT_PUBLIC_API_URL`)
