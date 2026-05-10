# RunCache Integration — Deployment Document

**Epic**   : RD-1161737
**Author** : Prabal Saha
**Date**   : 2026-04-21
**Status** : Production Pending

---

## 1. Overview

This document outlines the deployment components required for the NetSuite – RunCache
Integration, which enables automated monthly invoicing of RunCache consumption revenue
into NetSuite, and backfill of NetSuite customer IDs into Stripe customer metadata — all
orchestrated through the Celigo integration platform.

RunCache organizations are external accounts (not Fivetran platform accounts). The
integration introduces a dedicated billing pipeline separate from the existing Fivetran OLP
pipeline, with explicit guards to prevent cross-contamination.

**Pipeline Flow:**

```
digital-arbor-400.pg_public          (run_cache_accounts, account_billing_info, accounts)
private-internal.staging             (stg_pg_public_revenue_records)
private-internal.netsuite2           (customer, item)
private-internal.stripe              (customer)
        ↓  dbt run (monthly, via Cloud Scheduler or manual trigger)
private-internal.share_celigo.*      [BigQuery views — Celigo data source]
        ↓  Celigo reads views
NetSuite API  →  Customer upsert / Invoice / Credit Memo
Stripe API    →  netsuite_customer_id metadata backfill
```

---

## 2. Architecture Components Summary

| Layer | Component Type | Count |
|---|---|---|
| Celigo | Integration | 1 |
| Celigo | Flows | 3 |
| Celigo | preSavePage Scripts | 2 |
| BigQuery | dbt Models (Views) | 2 |
| BigQuery | Source SQL Query | 1 |
| NetSuite | Item / SKU | 1 |
| NetSuite | Customer Entity Field (existing) | 1 |

---

## 3. Celigo Components

### 3.1 Integration

| Field | Value |
|---|---|
| Integration Name | NetSuite – RunCache Integration |
| URL | *(to be confirmed post-Celigo setup)* |

---

### 3.2 Flows

| # | Flow Name | Purpose |
|---|---|---|
| 1 | RunCache Account Sync | Reads `run_cache_account_sync_v2.sql` output; creates or upserts RunCache organizations as NetSuite customers keyed by `billing_info_id` |
| 2 | RunCache Monthly Revenue Sync | Reads `monthly_run_cache_revenue_v2` BigQuery view; creates Invoice or Credit Memo in NetSuite per RunCache org per month |
| 3 | Stripe NetSuite Customer ID Backfill | Reads `stripe_null_netsuite_customer_id_mapping_both` BigQuery view; writes resolved `netsuite_customer_id` into Stripe customer metadata |

---

## 4. Celigo preSavePage Scripts

### 4.1 Script 1 — Account Transform

| Field | Value |
|---|---|
| Script Name | preSaveDataTransformAccountRunCache |
| File Name | `preSaveDataTransformAccountRunCache.ts` |
| Used In Flow | RunCache Account Sync (Flow 1) |
| Purpose | Validates presence of `billing_address`; parses JSON to extract `billing_email`, `billing_country`, `billing_zip`; defaults `legal_name` to `billing_email` if null. Throws a fatal exception (halts entire flow) if required address fields are missing after parse. Soft-rejects records with unparseable `billing_address` JSON. |

**Validation Logic:**

| Field | Behaviour on Failure |
|---|---|
| `billing_address` absent | Soft reject — record pushed to errors, flow continues |
| `billing_email` / `billing_country` / `billing_zip` missing after parse | Fatal exception — entire Celigo flow halted |
| `billing_address` JSON malformed (parse error) | Soft reject — record pushed to errors, flow continues |
| `legal_name` null | Defaulted to `billing_email` (no error) |

---

### 4.2 Script 2 — Revenue Validation

| Field | Value |
|---|---|
| Script Name | preSaveDataValidationRevenueRunCache |
| File Name | `preSaveDataValidationRevenueRunCache.ts` |
| Used In Flow | RunCache Monthly Revenue Sync (Flow 2) |
| Purpose | Validates that all 7 required NetSuite invoice fields are present and non-null before each record is sent to NetSuite. Records missing any required field are soft-rejected to the errors array; the flow continues with valid records. |

**Required Fields Validated:**

| # | Field |
|---|---|
| 1 | `external_id` |
| 2 | `netsuite_customer_id` |
| 3 | `item_id` |
| 4 | `to_be_emailed` |
| 5 | `transaction_type` |
| 6 | `netsuite_amount` |
| 7 | `netsuite_quantity` |

---

## 5. BigQuery Components

### 5.1 dbt Models (Production Views)

| # | Model Name | Output View | Purpose |
|---|---|---|---|
| 1 | `monthly_run_cache_revenue_v2` | `private-internal.share_celigo.monthly_run_cache_revenue_v2` | Monthly invoice / credit memo rows for NetSuite. One row per RunCache org per month. |
| 2 | `stripe_null_netsuite_customer_id_mapping_both` | `private-internal.share_celigo.stripe_null_netsuite_customer_id_mapping_both` | Stripe customers missing `netsuite_customer_id` in metadata where a NetSuite customer can be resolved. Consumed by Flow 3. |

**Model location:** `dbt/run_cache/models/run_cache/`

**Materialization:** `view` — no data written to disk; rollback is a `bq rm` on the view.

---

### 5.2 Key Output Fields — `monthly_run_cache_revenue_v2`

| Field | Description |
|---|---|
| `external_id` | `RCINV{netsuite_customer_id}{YYYYMM}` (Invoice) or `RCCM{...}` (Credit Memo) |
| `transaction_type` | `Invoice` (amount ≥ 1) · `Credit Memo` (amount < 0) · `None` |
| `netsuite_customer_id` | NetSuite customer internal ID (keyed by `billing_info_id`) |
| `item_id` | NetSuite internal ID of the `RunCache` item |
| `netsuite_quantity` | Absolute value of `credits_used` (cache hits) |
| `netsuite_amount` | Absolute value of `revenue_amount` (rounded to 2 dp) |
| `payment_term` | Always `Autopay` |
| `to_be_emailed` | Customer email(s) for invoice notification |
| `billing_sync` | Always `monthly_run_cache_revenue` |
| `line_number` | Row number within `external_id` (for multi-line invoice support) |

---

### 5.3 Source SQL Query

| Field | Value |
|---|---|
| File | `sql/run_cache/run_cache_account_sync_v2.sql` |
| Used In Flow | RunCache Account Sync (Flow 1) |
| Purpose | Surfaces active RunCache organizations with subscription, billing, and Stripe attributes for Celigo to create/upsert NetSuite customers. One row per `run_cache_org_id`. Filtered to `type = 'RUN_CACHE_2026'`, `stripe_customer_id IS NOT NULL`, and 28-hour `_fivetran_synced` window. |

---

## 6. NetSuite Configuration

### 6.1 Item / SKU

| Field | Value |
|---|---|
| Item Name | `RunCache` |
| Source Table | `private-internal.netsuite2.item` |
| Usage | Referenced as `item_id` in every invoice line sent by Flow 2 |
| Note | Item must exist in NetSuite production before Flow 2 is activated |

---

### 6.2 Customer Entity Field (Existing)

| Label | ID | Type | Purpose |
|---|---|---|---|
| Fivetran Account ID | `custentity_ft_account_id_sf` | Free-Form Text | Stores `billing_info_id`; join key used by `monthly_run_cache_revenue_v2` to resolve `netsuite_customer_id` |

> This field already exists on the Customer record. No new custom fields are required for RunCache.

---

### 6.3 Transaction Configuration

| Setting | Value |
|---|---|
| External ID prefix — Invoice | `RCINV` (e.g. `RCINV12345202503`) |
| External ID prefix — Credit Memo | `RCCM` (e.g. `RCCM12345202503`) |
| Payment Term | `Autopay` |
| Product Type | `DBT_RUN_CACHE` (in revenue records source) |
| NetSuite Account URL | `https://5260239.app.netsuite.com` |

---

## 7. Source Tables

| Source | Project | Dataset | Table |
|---|---|---|---|
| Revenue records | `private-internal` | `staging` | `stg_pg_public_revenue_records` |
| RunCache accounts | `digital-arbor-400` | `pg_public` | `run_cache_accounts` |
| Billing info | `digital-arbor-400` | `pg_public` | `account_billing_info` |
| Fivetran accounts | `digital-arbor-400` | `pg_public` | `accounts` |
| NS customer | `private-internal` | `netsuite2` | `customer` |
| NS item | `private-internal` | `netsuite2` | `item` |
| Stripe customer | `private-internal` | `stripe` | `customer` |

---

## 8. Deployment Sequence

### Step 1 — GCP Permissions (Pre-requisite)

Confirm the production Service Account has the following roles before running dbt:

| Principal | Resource | Role |
|---|---|---|
| SA | `internal-analytics-data-access` | BigQuery Job User |
| SA | `digital-arbor-400` | BigQuery Data Viewer |
| SA | `private-internal` | BigQuery Data Viewer |
| SA | `private-internal.share_celigo` | BigQuery Data Editor |

---

### Step 2 — NetSuite Item

Confirm the `RunCache` item exists in `private-internal.netsuite2.item`. If not, create it in NetSuite production before proceeding.

```sql
select id, itemid from `private-internal`.`netsuite2`.`item`
where itemid = 'RunCache' and not _fivetran_deleted;
```

---

### Step 3 — Deploy dbt Models

```bash
cd dbt/run_cache

# 1. Validate connection
dbt debug

# 2. Compile and inspect generated SQL (no DB writes)
dbt compile --select monthly_run_cache_revenue_v2
dbt compile --select stripe_null_netsuite_customer_id_mapping_both

# 3. Deploy views
dbt run --select monthly_run_cache_revenue_v2
dbt run --select stripe_null_netsuite_customer_id_mapping_both
```

**Post-deploy validation:**
- [ ] Views visible at `private-internal.share_celigo.*`
- [ ] `external_id` format: `RCINV{customer_id}{YYYYMM}` / `RCCM{customer_id}{YYYYMM}`
- [ ] `payment_term = 'Autopay'` on all revenue rows
- [ ] No duplicate `external_id + line_number` combinations
- [ ] Stripe mapping view returns rows only where `stripe_netsuite_customer_id IS NULL`
- [ ] No staging refs (`dulcet-yew-246109`, `netsuite2_sandbox`) in generated SQL

---

### Step 4 — Celigo Integration Setup

1. Create or import the integration: **NetSuite – RunCache Integration**
2. Configure connections:
   - NetSuite: production account `5260239`
   - BigQuery: service account with Data Viewer on `private-internal` and `digital-arbor-400`
   - Stripe: production API key (for Flow 3 only)
3. Configure **Flow 1 — RunCache Account Sync:**
   - Export: BigQuery query → `sql/run_cache/run_cache_account_sync_v2.sql`
   - preSavePage: `preSaveDataTransformAccountRunCache`
   - Import: NetSuite Customer record, upsert on `custentity_ft_account_id_sf` = `billing_info_id`
4. Configure **Flow 2 — RunCache Monthly Revenue Sync:**
   - Export: BigQuery view → `private-internal.share_celigo.monthly_run_cache_revenue_v2`
   - preSavePage: `preSaveDataValidationRevenueRunCache`
   - Import: NetSuite Invoice or Credit Memo (driven by `transaction_type` field)
   - Idempotency key: `external_id`
5. Configure **Flow 3 — Stripe Metadata Backfill:**
   - Export: BigQuery view → `private-internal.share_celigo.stripe_null_netsuite_customer_id_mapping_both`
   - Import: Stripe Customer metadata update (`netsuite_customer_id` key)
   - Idempotency: view only returns rows where Stripe is missing the value
6. Upload preSavePage scripts to Celigo script library
7. Activate all three flows

---

### Step 5 — End-to-End Validation

| Check | Expected Result |
|---|---|
| Flow 1 runs | NetSuite customer records created/updated with `custentity_ft_account_id_sf = billing_info_id` |
| Flow 2 runs | NetSuite invoices created with `RCINV*` external IDs; credit memos with `RCCM*` |
| Flow 3 runs | Stripe customer metadata contains `netsuite_customer_id` for all rows returned by the view |
| Re-run Flow 2 | Idempotent — no duplicate invoices created (NetSuite deduplicates on `external_id`) |
| OLP pipeline check | Zero RunCache rows appear in `olp_overage_revenue` output |

---

## 9. Rollback Plan

1. Deactivate all three Celigo flows (Account Sync, Revenue Sync, Stripe Backfill).
2. Drop the BigQuery views — no data is written, rollback is immediate:
   ```bash
   bq rm -f private-internal:share_celigo.monthly_run_cache_revenue_v2
   bq rm -f private-internal:share_celigo.stripe_null_netsuite_customer_id_mapping_both
   ```
3. NetSuite invoices already created are retained for audit — do not delete; reverse via Credit Memo if needed.
4. Stripe metadata already written is retained — no automated rollback; correct manually if required.
5. Celigo flows can be re-activated once the root cause is resolved.

---

## 10. Open Items

| # | Item | Owner | Priority |
|---|---|---|---|
| 1 | Wire Celigo Flow 1 (Account Sync) in production | Systems Eng | P1 |
| 2 | Wire Celigo Flow 2 (Revenue Sync) in production | Systems Eng | P1 |
| 3 | Wire Celigo Flow 3 (Stripe Backfill) in production | Systems Eng | P1 |
| 4 | Confirm Celigo Integration URL post-setup | Systems Eng | P1 |
| 5 | Grant SA BigQuery Data Viewer on `private-internal.netsuite2` | GCP Admin | P0 |
| 6 | Grant SA BigQuery Job User on `internal-analytics-data-access` | GCP Admin | P0 |
| 7 | Confirm `run_cache_accounts` is deployed in `digital-arbor-400.pg_public` | Backend | P0 |
| 8 | Phase 2: update join keys when `billing_account_id` → `billing_info_id` | Systems Eng | P2 |

---

## 11. Related Resources

| Resource | Location |
|---|---|
| TDD | `sql/run_cache/RD-1160536_run_cache_billing_revenue_tdd.md` |
| Technical Spec | `sql/run_cache/RD-1161737_technical_spec.md` |
| dbt DEPLOYMENT.md | `dbt/run_cache/DEPLOYMENT.md` |
| Account Sync SQL | `sql/run_cache/run_cache_account_sync_v2.sql` |
| Account Transform Script | `javascripts/run_cache/preSaveDataTransformAccountRunCache.ts` |
| Revenue Validation Script | `javascripts/run_cache/preSaveDataValidationRevenueRunCache.ts` |
| Staging SQL | `sql/run_cache/staging/` |
| Jira Epic | RD-1161737 |
| Jira TDD | RD-1160536 |
