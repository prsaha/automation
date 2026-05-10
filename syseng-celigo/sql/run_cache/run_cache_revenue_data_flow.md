# RunCache Revenue Data Flow — NetSuite Invoice Pipeline
**Feature:** RD-1160536 — Pricing for Dbt Run Cache
**Date:** 2026-03-11
**Author:** Prabal Saha

---

## End-to-End Data Flow

```
╔══════════════════════════════════════════════════════════════════╗
║                    TOBICO (RunCache Side)                        ║
║                                                                  ║
║   RunCache Prod DB                                               ║
║   ├── Organization data  (org_id, stripe_customer_id)           ║
║   └── Consumption data   (org_id, utc_date, cache_hits)         ║
╚══════════════════════════════════════════════════════════════════╝
         │                          │
         │ Fivetran Connector        │ Fivetran Connector
         │ (Data Sync)               │ (Data Sync)
         ▼                          ▼
╔═══════════════════╗    ╔══════════════════════════════╗
║     BigQuery      ║    ║          BigQuery             ║
║                   ║    ║                              ║
║  metrics_daily_agg║    ║  RunCache org data           ║
║  ├── org_id       ║    ║  (source for provisioning)   ║
║  ├── utc_date     ║    ║                              ║
║  ├── num_unique_  ║    ╚══════════════════════════════╝
║  │   target_tables║              │
║  └── loaded_at    ║              │ BigQueryToAppRunCacheSync
╚═══════════════════╝              │ (Java Task — on new org detected)
         │                         ▼
         │              ╔══════════════════════════════════════════╗
         │              ║         Fivetran Prod DB                 ║
         │              ║                                          ║
         │              ║  run_cache_accounts                      ║
         │              ║  ├── run_cache_org_id  (PK)             ║
         │              ║  └── billing_info_id   (FK → abi)       ║
         │              ║                                          ║
         │              ║  account_billing_info                    ║
         │              ║  ├── id                (PK, run_cache_{})║
         │              ║  └── stripe_customer_id                  ║
         │              ║                                          ║
         │              ║  subscriptions                           ║
         │              ║  ├── billing_account_id                  ║
         │              ║  └── type = 'RunCache_2026'              ║
         │              ╚══════════════════════════════════════════╝
         │                         │
         │ FillRunCacheRevenue      │ Fivetran Connector
         │ (Java Task — daily)      │ (Data Sync)
         │ applies pricing curve    │
         ▼                         ▼
╔══════════════════════════════════════════════════════════════════╗
║                      Fivetran Prod DB                            ║
║                                                                  ║
║   revenue_records                                                ║
║   ├── billing_account_id   → run_cache_{generated_id}           ║
║   ├── revenue_date_utc     → daily consumption date             ║
║   ├── credits_used         → cache hits for the day             ║
║   ├── amount               → dollars (pricing curve applied)    ║
║   ├── revenue_type         → SELF_SERVICE                        ║
║   └── product_type         → RUN_CACHE                          ║
╚══════════════════════════════════════════════════════════════════╝
         │
         │ Fivetran Connector (Data Sync)
         ▼
╔══════════════════════════════════════════════════════════════════╗
║                        BigQuery                                  ║
║                                                                  ║
║  private-internal.staging.stg_pg_public_revenue_records         ║
║  ├── billing_account_id                                          ║
║  ├── revenue_date_utc                                            ║
║  ├── credits_used                                                ║
║  ├── amount                                                      ║
║  ├── revenue_type  = 'SELF_SERVICE'                              ║
║  └── product_type  = 'RUN_CACHE'                                 ║
║                                                                  ║
║  digital-arbor-400.pg_public.run_cache_accounts                  ║
║  ├── run_cache_org_id                                            ║
║  └── billing_info_id                                             ║
║                                                                  ║
║  digital-arbor-400.pg_public.account_billing_info                ║
║  ├── id  (= billing_info_id)                                     ║
║  └── stripe_customer_id                                          ║
╚══════════════════════════════════════════════════════════════════╝
         │
         │ monthly_run_cache_revenue_v2.sql (DBT — monthly)
         │
         │  JOIN 1: stg_pg_public_revenue_records
         │          ↳ INNER JOIN run_cache_accounts
         │            (billing_account_id = billing_info_id)
         │            → confirms RunCache org, gets run_cache_org_id
         │          ↳ INNER JOIN account_billing_info
         │            (billing_info_id = id)
         │            → gets stripe_customer_id
         │
         │  JOIN 2: netsuite2.customer
         │          (billing_account_id = custentity_ft_account_id_sf)
         │          → gets netsuite_customer_id, company name, to_be_emailed
         │
         │  JOIN 3: netsuite2.item
         │          (item.name = 'RunCache_2026')
         │          → gets item_id for invoice line
         │
         │  TRANSFORMS:
         │          → GROUP BY org + month
         │          → quantity  = sum(credits_used)
         │          → amount    = sum(revenue_amount) rounded
         │          → external_id = RCINV/RCCM + customer_id + YYYYMM
         │          → payment_term = Autopay
         │          → transaction_type = Invoice | Credit Memo | None
         ▼
╔══════════════════════════════════════════════════════════════════╗
║              Invoice-Ready Dataset (BigQuery output)             ║
║                                                                  ║
║  One row per RunCache org per month                              ║
║  ├── external_id          RCINV{customer_id}{YYYYMM}            ║
║  ├── revenue_month_start  2026-03-01                             ║
║  ├── revenue_month_end    2026-03-31                             ║
║  ├── billing_account_id   run_cache_{generated_id}              ║
║  ├── org_id               Tobico org ID                          ║
║  ├── stripe_customer_id   cus_xxxxx                              ║
║  ├── netsuite_customer_id NS customer ID                         ║
║  ├── netsuite_customer_name company name                         ║
║  ├── to_be_emailed        invoice email(s)                       ║
║  ├── item_id              NS item ID for RunCache_2026           ║
║  ├── product_type         RUN_CACHE                              ║
║  ├── revenue_type         SELF_SERVICE                           ║
║  ├── quantity             monthly cache hits                     ║
║  ├── amount               dollar value (signed)                  ║
║  ├── netsuite_quantity    abs(quantity)                          ║
║  ├── netsuite_amount      abs(amount)                            ║
║  ├── rate                 unit price                             ║
║  ├── payment_term         Autopay                                ║
║  ├── transaction_type     Invoice | Credit Memo | None           ║
║  └── line_number          line sequence per invoice              ║
╚══════════════════════════════════════════════════════════════════╝
         │
         │ BigQueryToAppSyncNetsuiteFinancials
         │ (reads revenue_records + billing_profile from BigQuery)
         ▼
╔══════════════════════════════════════════════════════════════════╗
║                         NetSuite                                 ║
║                                                                  ║
║  Creates:  Invoice (external_id = RCINV...)                      ║
║         or Credit Memo (external_id = RCCM...)                   ║
║                                                                  ║
║  Line item:  RunCache_2026 SKU                                   ║
║  Bill to:    netsuite_customer_id                                 ║
║  Email to:   to_be_emailed                                       ║
║  Term:       Autopay                                             ║
║                    │                                             ║
║                    │ Charge through Stripe                        ║
║                    ▼                                             ║
║              stripe_customer_id (cus_xxxxx)                      ║
╚══════════════════════════════════════════════════════════════════╝
```

---

## Table Ownership by System

| Table | System | Owner | Updated By |
|---|---|---|---|
| `metrics_daily_agg` | BigQuery | Tobico | Tobico (hourly upload) |
| `run_cache_accounts` | Fivetran Prod DB → BigQuery | Fivetran | `BigQueryToAppRunCacheSync` |
| `account_billing_info` | Fivetran Prod DB → BigQuery | Fivetran | `BigQueryToAppRunCacheSync` |
| `subscriptions` | Fivetran Prod DB | Fivetran | `BigQueryToAppRunCacheSync` |
| `revenue_records` | Fivetran Prod DB → BigQuery | Fivetran | `FillRunCacheRevenue` (daily) |
| `stg_pg_public_revenue_records` | BigQuery | Fivetran | Fivetran Connector sync |
| `netsuite2.customer` | BigQuery | NetSuite | Fivetran Connector sync |
| `netsuite2.item` | BigQuery | NetSuite | Fivetran Connector sync |
| Invoice-ready dataset | BigQuery | Sys Eng | `monthly_run_cache_revenue_v2.sql` (monthly) |

---

## Key Constraints

| Rule | Detail |
|---|---|
| Stripe metadata timing | `billing_profile_id` must be written to Stripe customer metadata **before** `FillRunCacheRevenue` runs — fail fast if Stripe API unavailable |
| Deduplication | `external_id` (`RCINV`/`RCCM` + customer + YYYYMM) prevents duplicate NetSuite invoices on reruns |
| RunCache isolation | `run_cache_accounts` join ensures only RunCache orgs appear in this pipeline — Fivetran OLP is shielded via `NOT EXISTS (run_cache_accounts)` in `001` and `002` |
| Corrections | Not handled automatically — Tobico alerts via Slack, handled manually (out of scope per TDD) |
| Phase 2 rename | `billing_account_id` → `billing_info_id` across all tables — all join keys in this flow will need updating |
