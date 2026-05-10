# RunCache Billing & Revenue — Migration Runbook
**Epic:** RD-1161737 · RD-1160536
**Author:** Prabal Saha
**Last updated:** 2026-04-06
**Status:** Phase 1 in QA — E2E target Apr 7–11

---

## Overview

This runbook covers the two-phase migration to introduce RunCache billing into the
existing Fivetran billing pipeline (BigQuery → Celigo → NetSuite).

| Phase | Scope | Status |
|---|---|---|
| Phase 1 | New tables, new pipelines, RunCache exclusion guards on existing pipelines | In QA |


**Pipeline separation:**
- Fivetran OLP will never source RunCache transactions by design (confirmed by Product) — the `NOT EXISTS` guard is defense-in-depth, not the primary separation mechanism
- RunCache uses `INNER JOIN run_cache_accounts` as an allowlist to scope its own pipeline
- The `NOT EXISTS` guard remains in place as an explicit safeguard and audit signal

---

## Pre-Migration: Open Items (Must Resolve Before Phase 1)

| # | Item | Owner | Status |
|---|---|---|---|
| P0 | Confirm `product_type` value in prod: `RUN_CACHE` or `DBT_RUN_CACHE`? | Backend | ✅ Resolved — `DBT_RUN_CACHE` (confirmed from compiled staging SQL) |
| P0 | Deploy `run_cache_accounts` to staging (dulcet-yew-246109) | Backend | ⏳ Open |
| P0 | Stripe ↔ NetSuite sandbox integration active (see Blocker section) | Backend + SysEng | ⏳ Blocked |
| P1 | Grant BigQuery Data Viewer on `netsuite2` to `dulcet-yew-246109` SA | GCP Admin | ⏳ Open |
| P1 | Grant SA permissions on `internal-analytics-data-access` | GCP Admin | ⏳ Open |
| P1 | Confirm `private-internal` vs `internal-analytics-data-access` project name | Infra | ⏳ Open |

---

## Active Blocker

**Stripe ↔ NetSuite integration not active in sandbox.**

The payment flow requires:
1. `BigQueryToAppRunCacheSync` creates a `run_cache_accounts` record and an `account_billing_info` record with `stripe_customer_id`
2. NetSuite stamps customer metadata back to Stripe via `billing_profile_id` in Stripe customer metadata
3. When an invoice is generated in NetSuite, it charges via `stripe_customer_id`
4. NetSuite creates the corresponding payment record

Without this integration active in sandbox, E2E payment reconciliation cannot be validated.
**Nothing moves to production until this is confirmed working end-to-end.**

---

## Phase 1 — Deployment Sequence

> Deploy in this exact order. Each step has a validation check before proceeding.

### Step 1 — Backend: Schema Changes in Fivetran Prod DB

**Owner:** Backend team
**Prereq:** None

```sql
-- 1a. Create run_cache_accounts table
CREATE TABLE `digital-arbor-400`.pg_public.run_cache_accounts (
  run_cache_org_id  TEXT PRIMARY KEY,
  billing_info_id   TEXT REFERENCES `digital-arbor-400`.pg_public.account_billing_info(id)
);

-- 1b. Add columns to account_billing_info
ALTER TABLE `digital-arbor-400`.pg_public.account_billing_info
  ADD COLUMN id                TEXT,
  ADD COLUMN stripe_customer_id TEXT,
  ADD CONSTRAINT uq_abi_account_id UNIQUE (account_id);

-- 1c. Backfill account_billing_info.id from accounts
-- (Backend team to confirm backfill strategy)

-- 1d. Drop stripe_customer_id from accounts (AFTER backfill confirmed)
ALTER TABLE `digital-arbor-400`.pg_public.accounts DROP COLUMN stripe_customer_id;
ALTER TABLE `digital-arbor-400`.pg_public.accounts DROP CONSTRAINT accounts_billing_account_id_fkey;
```

**Validation:**
```sql
-- Confirm columns exist
SELECT column_name FROM information_schema.columns
WHERE table_name = 'account_billing_info'
AND column_name IN ('id', 'stripe_customer_id');

-- Confirm run_cache_accounts exists and is empty (pre-data)
SELECT COUNT(*) FROM `digital-arbor-400`.pg_public.run_cache_accounts;
```

---

### Step 2 — Backend: Deploy Java Tasks

**Owner:** Backend team
**Prereq:** Step 1 complete

Deploy in order:
1. **`BigQueryToAppRunCacheSync`** — provisions `run_cache_accounts` + `account_billing_info` on new RunCache org detection
2. **`FillRunCacheRevenue`** — daily task that writes `product_type = 'RUN_CACHE'` rows to `revenue_records` with pricing curve applied

**Validation:**
```sql
-- At least one RunCache org provisioned
SELECT * FROM `digital-arbor-400`.pg_public.run_cache_accounts LIMIT 5;

-- Revenue records with RUN_CACHE product_type present
SELECT COUNT(*) FROM `digital-arbor-400`.pg_public.revenue_records
WHERE product_type = 'RUN_CACHE';
```

---

### Step 3 — SysEng: Deploy Fivetran OLP Pipeline Guards

**Owner:** SysEng (Prabal)
**Prereq:** Step 1 complete (run_cache_accounts table must exist for NOT EXISTS to work)
**Files:** `001_account_sync_v2.sql`, `002_subscription_sync_v2.sql`

> **Note:** Product has confirmed the Fivetran OLP pipeline will never source RunCache transactions by design. The `NOT EXISTS` guards below are **defense-in-depth** — they make the exclusion explicit, auditable, and resilient to future schema changes.

Deploy the refactored pipelines with RunCache exclusion guards:

| Pipeline | Guard | Purpose |
|---|---|---|
| `001_account_sync_v2.sql` | `NOT EXISTS (run_cache_accounts WHERE billing_info_id = acct_info.id)` | Explicit audit signal — defense-in-depth |
| `002_subscription_sync_v2.sql` | `NOT EXISTS (run_cache_accounts WHERE billing_info_id = ls.billing_account_id)` | Explicit audit signal — defense-in-depth |

**Validation:**
```sql
-- Zero RunCache accounts in Fivetran account sync output
SELECT COUNT(*) FROM share_celigo.run_cache_account_sync_v2
WHERE billing_account_id IN (
  SELECT billing_info_id FROM `digital-arbor-400`.pg_public.run_cache_accounts
);
-- Expected: 0

-- Fivetran OLP row count unchanged vs pre-deploy baseline
SELECT COUNT(*) FROM share_celigo.olp_and_overage_monthly_billing;
-- Compare to pre-deploy count — must be equal
```

---

### Step 4 — SysEng: Deploy RunCache Celigo Pipelines

**Owner:** SysEng (Prabal)
**Prereq:** Steps 1–3 complete, `run_cache_accounts` has data, Stripe ↔ NetSuite integration active

Wire Celigo flows:

| Flow | Source view | NetSuite destination |
|---|---|---|
| RunCache Customer | `share_celigo.run_cache_account_sync_v2` | Customer record |
| RunCache Invoice | `share_celigo.monthly_run_cache_revenue_v2` | Invoice / Credit Memo |

**Celigo configuration:**
- External ID prefix: `RCINV` (invoices), `RCCM` (credit memos)
- Payment term: always `Autopay`
- Item: `RunCache_2026` (NetSuite item ID from `netsuite2.item WHERE name = 'RunCache_2026'`)
- `billing_sync` tag: `monthly_run_cache_revenue_v2`

**Validation:**
```sql
-- RunCache invoices visible in NetSuite with correct external_id prefix
SELECT external_id, netsuite_customer_id, amount, transaction_type
FROM share_celigo.monthly_run_cache_revenue_v2
WHERE external_id LIKE 'RCINV%' OR external_id LIKE 'RCCM%'
LIMIT 10;

-- No RCINV/RCCM in Fivetran OLP output (isolation check)
SELECT COUNT(*) FROM share_celigo.olp_and_overage_monthly_billing
WHERE external_id LIKE 'RCINV%' OR external_id LIKE 'RCCM%';
-- Expected: 0
```

---

### Step 5 — SysEng + Finance: UAT

**Owner:** Prabal + Jessica Wu (Finance)
**Prereq:** Steps 1–4 complete

Finance UAT checklist:
- [ ] `RCINV` invoices visible in NetSuite, separate from Fivetran `CBPINV` invoices
- [ ] `RCCM` credit memos visible and correct
- [ ] Customer Category = Self-Service on all RunCache customers
- [ ] Sales Rep = self-service employee record (not System account)
- [ ] Source System = "RunCache" on all invoice records
- [ ] RR Start/End dates = Service Start/End dates
- [ ] Fivetran Subscription ID populated
- [ ] GL account 40116 (Revenue: Fivetran Self Service: RunCache) receiving postings
- [ ] Payment term = Autopay on all RunCache invoices
- [ ] Charge flows through Stripe successfully on test invoice

---

### Step 6 — SysEng: Deploy Revenue Pipeline

**Owner:** SysEng (Prabal)
**Prereq:** UAT complete, `product_type` value in prod confirmed

```
Deploy: monthly_run_cache_revenue_v2.sql (DBT — runs monthly)
```

> ⚠️ Do NOT deploy before Phase 1 schema is confirmed complete.
> `run_cache_accounts` and `account_billing_info.id` must exist in prod.

**Validation:**
```sql
-- Confirm product_type value (must match what FillRunCacheRevenue writes)
SELECT DISTINCT product_type FROM stg_pg_public_revenue_records
WHERE product_type LIKE '%RUN%' OR product_type LIKE '%CACHE%';

-- Revenue pipeline produces rows
SELECT COUNT(*), MIN(revenue_month_start), MAX(revenue_month_start)
FROM share_celigo.monthly_run_cache_revenue_v2;

-- No Fivetran OLP accounts in RunCache output
SELECT COUNT(*) FROM share_celigo.monthly_run_cache_revenue_v2 rc
WHERE NOT EXISTS (
  SELECT 1 FROM `digital-arbor-400`.pg_public.run_cache_accounts
  WHERE billing_info_id = rc.billing_account_id
);
-- Expected: 0
```

---

## Phase 1 — Go / No-Go Criteria

| Criterion | Check |
|---|---|
| `run_cache_accounts` has RunCache org data | `SELECT COUNT(*) > 0` |
| `product_type = 'DBT_RUN_CACHE'` confirmed in revenue_records | Query above |
| Fivetran OLP row count unchanged | Compare pre/post counts |
| Zero RunCache accounts in Fivetran OLP output (defense-in-depth check) | Isolation queries above |
| At least one invoice end-to-end in staging | Manual UAT |
| Stripe charge confirmed on test invoice | Finance sign-off |
| `prepaid_revenue_recognition_journal_monthly` guard in place | Code review |

---

## DBT Migration

### Project Structure

| Field | Value |
|---|---|
| Project name | `syseng_run_cache_monthly_billing` |
| Profile name | `syseng_run_cache_monthly_billing` |
| Model directory | `sql/run_cache/` |
| Materialization | Views |
| Target schema | `share_celigo` |
| Compute project | `internal-analytics-data-access` |

### Profiles

Two profiles are required — one per environment. Add both to `~/.dbt/profiles.yml` (or `sql/profiles_template.yml` as a reference):

```yaml
syseng_run_cache_monthly_billing:
  target: staging
  outputs:

    staging:
      type: bigquery
      method: oauth
      project: dulcet-yew-246109
      dataset: share_celigo
      location: US
      threads: 4
      job_project: internal-analytics-data-access

    production:
      type: bigquery
      method: oauth
      project: digital-arbor-400
      dataset: share_celigo
      location: US
      threads: 4
      job_project: internal-analytics-data-access
```

### Model File Inventory

| Model | File | Target view | Phase |
|---|---|---|---|
| `run_cache_account_sync_v2` | `sql/run_cache/run_cache_account_sync_v2.sql` | `share_celigo.run_cache_account_sync_v2` | Phase 1 |
| `monthly_run_cache_revenue_v2` | `sql/run_cache/monthly_run_cache_revenue_v2.sql` | `share_celigo.monthly_run_cache_revenue_v2` | Phase 1 |

### Critical: `product_type` Value

**`product_type = 'DBT_RUN_CACHE'`** — confirmed from compiled staging SQL.

This value is hardcoded in `monthly_run_cache_revenue_v2.sql`. The backend `FillRunCacheRevenue` Java task must write the **same value** to `revenue_records.product_type`. If there is a mismatch (e.g. backend writes `RUN_CACHE`), the revenue pipeline will produce zero rows.

**Validation query:**
```sql
SELECT DISTINCT product_type
FROM stg_pg_public_revenue_records
WHERE product_type LIKE '%RUN%' OR product_type LIKE '%CACHE%';
-- Expected: DBT_RUN_CACHE
```

### Run Commands

```bash
# Navigate to DBT project root
cd sql/dbt_migration   # or wherever dbt_project.yml lives

# Staging (default target)
dbt run

# Run a single model
dbt run --select monthly_run_cache_revenue_v2

# Production target
dbt run --target production

# Compile only (no execution — useful to inspect generated SQL)
dbt compile --select monthly_run_cache_revenue_v2

# Test sources
dbt test --select source:pg_public
```

### DBT Deployment Sequence

Deploy DBT models **after** the backend schema changes (Step 1) and Java tasks (Step 2) are complete.

| Order | Command | Prereq | Validation |
|---|---|---|---|
| 1 | `dbt run --target staging --select run_cache_account_sync_v2` | `run_cache_accounts` populated in staging | View exists in `dulcet-yew-246109.share_celigo` |
| 2 | `dbt run --target staging --select monthly_run_cache_revenue_v2` | `product_type = 'DBT_RUN_CACHE'` rows in `revenue_records` | View returns rows with correct revenue amounts |
| 3 | UAT sign-off (Step 5) | Both views return correct data | Finance confirms invoice amounts |
| 4 | `dbt run --target production --select run_cache_account_sync_v2` | Backend schema in prod | View exists in `digital-arbor-400.share_celigo` |
| 5 | `dbt run --target production --select monthly_run_cache_revenue_v2` | `product_type = 'DBT_RUN_CACHE'` in prod `revenue_records` | Revenue rows match expected amounts |

### Phase 2 DBT Changes

When Phase 2 schema rename lands, update these in both models:

| Current | Replacement | Affected models |
|---|---|---|
| `account_billing_info` | `billing_info` | Both |
| `billing_account_id` | `billing_info_id` | `monthly_run_cache_revenue_v2` (all 6 CTEs) |
| `account_billing_info.account_id` join | Join via `billing_info_management` | `run_cache_account_sync_v2` |

Test in staging first (`--target staging`), then promote to production.

---

## Phase 1 — Rollback Plan

| Step | Rollback action |
|---|---|
| Step 1 (schema) | Re-add `stripe_customer_id` to `accounts` · restore FK constraint · drop `run_cache_accounts` · revert `account_billing_info` columns |
| Step 2 (Java tasks) | Disable `BigQueryToAppRunCacheSync` + `FillRunCacheRevenue` via feature flag |
| Step 3 (OLP guards) | Redeploy previous `001` + `002` SQL without NOT EXISTS guards |
| Step 4 (Celigo) | Disable RunCache Celigo flows — OLP flows are independent and unaffected |
| Step 6 (DBT) | Disable `monthly_run_cache_revenue_v2` DBT model |

> Schema rollback (Step 1) is the highest-risk step. Confirm backfill of `stripe_customer_id`
> is reversible before proceeding.

---


## File Inventory

| File | Phase | Status |
|---|---|---|
| `run_cache_account_sync_v2.sql` | Phase 1 | ✅ Ready |
| `monthly_run_cache_revenue_v2.sql` | Phase 1 | ✅ Ready (deploy after schema confirm) |
| `001_account_sync_v2.sql` | Phase 1 | ✅ Ready (RunCache guard added) |
| `002_subscription_sync_v2.sql` | Phase 1 | ✅ Ready (RunCache guard added) |
| `staging/run_cache_account_sync_v2_stg.sql` | Staging only | dulcet-yew-246109 |
| `staging/monthly_run_cache_revenue_v2_stg.sql` | Staging only | dulcet-yew-246109 |
| `archive/run_cache_account_sync.sql` | Superseded v1 | Reference only |
| `archive/monthly_run_cache_revenue.sql` | Superseded v1 | Reference only |

---

## Key Contacts

| Role | Person | Area |
|---|---|---|
| Systems Engineering | Prabal Saha | SQL, Celigo, DBT |
| Finance UAT | Jessica Wu | NetSuite invoice validation |
| Backend | TBC | Java tasks, schema changes |
| GCP Admin | TBC | SA permissions |
| NetSuite Admin | Robin Turner | GL account, item setup |
