
================================================================================
  TECHNICAL SPEC — RunCache Billing & Revenue Integration
  Epic   : RD-1161737
  Parent : RD-1160536
  Author : Prabal Saha
  Date   : 2026-03-17
  Status : In Progress
================================================================================


1. OVERVIEW
───────────
RunCache is a new dbt Core plugin (by Tobico) billed on consumption.
This spec covers the Systems Engineering work to integrate RunCache
into the existing Fivetran billing pipeline (BQ → Celigo → NetSuite).

Scope: BigQuery onwards. Stripe provisioning and BigQueryToAppRunCacheSync
are owned by the backend team.


2. ARCHITECTURE
───────────────

  STORAGE                          COMPUTE                    DESTINATION
  ───────                          ───────                    ───────────

  digital-arbor-400                                           NetSuite
  └── pg_public                    internal-analytics-            │
      ├── accounts              ┌──  data-access (NEW)            │
      ├── subscriptions         │                            ┌────┴────┐
      ├── account_billing_info  │   runs all queries         │ Invoices│
      ├── run_cache_accounts    │                            │ Customers│
      └── revenue_records       │                            └────┬────┘
                                │                                 │
  private-internal              │                                 │
  ├── staging                   │        Celigo ───────────────────┘
  │   └── stg_pg_public_        │           │
  │       revenue_records       │           │ reads from
  ├── netsuite2                 │           ▼
  │   ├── customer              │    share_celigo (views)
  │   ├── item                  │    ├── olp_and_overage_monthly_billing  (existing)
  │   └── partner               │    ├── monthly_run_cache_revenue_v2     (NEW)
  └── share_celigo ─────────────┘    └── run_cache_account_sync_v2        (NEW)


3. PIPELINE CHANGES
───────────────────

  ┌─────────────────────┬──────────────────────────────┬────────────────────────────────┐
  │ Pipeline            │ Existing Fivetran             │ New RunCache                   │
  ├─────────────────────┼──────────────────────────────┼────────────────────────────────┤
  │ Account Sync        │ 001_account_sync_v2.sql       │ run_cache_account_sync_v2.sql  │
  │                     │ Excludes RunCache via         │ RunCache only via              │
  │                     │ NOT EXISTS (run_cache_        │ INNER JOIN run_cache_accounts  │
  │                     │ accounts)                     │ WHERE type = 'RunCache_2026'   │
  ├─────────────────────┼──────────────────────────────┼────────────────────────────────┤
  │ Subscription Sync   │ 002_subscription_sync_v2.sql  │ NOT NEEDED                     │
  │                     │ Excludes RunCache via         │ Subscription data embedded     │
  │                     │ NOT EXISTS (run_cache_        │ inside account sync query      │
  │                     │ accounts)                     │                                │
  ├─────────────────────┼──────────────────────────────┼────────────────────────────────┤
  │ Billing Sync        │ olp_overage_revenue_v2.sql    │ monthly_run_cache_revenue_v2   │
  │                     │ Refactored:                   │ New DBT transformation:        │
  │                     │ - Remove accounts table       │ - product_type = 'RUN_CACHE'   │
  │                     │ - Add RunCache exclusion      │ - INNER JOIN run_cache_accounts│
  │                     │ - Add billing_sync field      │ - item.itemid = 'RunCache_2026'│
  │                     │                               │ - External ID: RCINV / RCCM   │
  │                     │                               │ - Payment term: Autopay always │
  └─────────────────────┴──────────────────────────────┴────────────────────────────────┘


4. DATA FLOW
────────────

  Tobico (RunCache usage)
        │
        │  FillRunCacheRevenue (Java, daily)
        │  writes product_type = 'RUN_CACHE'
        ▼
  digital-arbor-400.pg_public.revenue_records
        │
        │  BigQueryToAppRunCacheSync (Java)
        │  provisions run_cache_accounts + account_billing_info
        ▼
  digital-arbor-400.pg_public.run_cache_accounts
  digital-arbor-400.pg_public.account_billing_info
        │
        │  DBT (monthly)
        ▼
  private-internal.share_celigo.monthly_run_cache_revenue_v2  (VIEW)
  private-internal.share_celigo.run_cache_account_sync_v2     (VIEW)
        │
        │  Celigo reads views
        ▼
  NetSuite API
  ├── Customer record  (from run_cache_account_sync_v2)
  └── Invoice / CM     (from monthly_run_cache_revenue_v2)


5. KEY DESIGN DECISIONS
───────────────────────

  A. run_cache_accounts as identity gate
     ─────────────────────────────────────
     All RunCache queries use INNER JOIN run_cache_accounts as an allowlist.
     All Fivetran queries use NOT EXISTS (run_cache_accounts) as an exclusion.
     This ensures zero overlap between the two pipelines.

  B. stripe_customer_id source (Phase 1)
     ─────────────────────────────────────
     accounts.stripe_customer_id is DROPPED in Phase 1.
     RunCache  → account_billing_info.stripe_customer_id
     Fivetran  → salesforce.account.stripe_customer_id_c

  C. External ID prefixes
     ─────────────────────
     Fivetran OLP  →  CBPINV / CBPCM
     RunCache      →  RCINV  / RCCM

  D. Payment term
     ─────────────
     Fivetran OLP  →  Autopay (SELF_SERVICE) or Net 30
     RunCache      →  Always Autopay

  E. billing_sync traceability field
     ──────────────────────────────────
     Every invoice row carries a billing_sync tag:
     Fivetran OLP  →  'olp_overage_revenue'
     RunCache      →  'monthly_run_cache_revenue_v2'

  F. Item lookup
     ────────────
     Fivetran OLP  →  item.custitem_account_tier + usage_revenue_type_id
     RunCache      →  item.itemid = 'RunCache_2026'  (single SKU)

  G. Compute migration
     ──────────────────
     All pg_public table refs use explicit digital-arbor-400 prefix.
     Compute moves to internal-analytics-data-access.
     SA: syseng-decoupling-prod-sa@fivetran-donkeys.iam.gserviceaccount.com
     Needs: BigQuery Job User on internal-analytics-data-access
            BigQuery Data Viewer on digital-arbor-400
            BigQuery Data Viewer on private-internal


6. FILE INVENTORY
─────────────────

  sql/run_cache/                                         [DBT model path]
  ├── monthly_run_cache_revenue_v2.sql                   PRODUCTION ✅
  ├── run_cache_account_sync_v2.sql                      PRODUCTION ✅
  ├── staging/
  │   ├── monthly_run_cache_revenue_v2_stg.sql           STAGING (dulcet-yew-246109)
  │   └── run_cache_account_sync_v2_stg.sql              STAGING
  └── archive/
      ├── monthly_run_cache_revenue.sql                  SUPERSEDED v1
      └── run_cache_account_sync.sql                     SUPERSEDED v1

  sql/Fivetran_RunCache/to_be_refactored/                [pending deployment]
  ├── 001_account_sync_v2.sql                            READY ✅
  ├── 002_subscription_sync_v2.sql                       READY ✅
  ├── olp_overage_revenue_v2.sql                         READY ✅
  └── olp_and_overage_monthly_billing.sql                ORIGINAL (reference)

  sql/dbt_project.yml                                    DBT project config
  sql/profiles_template.yml                              DBT profile template


7. OPEN ITEMS
─────────────

  #  Item                                                Owner         Priority
  ── ────────────────────────────────────────────────── ────────────  ────────
  1  Confirm product_type value in prod:                 Backend       P0
     'RUN_CACHE' or 'DBT_RUN_CACHE'?

  2  Deploy run_cache_accounts to staging                Backend       P0
     (dulcet-yew-246109.staging_billing_public)

  3  Grant BigQuery Data Viewer on netsuite2             GCP Admin     P0
     (dulcet-yew-246109) to run staging query end-to-end

  4  Grant SA permissions on internal-analytics-         GCP Admin     P1
     data-access for compute migration

  5  Confirm private-internal project name vs            Infra         P1
     internal-analytics-data-access relationship

  6  Wire Celigo flow for RunCache Customer creation     Systems Eng   P1
     (run_cache_account_sync_v2 → NetSuite Customer)

  7  Wire Celigo flow for RunCache invoice creation      Systems Eng   P1
     (monthly_run_cache_revenue_v2 → NetSuite Invoice)

  8  Phase 2: update join keys when billing_account_id   Systems Eng   P2
     → billing_info_id rename deploys


8. PHASE READINESS
──────────────────

  Phase 1 (current)
  ✅  run_cache_accounts table defined
  ✅  account_billing_info.id + stripe_customer_id added
  ✅  All SQL queries written against Phase 1 schema
  ⏳  run_cache_accounts not yet in staging environment
  ⏳  product_type value in revenue_records TBC

  Phase 2 (future)
  ⏳  account_billing_info → billing_info rename
  ⏳  billing_account_id  → billing_info_id rename
  ⏳  billing_info_management junction table introduced
  ⏳  All v2 SQL files need join key updates at Phase 2

================================================================================
