# syseng-celigo

BigQuery SQL queries, dbt models, JavaScript Celigo hooks, and TypeScript transformers for Fivetran's billing pipeline: **BigQuery → Celigo → NetSuite**.

Two billing pipelines run through this stack:

| Pipeline | BQ Source | SKU | NS External ID prefix |
|---|---|---|---|
| Fivetran OLP | `pg_public.subscriptions` | SELF_SERVICE / OVERAGE | `CBPINV` / `CBPCM` |
| RunCache | `staging.stg_pg_public_revenue_records` (type=`DBT_RUN_CACHE`) | `RUN_CACHE_2026` | `RCINV` / `RCCM` |

---

## Repository Layout

```
syseng-celigo/
├── sql/                          # BigQuery extract queries (OLP pipeline)
│   ├── 001_account_sync.sql      # Account master sync to NS customer
│   ├── 002_subscription_sync.sql # Subscription billing line extraction
│   ├── 003–005_*_ddl.sql        # Financial header/line/PDF DDL schemas
│   ├── 006–011_*.sql            # Diagnostic and backfill helpers
│   ├── 012_compositeQuery_NS_Product.sql  # NS Product composite lookup
│   ├── 013_reconQuery.sql        # Reconciliation query
│   ├── 014_troubleshooting_sqls.sql       # On-call troubleshooting
│   ├── account_owner_sync.sql    # Account owner field sync
│   ├── olp_overage_revenue.sql   # OLP overage revenue extraction
│   ├── real_time_dashboard.sql   # Live billing status dashboard
│   ├── debug/                    # Step-by-step debug queries (01–05 + combined)
│   └── run_cache/                # RunCache-specific SQL and docs
│       ├── run_cache_account_sync_v2.sql          # RC account → NS customer
│       ├── staging/                               # Staging validation SQL
│       └── archive/                               # Superseded queries
├── dbt/run_cache/                # Production dbt project (RunCache)
│   ├── models/run_cache/
│   │   ├── monthly_run_cache_revenue_v2.sql       # Core billing view
│   │   ├── stripe_null_netsuite_customer_id_mapping_both.sql
│   │   └── sources.yml
│   ├── debug/                    # Diagnostic dbt models (not in production)
│   ├── dbt_project.yml
│   └── profiles_template.yml
└── javascripts/                  # Celigo integration hooks and transformers
    ├── preMapHookSubNsSync.js     # Pre-map: reconciliation & control totals
    ├── preSavePageTransformerPdNsSub.js   # Pre-save: OLP subscription transformer (PRIMARY)
    ├── preSavePageTransformerPdNsAcc.js   # Pre-save: account/customer sync
    ├── preSavePageTransformerPdNSAccv1.js # Archive: previous account transformer
    ├── preSavePageParserNSProd.js         # NS response parser
    ├── preSavePageHRinactiveStatus.js     # HR inactive status handler
    ├── preSavePageTransformer_fixed_2_6.js # Pinned production snapshot
    ├── preSavePageTransformerPdNsSub_RD-1165774.js  # RD-1165774 variant
    ├── [FT] - MR Delete Invoices.js       # NetSuite MR: bulk invoice delete
    ├── [FT] - MR backfillContact.js       # NetSuite MR: contact backfill
    ├── [FT]-restLetCallGCPAPI.js          # NetSuite RESTlet → GCP API caller
    └── run_cache/
        ├── preSaveDataTransformAccountRunCache.ts   # RC account transformer
        └── preSaveDataValidationRevenueRunCache.ts  # RC revenue validator
```

---

## BigQuery Environments

| Layer | Staging | Production |
|---|---|---|
| Billing tables | `dulcet-yew-246109.staging_billing_public` | `digital-arbor-400.pg_public` |
| Revenue records | `dulcet-yew-246109.staging_billing_public.revenue_records` | `private-internal.staging.stg_pg_public_revenue_records` |
| NetSuite | `private-internal.netsuite2_sandbox` | `private-internal.netsuite2` |
| Stripe | `dulcet-yew-246109.stripe` | `private-internal.stripe` |
| Output | `dulcet-yew-246109.share_celigo` | `private-internal.share_celigo` |

**Production is canonical.** All SQL should target production refs unless the file is under `sql/run_cache/staging/` or named with a `_stg` suffix.

---

## SQL — OLP Pipeline (`sql/`)

### Core Extract Queries

| File | Purpose |
|---|---|
| `001_account_sync.sql` | Extracts account master records from `pg_public.account_billing_info` for NetSuite customer sync. Joins to Stripe for `stripe_customer_id`, excludes `_fivetran_deleted` rows, deduplicates on `billing_account_id`. |
| `002_subscription_sync.sql` | Extracts active subscription billing lines from `pg_public.subscriptions`. Filters for `type IN ('SELF_SERVICE','OVERAGE')`, applies 28-hour recency filter (`_fivetran_synced`), excludes `CENSUS_LEGACY` (RD-1063527) and Tobiko sandbox accounts. Groups by `order_number` and produces one output row per subscription line. |
| `012_compositeQuery_NS_Product.sql` | Composite lookup joining BQ subscription data against `netsuite2.item` to identify matching NS product records. Used for NS item ID resolution during sync validation. |
| `013_reconQuery.sql` | Reconciliation query: compares records written to NS against BQ source data. Used to detect drift, double-charges, or missing invoices after a Celigo run. |
| `014_troubleshooting_sqls.sql` | Collection of on-call diagnostic queries: find specific `order_number`, audit `billing_account_id` history, check `_fivetran_synced` timestamps, inspect control totals. |

### DDL Schemas

| File | Table | Description |
|---|---|---|
| `003_financial_header_ddl.sql` | `financial_sync_header` | Audit log header per Celigo sync run: run ID, timestamp, record count, status |
| `004_financial_lines_ddl.sql` | `financial_sync_lines` | Per-record audit: `billing_account_id`, `order_number`, amount, NS response code |
| `005_financial_pdf_tracking_ddl.sql` | `financial_pdf_tracking` | Tracks PDF archival: NS invoice ID, GCS path, upload timestamp, error if any |

### Diagnostic and Backfill Helpers

| File | Purpose |
|---|---|
| `006_missing_account_fields.sql` | Finds accounts missing `stripe_customer_id` or `netsuite_customer_id` — surfaced during pre-save validation. |
| `007_missing_fields_subs.sql` | Finds subscriptions missing required billing fields (`order_number`, `billing_account_id`). |
| `008_fivetran_id_sfdc_id_map.sql` | Maps Fivetran account IDs to Salesforce account IDs for cross-system reconciliation. |
| `009_fivetran_missing_reseller_query.sql` | Identifies reseller accounts not yet mapped in the NS partner table. |
| `010_backfill_subscription_id.sql` | One-time backfill: populates `subscription_id` on historical records that predate the field. |
| `011_backfill_subs_v2.sql` | Updated backfill for v2 schema changes, including multi-line order support. |
| `account_owner_sync.sql` | Syncs `account_owner` field changes from Salesforce/BQ to NS customer records. |
| `olp_overage_revenue.sql` | Extracts OLP overage charges for revenue reporting (separate from billing sync). |
| `real_time_dashboard.sql` | Live dashboard query: recent Celigo runs, success/failure counts, last sync timestamps. |

### Debug Step Queries (`sql/debug/`)

Numbered step-by-step decomposition of `002_subscription_sync.sql` for troubleshooting individual pipeline stages:

| File | What it isolates |
|---|---|
| `01_raw_subscriptions.sql` | Raw subscription table with no filters applied |
| `02_deduped_by_salesforce_id.sql` | After deduplication on `salesforce_id` |
| `03_type_and_order_filters.sql` | After applying `type` and `order_number` filters |
| `04_recency_filter.sql` | After applying 28-hour `_fivetran_synced` recency window |
| `05_billing_info_joins.sql` | After joining `account_billing_info` |
| `combined_diagnostic.sql` | All steps combined with row counts at each stage |

---

## SQL — RunCache Pipeline (`sql/run_cache/`)

### Production Queries

| File | Purpose |
|---|---|
| `run_cache_account_sync_v2.sql` | Extracts RunCache accounts from `pg_public.run_cache_accounts` + `account_billing_info`. Produces one row per `billing_info_id` with `netsuite_customer_id` resolved. **All RunCache accounts must go through this file** — not through `001_account_sync.sql`. |
| `monthly_run_cache_revenue.md` | Design doc for the v1 monthly revenue query (archived). |

### Design and Architecture Documents

| File | Description |
|---|---|
| `RD-1160536_run_cache_billing_revenue_tdd.md` | Full TDD for RunCache billing and revenue. Covers Phase 1 (FillRunCacheRevenue), Phase 2 (Celigo integration), identity key design (`run_cache_org_id`, `billing_info_id`), external ID format (`RCINV{customer_id}{YYYYMM}`). |
| `RD-1161737_technical_spec.md` | Technical spec for Celigo integration of RunCache billing (Jira RD-1161737). |
| `RD-1160536_consolidated_design.md` | Consolidated design decisions for RunCache pricing (parent epic). |
| `TDD_comparison_v1_vs_v2.md` | Side-by-side comparison of v1 and v2 TDD approaches; explains why v2 was adopted. |
| `RunCache_Integration_Deployment_Document.md` | Deployment runbook: pre-flight checks, dbt run commands, post-deploy validation, rollback procedure. |
| `impact_analysis_phase1_phase2.md` | Impact analysis for Phase 1 vs Phase 2 cutover. |
| `run_cache_revenue_data_flow.md` | Narrative data flow description from `revenue_records` → Celigo → NS. |
| `compute_migration_one_pager.md` | One-pager for RunCache Compute migration context. |
| `billing_sync_flow.svg` | Architecture diagram: RunCache billing sync flow (source: `billing_sync_flow.drawio`). |
| `customer_sync_flow.svg` | Architecture diagram: RunCache customer/account sync flow. |
| `MIGRATION.md` | Migration notes for `run_cache_account_sync` v1 → v2. |

### Staging Queries (`sql/run_cache/staging/`)

Used for end-to-end validation against the staging BigQuery project. **Do not promote these to production directly** — they contain staging-only guards.

| File | Purpose |
|---|---|
| `monthly_run_cache_revenue_v2_stg.sql` | Staging version of the revenue query; uses `dulcet-yew-246109.staging_billing_public` refs. |
| `run_cache_account_sync_v2_stg.sql` | Staging account sync query. |
| `stripe_null_netsuite_customer_id_mapping.sql` | Maps RunCache accounts where `stripe_customer_id` is null — used to find missing NS customer IDs. |
| `stripe_null_netsuite_customer_id_mapping_both.sql` | Extended version: checks both Stripe-null and NS-null mappings side by side. |
| `debug_billing_id_match.sql` | Validates that `billing_info_id` in `revenue_records` matches `account_billing_info.id`. |
| `runCache_Debug.sql` | Ad hoc debug queries for staging RunCache runs. |
| `create_staging_tables.sql` | **Seed script only.** Creates mock staging tables. Never runs in production. |

### Archived Queries (`sql/run_cache/archive/`)

| File | Note |
|---|---|
| `monthly_run_cache_revenue.sql` | v1 revenue query, superseded by `monthly_run_cache_revenue_v2.sql`. Retained for reference. |
| `run_cache_account_sync.sql` | v1 account sync, superseded by `run_cache_account_sync_v2.sql`. |

---

## dbt — RunCache Production Models (`dbt/run_cache/`)

Production dbt project that materializes BigQuery views consumed by Celigo.

### Models

| Model | Output view | Description |
|---|---|---|
| `monthly_run_cache_revenue_v2.sql` | `private-internal.share_celigo.syseng_monthly_run_cache_revenue_v2` | Core RunCache billing view. Joins `revenue_records` → `account_billing_info` → `netsuite2.customer` → `netsuite2.item`. Produces one row per billing period per account with `external_id`, `payment_term = 'Autopay'`, amount, and NS line metadata. |
| `stripe_null_netsuite_customer_id_mapping_both.sql` | `private-internal.share_celigo.syseng_stripe_null_netsuite_customer_id_mapping_both` | Lookup view for RunCache accounts missing NS customer IDs. Used by the account sync integration to detect and surface unmapped accounts. |

### Model Config

Each model uses:
```sql
{{
  config(
    materialized = 'view',
    project      = 'private-internal'
  )
}}
```

The output dataset (`share_celigo`) is set solely in `profiles.yml` — **never in `{{ config() }}` or `dbt_project.yml`** (adding `schema` there would produce `share_celigo_share_celigo`).

### Source References

All hardcoded table refs are replaced with `{{ source(...) }}` macros:

| Macro | Resolves to |
|---|---|
| `{{ source('pg_public', 'run_cache_accounts') }}` | `digital-arbor-400.pg_public.run_cache_accounts` |
| `{{ source('pg_public', 'account_billing_info') }}` | `digital-arbor-400.pg_public.account_billing_info` |
| `{{ source('staging', 'stg_pg_public_revenue_records') }}` | `private-internal.staging.stg_pg_public_revenue_records` |
| `{{ source('netsuite2', 'customer') }}` | `private-internal.netsuite2.customer` |
| `{{ source('netsuite2', 'item') }}` | `private-internal.netsuite2.item` |

Sources are registered in `models/run_cache/sources.yml`.

### Debug Models (`dbt/run_cache/debug/`)

Step-by-step diagnostic queries mirroring the revenue model's CTEs. Not part of the production dbt run — used during development and incident triage.

| File | What it isolates |
|---|---|
| `01_source_account_billing_info.sql` | Raw `account_billing_info` for RunCache accounts |
| `02_source_netsuite_customer.sql` | NS customer records matching RunCache billing accounts |
| `03_source_netsuite_item.sql` | NS item lookup for `RUN_CACHE_2026` SKU |
| `04_source_revenue_records.sql` | Raw `revenue_records` filtered to `type = 'DBT_RUN_CACHE'` |
| `05_credits_with_customer.sql` | Revenue records joined to customer IDs |
| `06_transaction_types.sql` | INV vs CM classification logic |
| `combined_diagnostic.sql` | All steps with row counts at each CTE boundary |

### Running dbt

```bash
cd dbt/run_cache

# Validate connection
dbt debug --profiles-dir .

# Compile and inspect generated SQL
dbt compile --select monthly_run_cache_revenue_v2 --profiles-dir .

# Deploy
dbt run --select monthly_run_cache_revenue_v2 --profiles-dir .

# Deploy both models
dbt run --profiles-dir .
```

Post-deploy validation:
- View created at `private-internal.share_celigo.syseng_monthly_run_cache_revenue_v2`
- `external_id` follows `RCINV{customer_id}{YYYYMM}` (invoices) or `RCCM{customer_id}{YYYYMM}` (credits)
- No duplicate `external_id + line_number` pairs
- `payment_term = 'Autopay'` on all rows

Rollback (views only — no data written):
```bash
bq rm -f private-internal:share_celigo.syseng_monthly_run_cache_revenue_v2
```

---

## JavaScript — Celigo Hooks (`javascripts/`)

All hooks are **ES5-compatible** (Celigo's JS runtime does not support ES6+). No `const`/`let`, no arrow functions, no spread operator, no template literals.

### Pre-Map Hook

#### `preMapHookSubNsSync.js`

Runs **before** field mapping in the OLP subscription integration. Computes reconciliation control totals across all records in the batch and stamps them onto every valid output record.

**Inputs** (`options.data`): array of subscription records from BQ extract.

**Outputs**: array of the same length. Each element is `{ data: {...}, errors?: [...] }`.

**Control fields stamped on each valid record:**

| Field | Description |
|---|---|
| `control_record_count` | Total records in this batch |
| `control_valid_records` | Records with a non-empty `billing_account_id` |
| `control_total_amount` | Sum of `amount` across valid records |
| `control_hash_total` | Char-code hash of all `billing_account_id` values |
| `control_average_amount` | `total_amount / valid_records` |

**Validity check**: A record is valid if `billing_account_id` is non-empty (amount is not checked here — amount validation happens in the pre-save transformer).

**Error handling**: Invalid records get an `invalid_record` error in `options.errors` and in the element's `errors` array, but are still passed through (not dropped) — the pre-save transformer handles rejection.

### Pre-Save Page Transformers

#### `preSavePageTransformerPdNsSub.js` ← **PRIMARY OLP TRANSFORMER**

The main Celigo pre-save hook for the OLP subscription billing pipeline. Runs after the BQ extract and field-map steps, before writing to NetSuite.

**Key responsibilities:**

1. **Order grouping**: Groups all records by `order_number`. Each order may have multiple subscription lines (e.g., a new charge + a credit offset from an upsell).

2. **Zero/negative order filter**: Orders where `SUM(amount) ≤ 0` are rejected entirely — the whole order group is dropped. This prevents net-zero or net-negative charges from creating Sales Orders in NetSuite. These are logged as `zero_or_negative_total` errors.

   ```javascript
   .filter(function (g) {
       if (g.total <= 0) {
           // log to removedOrders, push error
           return false;
       }
       return true;
   })
   ```

3. **NS item ID resolution**: Maps subscription `type` and `product_name` to NetSuite item internal IDs using a hardcoded partner/product lookup table. Covers 60+ partner entries, HVR variants, ELA plans, and census legacy mappings (RD-1063527, RD-1060067, RD-927162).

4. **Sales Order construction**: Builds the NS Sales Order payload with correct `externalId` (`CBPINV{billing_account_id}{YYYYMM}` for invoices, `CBPCM...` for credit memos), line items, `paymentTerms`, and billing schedule fields.

5. **Credit memo routing**: Orders with a negative net (after the `≤ 0` filter was already applied) are classified as credit memos and routed to the `CBPCM` external ID prefix.

**Important exclusions baked in:**
- `CENSUS_LEGACY` accounts (NS item ID 18037) — ref: RD-1063527
- Tobiko (`Tobiko_Legacy_Pre_Migration`) — sandbox only, do not promote

#### `preSavePageTransformerPdNsAcc.js`

Pre-save transformer for the **account/customer sync** integration. Maps BQ account fields to NS customer fields. Handles:
- `netsuite_customer_id` resolution
- Billing address mapping
- Payment term defaulting to `'Autopay'`
- Partner/reseller account routing

#### `preSavePageTransformerPdNSAccv1.js`

Archived v1 of the account transformer. Retained for rollback reference.

#### `preSavePageParserNSProd.js`

Parses NetSuite responses after a write operation. Extracts the internal NS record ID, maps it back to the BQ `billing_account_id`, and structures the response for Celigo's error/success handling.

#### `preSavePageHRinactiveStatus.js`

Handles HR (Human Resources) integration — marks inactive status on NS records when an account is deactivated. Separate from the billing pipeline.

#### `preSavePageTransformer_fixed_2_6.js`

Pinned production snapshot from version 2.6. Not actively deployed — kept as a rollback reference for the main transformer.

#### `preSavePageTransformerPdNsSub_RD-1165774.js`

Variant of the main transformer with changes specific to RD-1165774. Branched from the main file for isolated testing; may be merged back or retired.

### NetSuite SuiteScript (`javascripts/`)

These run **inside NetSuite** (not in Celigo):

| File | Type | Purpose |
|---|---|---|
| `[FT] - MR Delete Invoices.js` | Map/Reduce | Bulk-deletes NetSuite invoice records. Used for cleanup after bad sync runs. |
| `[FT] - MR backfillContact.js` | Map/Reduce | Backfills missing contact associations on NS customer records. |
| `[FT]-restLetCallGCPAPI.js` | RESTlet | Called from within NetSuite to trigger GCP Cloud Function endpoints (e.g., PDF archival worker). Handles OAuth signing for GCP. |

### RunCache TypeScript Transformers (`javascripts/run_cache/`)

TypeScript files transpiled before deployment to Celigo.

#### `preSaveDataTransformAccountRunCache.ts`

Pre-save transformer for the RunCache account sync integration. Maps `run_cache_accounts` fields to NS customer fields. Key differences from OLP:
- Uses `run_cache_org_id` as the primary identity key
- External ID prefix: none (RunCache accounts share the same NS customer records as OLP — they don't create new customers)
- Validates `billing_info_id` matches `account_billing_info.id`

#### `preSaveDataValidationRevenueRunCache.ts`

Pre-save validator for the RunCache revenue/billing integration. Validates:
- `external_id` format: `RCINV{customer_id}{YYYYMM}` or `RCCM{customer_id}{YYYYMM}`
- `payment_term = 'Autopay'` is present
- NS item exists for `RUN_CACHE_2026` SKU
- No duplicate `external_id + line_number` pairs in the batch

---

## Integration Architecture

```
BigQuery (pg_public / staging / netsuite2 / stripe)
    │
    ▼
SQL Extract Query (001_account_sync / 002_subscription_sync / run_cache_account_sync_v2
                   / dbt view: monthly_run_cache_revenue_v2)
    │
    ▼
Celigo Integration Platform
  ├── Pre-Map Hook         preMapHookSubNsSync.js
  │   └── Stamps control totals, flags invalid billing_account_id
  ├── Field Mapping        (configured in Celigo UI)
  ├── Pre-Save Page Hook   preSavePageTransformerPdNsSub.js (OLP)
  │   └── Groups by order_number, filters net ≤ 0, resolves NS item IDs,
  │       builds Sales Order / Credit Memo payloads
  └── NetSuite Write       → Sales Orders / Invoices / Credit Memos
          │
          ▼
     Response Parser       preSavePageParserNSProd.js
          │
          ▼
     Audit Log             financial_sync_header + financial_sync_lines
```

---

## Key Business Rules

| Rule | Where enforced | Jira |
|---|---|---|
| Orders with net amount ≤ 0 are dropped entirely | `preSavePageTransformerPdNsSub.js` | — |
| CENSUS_LEGACY accounts get NS item ID 18037 | Transformer item lookup table | RD-1063527 |
| RunCache subs must use `run_cache_account_sync_v2.sql` | Documentation + code review | RD-1160536 |
| 28-hour recency filter on `_fivetran_synced` | `002_subscription_sync.sql` WHERE clause | — |
| `not <alias>._fivetran_deleted` filter on all joins | All SQL files | — |
| NS item names must not include year suffixes | Transformer lookup + CLAUDE.md | — |
| `payment_term = 'Autopay'` on all RunCache rows | dbt model + validator | — |
| No direct commits to `main` | Branch policy (CLAUDE.md) | — |

---

## External ID Format

| Pipeline | Transaction type | Format | Example |
|---|---|---|---|
| OLP | Invoice / Sales Order | `CBPINV{billing_account_id}{YYYYMM}` | `CBPINVsurprisingly_zebra202501` |
| OLP | Credit Memo | `CBPCM{billing_account_id}{YYYYMM}` | `CBPCMsurprisingly_zebra202501` |
| RunCache | Invoice | `RCINV{ns_customer_id}{YYYYMM}` | `RCINV123456202501` |
| RunCache | Credit Memo | `RCCM{ns_customer_id}{YYYYMM}` | `RCCM123456202501` |

---

## SQL Conventions

- Always alias tables; always qualify column refs with the alias in multi-table queries
- Use `not <alias>._fivetran_deleted` (not `= false` or `is false`)
- Use `SAFE_CAST` / `SAFE_DIVIDE` / `COALESCE` over bare `CAST` / `/` / `IF(x IS NULL)`
- Use CTEs over nested subqueries; one CTE per logical step
- Static filters in `WHERE`, join conditions only in `ON`
- `QUALIFY ROW_NUMBER() OVER (...) = 1` for deduplication

---

## Jira Epics

| Epic | Title |
|---|---|
| RD-1160536 | Pricing for Run Cache (parent) |
| RD-1161737 | RunCache Billing & Revenue Integration |
| RD-1177722 | RunCache repo reorg (current branch) |
| RD-1063527 | CENSUS_LEGACY NS product mapping |
| RD-1060067 | RR dates from Service min/max |
| RD-927162 | Auto-set Billing Schedules |
| RD-1010532 | ELA HVR Intra-Allocations |
| RD-899810 | Pricing Model Subscription date mapping |
| RD-1165774 | Subscription transformer variant |

---

## Branch Policy

Every change — including single-line patches — must happen on a named branch. Never commit to `main`.

```bash
git checkout main && git pull && git checkout -b <branch-name>
```

| Change type | Branch pattern | Example |
|---|---|---|
| Epic | `epic/<N>-<slug>` | `epic/3-runcache-billing` |
| Bug fix | `fix/<slug>` | `fix/zero-total-order-drop` |
| Docs | `docs/<slug>` | `docs/update-sql-readme` |
| Refactor | `refactor/<slug>` | `refactor/transformer-item-lookup` |
