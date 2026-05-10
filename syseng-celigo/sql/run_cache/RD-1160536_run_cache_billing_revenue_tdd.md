# Billing / Revenue Integration for RunCache
**Required:** PRD / RD-1160536: Pricing for Run Cache
**TDD Status:** In Progress

---

## Authors

| Role | Team Member Name |
|---|---|
| Project Lead | Prabal Saha |
| Feature Architect | Prabal Saha |
| Engineers | Prabal Saha |
| Product Manager | Jessica Wu |

---

## Approvers

| Team | Role | Name | Approval Date |
|---|---|---|---|
| Squad Delivery Team | EM | Alexa Pujol | 1/21/2026 |
| EPD Squad | Engineering Squad Lead | Prabal Saha | In Progress |
| EPD Squad | Product Manager | Jessica Wu | In Progress |
| Accounting Revenue | Dir | Erin MacLean | Not Started |
| Sys Eng | VP of Systems | Ed Di Cristofaro | Not Started |

---

## Introduction

### What Problem is This Feature Solving?

Fivetran is launching a new product — **RunCache** — a plugin for dbt Core developed by the Tobico team. RunCache allows skipping and reusing existing materialized models, billed on consumption (cache hits). This creates two operational problems that this TDD addresses:

**1. No NetSuite invoicing pipeline for RunCache revenue**
RunCache organizations are external accounts — they are not Fivetran platform accounts. Today, the Celigo → NetSuite pipeline only handles Fivetran billing accounts. RunCache revenue cannot flow into NetSuite without dedicated integration work.

**2. Risk of RunCache revenue bleeding into Fivetran OLP reporting**
RunCache consumption is `SELF_SERVICE` type, the same as Fivetran OLP self-service revenue. Without explicit guards, RunCache revenue records could be incorrectly included in Fivetran OLP invoicing queries, causing incorrect billing and Finance reporting.

This TDD describes the system engineering changes required to:
- Sync RunCache organizations into the billing pipeline via a dedicated account sync query
- Generate monthly NetSuite invoices for RunCache revenue via a dedicated DBT transformation
- Protect the existing Fivetran OLP pipeline from RunCache data contamination

---

## Technical Requirements (Success Criteria)

| # | Requirement |
|---|---|
| 1 | RunCache organization identity is sourced from `pg_public.run_cache_accounts` (`run_cache_org_id` → `billing_info_id`), while billing attributes live in `account_billing_info` |
| 2 | Active RunCache subscriptions are surfaced via `run_cache_account_sync` query for downstream sync |
| 3 | Monthly RunCache revenue flows from `stg_pg_public_revenue_records` into a NetSuite-ready invoice dataset via `monthly_run_cache_revenue` |
| 4 | RunCache invoices use distinct external ID prefix (`RCINV` / `RCCM`) separate from Fivetran (`CBPINV` / `CBPCM`) |
| 5 | Fivetran OLP query (`001_account_sync`, `olp_overage_revenue`) explicitly excludes RunCache accounts |
| 6 | Finance team can separate Fivetran revenue from RunCache revenue in all downstream reports |
| 7 | After the billing profile is created, Stripe customer metadata is updated with the billing profile identifier before payment collection begins |

---

## Out of Scope & Future Work

- Corrections / adjustments for RunCache usage (manual process per TDD RD-1160536)
- Reseller / partner billing for RunCache (no partner model in current design)
- Salesforce account sync for RunCache organizations
- Pricing curve definition (owned by `FillRunCacheRevenue` Java task, upstream of this integration)

---

## Design Overview

### Current Flow (as-is)

```
Fivetran Accounts
  pg_public.accounts
  pg_public.account_billing_info (billing_account_type = 'FIVETRAN')
        ↓
  pg_public.subscriptions
        ↓
  001_account_sync.sql         → Celigo account sync pipeline
  olp_overage_revenue.sql      → NetSuite OLP invoicing
```

RunCache organizations have no place in this flow today. They are external accounts — no row in `pg_public.accounts`, no Salesforce ID, no platform tier.

### Desired Flow (to-be)

```
Tobico (BigQuery)
  metrics_daily_agg
        ↓
  FillRunCacheRevenue (Java task)    ← applies pricing curve
        ↓
  stg_pg_public_revenue_records      (product_type = 'RUN_CACHE')
        ↓
  monthly_run_cache_revenue.sql      → NetSuite RunCache invoicing

RunCache Organizations
  pg_public.run_cache_accounts       (run_cache_org_id → billing_info_id)
  account_billing_info               (billing attributes + stripe_customer_id)
  pg_public.subscriptions            (type = 'RunCache_2026')
        ↓
  run_cache_account_sync.sql         → Celigo RunCache account sync pipeline
        ↓
  NetSuite customer / billing profile created
        ↓
  Stripe metadata sync               (write billing profile id before payments)
```

---

## Detailed Design

### 1. Canonical Entities and Keys

The RunCache integration uses the following entities and keys as the source of truth:

| Concept | Canonical Source | Key | Notes |
|---|---|---|---|
| RunCache organization identity | `pg_public.run_cache_accounts` | `run_cache_org_id` | Natural key for the external RunCache org |
| Billing profile identity | `pg_public.account_billing_info` | `id` | Referred to as `billing_info_id` in `run_cache_accounts` |
| RunCache org → billing profile mapping | `pg_public.run_cache_accounts` | `run_cache_org_id` → `billing_info_id` | This mapping is the allowlist for RunCache-specific SQL |
| Customer sync grain | `run_cache_account_sync_v2.sql` output | One row per `run_cache_org_id` | Multiple orgs may point to the same `billing_info_id`; the sync must not collapse them |
| NetSuite customer / billing profile grain | Celigo / NetSuite | One customer keyed by `billing_info_id` | The NetSuite record stores the billing profile identity used by Stripe and invoice generation |
| Billing dataset grain | `monthly_run_cache_revenue_v2.sql` output | One row per `run_cache_org_id` per revenue month | External IDs remain invoice-level (`RCINV` / `RCCM`) |

`account_billing_info` stores billing attributes such as legal name, billing address, tax id, and `stripe_customer_id`, but it is not the source of truth for deciding whether a row belongs to RunCache. That classification comes from `run_cache_accounts`.

---

### 2. Account Billing Info (`account_billing_info`)

RunCache billing details are stored in `account_billing_info`, and `run_cache_accounts.billing_info_id` points to the owning billing profile:

| Column | Value for RunCache |
|---|---|
| `id` | Generated billing profile identifier (`billing_info_id`) |
| `account_id` | `NULL` for external RunCache orgs |
| `legal_name` / `billing_address` / `tax_id` | Sourced from RunCache provisioning inputs |
| `stripe_customer_id` | Set during `BigQueryToAppRunCacheSync` provisioning |

Related mapping table:

| Table | Key | Purpose |
|---|---|---|
| `pg_public.run_cache_accounts` | `run_cache_org_id` → `billing_info_id` | Canonical RunCache identity mapping used by customer and billing SQL |

---

### 3. run_cache_account_sync.sql

**File:** `sql/run_cache_account_sync.sql`

Surfaces active RunCache organizations and their billing/subscription details for the Celigo sync pipeline. Adapted from `001_account_sync.sql` with the following key differences:

| Dimension | `001_account_sync` (Fivetran) | `run_cache_account_sync` (RunCache) |
|---|---|---|
| Account table | `pg_public.accounts` (INNER JOIN) | Not joined — external accounts have no Fivetran account row |
| RunCache identity | Implicit via internal account model | `INNER JOIN pg_public.run_cache_accounts` |
| Billing info join | `ON acct.id = acct_info.account_id` | `ON run_cache_accounts.billing_info_id = acct_info.id` |
| Status filter | `acct.status IN ('Customer','Frozen','Partner')` | Replaced by `stripe_customer_id IS NOT NULL` (fully provisioned) |
| Reseller logic | `payer_account_id` / `payer_type` | Dropped — no reseller model |
| Dedup partition | `PARTITION BY salesforce_id` | `PARTITION BY run_cache_org_id` |
| Subscription filter | Excludes FREE_2022/2024/2026 tiers | `type = 'RunCache_2026'` only |
| Incremental window | 28-hour `_fivetran_synced` | Same |

Customer sync output contract:

- One row per `run_cache_org_id`
- Includes the referenced `billing_info_id`
- Carries the billing attributes Celigo needs to create or upsert the NetSuite customer
- Must preserve multiple orgs even if they share the same `billing_info_id`

---

### 4. Stripe Metadata Sync

Stripe metadata write-back is part of the provisioning path, not an optional side effect.

#### Sequence

1. `BigQueryToAppRunCacheSync` detects a new `run_cache_org_id`
2. Create or look up the billing profile in `account_billing_info`
3. Persist the `run_cache_org_id` → `billing_info_id` mapping in `run_cache_accounts`
4. Create or upsert the NetSuite customer / billing profile through Celigo
5. Write `billing_info_id` to the Stripe customer metadata (`fivetran_billing_account_id`)
6. Only after Stripe metadata write succeeds is the org considered payment-ready

#### Failure Behavior

- If Stripe metadata update fails, the RunCache org remains unsynced for payments
- The provisioning task must fail the org-level sync and retry on the next run
- Alerting should fire for repeated Stripe metadata update failures

This sequencing prevents payment collection from starting before Stripe can be correlated back to the billing profile used by NetSuite and downstream finance systems.

---

### 5. monthly_run_cache_revenue.sql

**File:** `sql/monthly_run_cache_revenue.sql`

Produces one invoice-ready row per RunCache organization per month for NetSuite.

#### Data Flow

```
stg_pg_public_revenue_records    (product_type = 'RUN_CACHE')
        ↓ INNER JOIN
run_cache_accounts                (billing_account_id = billing_info_id)
        → run_cache_org_id, billing_info_id
        ↓ INNER JOIN
account_billing_info              (id = billing_info_id)
        → stripe_customer_id
        ↓ LEFT JOIN
netsuite2.customer                (ON billing_account_id = custentity_ft_account_id_sf)
        → netsuite_customer_id, company name, to_be_emailed, revenue_month_end
        ↓ LEFT JOIN
netsuite2.item                    (ON item.name = 'RunCache_2026')
        → item_id
        ↓
Transformations
        → quantity, amount, netsuite_quantity, netsuite_amount, rate
        → payment_term = 'Autopay'
        → transaction_type = Invoice / Credit Memo / None
        ↓
External ID assignment
        → RCINV{netsuite_customer_id}{YYYYMM}  (Invoice)
        → RCCM{netsuite_customer_id}{YYYYMM}   (Credit Memo)
        ↓
OUTPUT: one row per `run_cache_org_id` per month, ordered by revenue_month_start DESC
```

#### Business Logic

| Rule | Detail |
|---|---|
| Billing period | `revenue_date_utc` truncated to month; month end = `last_day()` |
| Quantity | `credits_used` (cache hits); fallback to `revenue_amount` if null |
| Amount | `revenue_amount` rounded to 2 decimal places |
| Payment term | Always `Autopay` — RunCache is self-service CBP |
| Transaction type | `amount ≥ 1` → Invoice · `amount < 0` → Credit Memo · else → None |
| NetSuite amounts | Always positive (`abs()`) — sign carried by `transaction_type` |
| External ID prefix | `RCINV` / `RCCM` — distinct from Fivetran `CBPINV` / `CBPCM` |

#### Tables Used

| Table | Join Type | Purpose |
|---|---|---|
| `private-internal.staging.stg_pg_public_revenue_records` | Source | RunCache revenue amounts |
| `digital-arbor-400.pg_public.run_cache_accounts` | INNER JOIN | Canonical RunCache allowlist and `run_cache_org_id` mapping |
| `digital-arbor-400.pg_public.account_billing_info` | INNER JOIN | Stripe customer ID and billing attributes |
| `private-internal.netsuite2.customer` | LEFT JOIN | NetSuite customer details, invoice email |
| `private-internal.netsuite2.item` | LEFT JOIN | RunCache_2026 SKU item ID |

**Not used (vs olp_overage_revenue.sql):**
- `pg_public.accounts` — dropped; `stripe_customer_id` sourced from `account_billing_info`
- `netsuite2.partner` — no reseller model for RunCache
- `salesforce.fivetran_account_c` — RunCache external accounts have no Fivetran→Salesforce mapping

---

### 6. Fivetran OLP Pipeline Guard (001_account_sync.sql)

**File:** `sql/001_account_sync.sql`

Added explicit exclusion to prevent RunCache accounts from appearing in the Fivetran OLP sync:

```sql
and not exists (
  select 1
  from `digital-arbor-400`.`pg_public`.`run_cache_accounts` as rca
  where rca.billing_info_id = acct_info.id
)
```

`run_cache_accounts` is the authoritative RunCache allowlist, so the same exclusion logic can be reused across account and subscription sync queries.

---

### 7. OLP Overage Revenue Guard (olp_overage_revenue.sql)

**File:** `sql/olp_overage_revenue.sql`

The existing OLP query was using `pg_public.accounts` to source `stripe_customer_id`. Per TDD, `accounts.stripe_customer_id` will be **dropped** post-migration. The query must both source Stripe data from `account_billing_info` and exclude RunCache through the same `run_cache_accounts` allowlist / denylist boundary:

```sql
-- Before (will break post-migration):
inner join `digital-arbor-400`.`pg_public`.`accounts`
  on revenue_records.billing_account_id = accounts.id

-- After (migration-safe):
inner join `digital-arbor-400`.`pg_public`.`account_billing_info`
  on revenue_records.billing_account_id = account_billing_info.id

where not exists (
  select 1
  from `digital-arbor-400`.`pg_public`.`run_cache_accounts` as rca
  where rca.billing_info_id = revenue_records.billing_account_id
)
```

---

### 8. NetSuite Configuration

| Item | Detail |
|---|---|
| New item/SKU | `RunCache_2026` — must exist in `netsuite2.item` |
| New product type | `DBT_RUN_CACHE` — must be supported on Sales Orders |
| External ID prefix | `RCINV` / `RCCM` — confirm no collision with existing NS records |
| Customer record | NetSuite customer / billing profile record must be keyed by `billing_info_id` via `custentity_ft_account_id_sf` |
| Customer grain | One NetSuite customer per `billing_info_id`; multiple `run_cache_org_id` rows may reference the same customer |

---

## Performance

Additional logic is limited to:
- One new SQL query (`run_cache_account_sync`) executed on the same cadence as `001_account_sync`
- One new DBT model (`monthly_run_cache_revenue`) on the same schedule as `olp_overage_revenue`

RunCache volume is significantly lower than Fivetran OLP at launch. No scaling concerns anticipated.

---

## Security

All existing security frameworks provided by Celigo, BigQuery, and NetSuite are applicable. All users with access to these systems are governed by ITGC.

---

## Observability: Metrics, Logging, and Monitoring

| Signal | Location | Alert Condition |
|---|---|---|
| No new RunCache revenue records | BigQuery / Grafana | No rows with `product_type = 'RUN_CACHE'` after expected load window |
| RunCache rows in OLP query | BigQuery | Any row in `olp_overage_revenue` whose `billing_account_id` exists in `run_cache_accounts.billing_info_id` |
| Missing NetSuite customer for RunCache org | NetSuite / Celigo | `netsuite_customer_id IS NULL` in `monthly_run_cache_revenue` output |
| Stripe metadata sync failure | Stripe / app logs | Missing `fivetran_billing_account_id` metadata after NetSuite customer creation |
| Celigo flow errors | Celigo native alerting | Flow-level and record-level failures in RunCache sync |

---

## Test Strategy

### Phase 1: Sandbox
- Deploy `run_cache_account_sync` and `monthly_run_cache_revenue` against sandbox BigQuery and NetSuite
- Seed test RunCache organizations in `run_cache_accounts` and linked `account_billing_info`
- Seed test revenue records with `product_type = 'RUN_CACHE'`
- Validate: correct `RCINV`/`RCCM` external IDs, correct item mapping to `RunCache_2026`, correct `Autopay` payment term
- Validate: Stripe metadata contains `fivetran_billing_account_id = billing_info_id` before payment collection

### Phase 2: Regression
- Run `001_account_sync` and `olp_overage_revenue` against the same sandbox data
- Validate: zero RunCache rows appear in Fivetran OLP output
- Validate: existing Fivetran OLP accounts unaffected (no row count drop)

### Phase 3: UAT (Accounting / Finance)
- Confirm Finance can distinguish RunCache vs Fivetran revenue in NetSuite by external ID prefix and product type
- Confirm invoice amounts and dates match expected monthly consumption

### Acceptance Criteria

| AC | Criteria |
|---|---|
| AC-1 | `monthly_run_cache_revenue` produces one invoice row per `run_cache_org_id` per month with correct external ID, item ID, and amounts |
| AC-2 | `run_cache_account_sync` returns only rows whose `billing_info_id` is present in `run_cache_accounts` and whose subscription type is `RunCache_2026` |
| AC-3 | `001_account_sync` returns zero rows for RunCache accounts |
| AC-4 | `olp_overage_revenue` returns zero rows for RunCache accounts |
| AC-5 | Finance can filter NetSuite invoices by `RCINV`/`RCCM` prefix to isolate RunCache revenue |
| AC-6 | Stripe metadata is populated with `fivetran_billing_account_id` before a RunCache customer is considered payment-ready |

---

## Implementation Phasing / Plan

| Step | Environment | Assigned To | Status |
|---|---|---|---|
| `monthly_run_cache_revenue.sql` — initial build | Sandbox | Prabal Saha | Done |
| `run_cache_account_sync.sql` — initial build | Sandbox | Prabal Saha | Done |
| `001_account_sync.sql` — RunCache exclusion guard | Sandbox | Prabal Saha | Done |
| `olp_overage_revenue.sql` — migrate from `accounts` to `account_billing_info` | Sandbox | Prabal Saha | Done |
| NetSuite `RunCache_2026` item configuration | Sandbox | TBD | Not Started |
| End-to-end sandbox validation | Sandbox | Prabal Saha | Not Started |
| Finance / Accounting UAT | Sandbox | Erin MacLean | Not Started |
| Production rollout | Production | Prabal Saha | Not Started |

---

## Caveats & Gotchas

| # | Note |
|---|---|
| 1 | `run_cache_accounts` is the canonical RunCache allowlist. Older docs that reference `billing_account_type = 'RUN_CACHE'` are obsolete and should not be used for new SQL. |
| 2 | RunCache orgs have no `status` field — "active" is inferred from `stripe_customer_id IS NOT NULL` + active subscription. Confirm with engineering. |
| 3 | `netsuite2.customer.custentity_ft_account_id_sf` must be populated with `billing_info_id`, not `run_cache_org_id`, so billing and Stripe reconciliation share one customer key. |
| 4 | Pricing curve is applied upstream by `FillRunCacheRevenue` Java task. This integration is downstream-only and does not validate pricing correctness. |
| 5 | Corrections / credit adjustments for RunCache are out of scope and handled manually per TDD. |

---

## References and Links

| Resource | Link |
|---|---|
| Source TDD | RD-1160536: Pricing for Run Cache |
| SQL: Monthly RunCache Revenue | `sql/monthly_run_cache_revenue.sql` |
| SQL: RunCache Account Sync | `sql/run_cache_account_sync.sql` |
| SQL: Fivetran OLP Account Sync (guarded) | `sql/001_account_sync.sql` |
| SQL: Fivetran OLP Revenue (guarded) | `sql/olp_overage_revenue.sql` |
| One Pager: monthly_run_cache_revenue | `sql/monthly_run_cache_revenue.md` |
