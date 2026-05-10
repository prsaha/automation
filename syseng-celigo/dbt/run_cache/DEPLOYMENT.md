# Deployment Guide — RunCache Monthly Billing DBT Models (Production)

**Epic**     : RD-1161737
**Author**   : Prabal Saha
**Date**     : 2026-03-18
**Status**   : Production pending 

---

## 1. Overview

This dbt project manages production RunCache billing models surfaced as BigQuery views
consumed by Celigo for NetSuite invoicing and Stripe metadata backfill.

**Pipeline flow:**

```
digital-arbor-400.pg_public (run_cache_accounts, account_billing_info, accounts)
private-internal.staging    (stg_pg_public_revenue_records)
private-internal.netsuite2  (customer, item)
private-internal.stripe     (customer)
        ↓  dbt run (monthly)
private-internal.share_celigo.<model_name>  [prod view]
        ↓  Celigo reads view
NetSuite API → Invoice / Credit Memo / Stripe metadata update
```

---

## 2. Project Structure

```
dbt/run_cache/
├── dbt_project.yml                                        # dbt project config
├── profiles_template.yml                                  # Copy to ~/.dbt/profiles.yml
├── DEPLOYMENT.md                                          # This file
└── models/
    └── run_cache/
        ├── sources.yml                                    # Source table definitions
        ├── monthly_run_cache_revenue_v2.sql               # RunCache invoice/credit memo sync
        └── stripe_null_netsuite_customer_id_mapping_both.sql  # Stripe NS customer ID backfill
```

---

## 3. Environment Reference

| Layer | Staging | Production |
|---|---|---|
| Billing tables | `dulcet-yew-246109.staging_billing_public` | `digital-arbor-400.pg_public` |
| Revenue records | `dulcet-yew-246109.staging_billing_public.revenue_records` | `private-internal.staging.stg_pg_public_revenue_records` |
| NetSuite | `private-internal.netsuite2_sandbox` | `private-internal.netsuite2` |
| Stripe | `dulcet-yew-246109.stripe` | `private-internal.stripe` |
| Output project | `dulcet-yew-246109` | `private-internal` |
| Output dataset | `share_celigo` | `share_celigo` |
| Auth | OAuth (local) | Service Account |

---

## 4. Prerequisites

### 4.1 GCP Permissions Required
| Principal | Resource | Role |
|-----------|----------|------|
| SA | `internal-analytics-data-access` | BigQuery Job User |
| SA | `digital-arbor-400` | BigQuery Data Viewer |
| SA | `private-internal` | BigQuery Data Viewer |
| SA | `private-internal.share_celigo` | BigQuery Data Editor (to create views) |



---

## 5. One-Time Setup

### 5.1 Configure profiles.yml
```bash
# Append prod profile from template
cat dbt/run_cache/profiles_template.yml >> ~/.dbt/profiles.yml
# Update keyfile path with actual service account key
```

> **Important:** The target dataset is controlled solely by `dataset` in `profiles.yml`.
> Do NOT set `+schema` in `dbt_project.yml` or `schema` in the model `{{ config() }}` block —
> dbt appends them to the profile dataset, producing duplicate names like `share_celigo_share_celigo`.

### 5.2 Verify connection
```bash
cd dbt/run_cache
dbt debug
# Expected: All checks passed!
```

---

## 6. Deployment Steps

```bash
cd dbt/run_cache

# 1. Compile to inspect generated SQL before running
dbt compile --select monthly_run_cache_revenue_v2
dbt compile --select stripe_null_netsuite_customer_id_mapping_both

# 2. Run models
dbt run --select monthly_run_cache_revenue_v2
dbt run --select stripe_null_netsuite_customer_id_mapping_both
```

**Post-deployment validation checklist:**
- [ ] Views created at `private-internal.share_celigo.*`
- [ ] `external_id` follows `RCINV{customer_id}{YYYYMM}` / `RCCM{customer_id}{YYYYMM}` format
- [ ] `payment_term` = `'Autopay'` for all rows in monthly revenue model
- [ ] No duplicate `external_id + line_number` combinations
- [ ] Stripe mapping model returns rows only where `stripe_netsuite_customer_id is null`
- [ ] Celigo can read both views

---

## 7. Models

| Model | Output view | Purpose |
|---|---|---|
| `monthly_run_cache_revenue_v2` | `private-internal.share_celigo.monthly_run_cache_revenue_v2` | Monthly invoice/credit memo sync to NetSuite |
| `stripe_null_netsuite_customer_id_mapping_both` | `private-internal.share_celigo.stripe_null_netsuite_customer_id_mapping_both` | Backfill missing netsuite_customer_id in Stripe metadata |

---

## 8. Source Tables

| Source | Project | Dataset | Table |
|--------|---------|---------|-------|
| Revenue records | `private-internal` | `staging` | `stg_pg_public_revenue_records` |
| RunCache accounts | `digital-arbor-400` | `pg_public` | `run_cache_accounts` |
| Billing info | `digital-arbor-400` | `pg_public` | `account_billing_info` |
| Fivetran accounts | `digital-arbor-400` | `pg_public` | `accounts` |
| NS customer | `private-internal` | `netsuite2` | `customer` |
| NS item | `private-internal` | `netsuite2` | `item` |
| Stripe customer | `private-internal` | `stripe` | `customer` |

---

## 9. Rollback

All models create **views only** — no data is written. To roll back:

```bash
bq rm -f private-internal:share_celigo.monthly_run_cache_revenue_v2
bq rm -f private-internal:share_celigo.stripe_null_netsuite_customer_id_mapping_both
```

Celigo fails gracefully if a view is absent (no data corruption).

---

## 10. Open Items

| # | Item | Owner | Priority |
|---|------|-------|----------|
| 1 | Wire Celigo flow for RunCache invoice creation | Systems Eng | P1 |
| 2 | Wire Celigo flow for RunCache customer creation | Systems Eng | P1 |
| 3 | ~~Confirm production NetSuite account ID for customer link URL~~ — resolved: `5260239` | Systems Eng | Done |
| 4 | Phase 2: update join keys when `billing_account_id` → `billing_info_id` | Systems Eng | P2 |

---

## 11. Related Resources

| Resource | Location |
|----------|----------|
| Staging SQL | `sql/run_cache/staging/` |
| TDD | `sql/run_cache/RD-1160536_run_cache_billing_revenue_tdd.md` |
| Technical Spec | `sql/run_cache/RD-1161737_technical_spec.md` |
| Jira Epic | RD-1161737 |
