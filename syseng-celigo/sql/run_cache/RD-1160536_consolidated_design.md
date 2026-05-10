# RunCache Billing & Revenue Integration — Consolidated Design
**Feature:** RD-1160536 — Pricing for Dbt Run Cache
**Date:** 2026-03-11
**Author:** Prabal Saha
**Status:** In Progress

---

## 1. Current Structure (Before RunCache)

### Data Model

```
pg_public.accounts
├── id                    TEXT  PK
├── billing_account_id    TEXT  (FK → account_billing_info, to be renamed Phase 2)
├── stripe_customer_id    TEXT  ← will be DROPPED in Phase 1
├── status                TEXT  (Customer | Frozen | Partner)
└── platform_tier         TEXT

pg_public.account_billing_info
├── account_id            TEXT  FK → accounts
├── updated_at            TIMESTAMPTZ  NOT NULL
├── tax_id                TEXT
├── legal_name            TEXT
├── billing_address       JSONB  NOT NULL DEFAULT '{}'
└── shipping_address      JSONB  NOT NULL DEFAULT '{}'

pg_public.subscriptions
├── id                    BIGSERIAL  PK
├── billing_account_id    TEXT       FK → accounts
├── salesforce_id         TEXT
├── payer_type            TEXT       (RESELLER | MARKETPLACE | ...)
├── third_party_payer_id  TEXT
└── type                  TEXT       (subscription SKU)

pg_public.revenue_records
├── id                    BIGSERIAL  PK
├── billing_account_id    TEXT       FK → accounts
├── revenue_date_utc      TIMESTAMPTZ
├── credits_used          NUMERIC
├── amount                NUMERIC
├── revenue_type          TEXT       (SELF_SERVICE | OVERAGE | ...)
└── product_type          TEXT       (OLP only today)
```

### Pipeline (Fivetran OLP Only)

```
Salesforce / CPQ
      ↓
pg_public.subscriptions
      ↓ Fivetran Connector
BigQuery: stg_pg_public_revenue_records
      ↓
001_account_sync.sql     → Celigo → NetSuite Sales Orders
002_subscription_sync.sql → Celigo → NetSuite Sales Orders
olp_overage_revenue.sql  → NetSuite OLP Invoices
```

---

## 2. New Structure (After Phase 1 & Phase 2)

### Phase 1 — Introduce RunCache Billing Structure

**New table:**
```
pg_public.run_cache_accounts                         ← NEW
├── run_cache_org_id    TEXT  PK  (Tobico org ID)
└── billing_info_id     TEXT  FK → account_billing_info
```

**Modified table — `account_billing_info`:**
```
pg_public.account_billing_info
├── id                  TEXT  PK  ← NEW (run_cache_{generated_id} for external)
├── account_id          TEXT  FK → accounts  (UNIQUE constraint added)
├── updated_at          TIMESTAMPTZ  NOT NULL
├── tax_id              TEXT
├── legal_name          TEXT
├── billing_address     JSONB  NOT NULL DEFAULT '{}'
├── shipping_address    JSONB  NOT NULL DEFAULT '{}'
└── stripe_customer_id  TEXT  ← NEW (moved from accounts)
```

**Modified table — `accounts`:**
```
pg_public.accounts
├── id                  TEXT  PK
├── billing_account_id  TEXT  (FK constraint dropped)
├── status              TEXT
└── platform_tier       TEXT
   stripe_customer_id   ← DROPPED
```

**Modified table — `revenue_records`:**
```
pg_public.revenue_records
  (existing columns unchanged in Phase 1)
  product_type = 'RUN_CACHE'  ← new enum value added
```

---

### Phase 2 — Full Billing Model Rework

**Table rename:**
```
account_billing_info  →  billing_info
```

**New junction table:**
```
pg_public.billing_info_management                    ← NEW
├── billing_info_id     TEXT  PK, FK → billing_info
└── account_id          TEXT  FK → accounts
```

**Column removed from `billing_info` (formerly `account_billing_info`):**
```
account_id  ← REMOVED (migrated to billing_info_management)
```

**Column rename on `accounts`:**
```
billing_account_id  →  billing_info_id
```

**Column renames across platform tables:**
```
billing_account_id  →  billing_info_id     on: revenue_records
                                               subscriptions
                                               daily_credit_usages
                                               account_history
                                               billing_invoices

billing_account_id  →  billing_entity_id   on: billing_payments
                                               subscription_history
```

### Final Phase 2 Data Model

```
pg_public.accounts
├── id                TEXT  PK
├── billing_info_id   TEXT  (renamed from billing_account_id)
├── status            TEXT
└── platform_tier     TEXT

pg_public.billing_info                               (renamed from account_billing_info)
├── id                TEXT  PK
├── updated_at        TIMESTAMPTZ  NOT NULL
├── tax_id            TEXT
├── legal_name        TEXT
├── billing_address   JSONB
├── shipping_address  JSONB
└── stripe_customer_id TEXT

pg_public.billing_info_management                    (new junction table)
├── billing_info_id   TEXT  PK, FK → billing_info
└── account_id        TEXT  FK → accounts

pg_public.run_cache_accounts
├── run_cache_org_id  TEXT  PK
└── billing_info_id   TEXT  FK → billing_info

pg_public.subscriptions
├── id                BIGSERIAL  PK
├── billing_info_id   TEXT  (renamed from billing_account_id)
├── salesforce_id     TEXT
└── type              TEXT

pg_public.revenue_records
├── id                BIGSERIAL  PK
├── billing_info_id   TEXT  (renamed from billing_account_id)
├── revenue_date_utc  TIMESTAMPTZ
├── credits_used      NUMERIC
├── amount            NUMERIC
├── revenue_type      TEXT
└── product_type      TEXT  (OLP | RUN_CACHE)
```

---

## 3. Data Models Impacted

### Phase 1 Changes

| Table | Type | Change | Breaking? |
|---|---|---|---|
| `account_billing_info` | Modified | Add `id` TEXT PK, `stripe_customer_id` TEXT, `UNIQUE(account_id)` | No — additive |
| `run_cache_accounts` | **New** | `run_cache_org_id PK`, `billing_info_id FK` | N/A — new table |
| `accounts` | Modified | DROP `stripe_customer_id`, DROP FK constraint | **Yes** — any query selecting `stripe_customer_id` from `accounts` breaks |
| `revenue_records` | Modified | New `product_type = 'RUN_CACHE'` enum value | No — additive |

### Phase 2 Changes

| Table | Type | Change | Breaking? |
|---|---|---|---|
| `account_billing_info` | **Renamed** | → `billing_info` | **Yes** — all references break |
| `account_billing_info.account_id` | **Removed** | Migrated to `billing_info_management` | **Yes** — all joins on `account_id` break |
| `billing_info_management` | **New** | Junction: `billing_info_id + account_id` | N/A — new table |
| `accounts.billing_account_id` | **Renamed** | → `billing_info_id` | **Yes** |
| `revenue_records.billing_account_id` | **Renamed** | → `billing_info_id` | **Yes** |
| `subscriptions.billing_account_id` | **Renamed** | → `billing_info_id` | **Yes** |
| `daily_credit_usages.billing_account_id` | **Renamed** | → `billing_info_id` | **Yes** |
| `account_history.billing_account_id` | **Renamed** | → `billing_info_id` | **Yes** |
| `billing_invoices.billing_account_id` | **Renamed** | → `billing_info_id` | **Yes** |
| `billing_payments.billing_account_id` | **Renamed** | → `billing_entity_id` | **Yes** |
| `subscription_history.billing_account_id` | **Renamed** | → `billing_entity_id` | **Yes** |

---

## 4. SQL Files Impacted

| SQL File | Phase 1 | Phase 2 | Notes |
|---|---|---|---|
| `001_account_sync_v2.sql` | Ready ✅ | Breaks — 3 changes | Table rename · join rewrite via `billing_info_management` · column rename |
| `002_subscription_sync_v2.sql` | Ready ✅ | Breaks — 3 changes | Both `account_billing_info` joins rewrite · column rename |
| `monthly_run_cache_revenue_v2.sql` | Ready ✅ | Breaks — 2 changes | Table rename · column rename across all 6 CTEs |
| `olp_overage_revenue.sql` | Ready ✅ | Breaks — 2 changes | Already migrated from `accounts` to `account_billing_info`; needs table + column rename in Phase 2 |
| `run_cache_account_sync_v2.sql` | Ready ✅ | Breaks — 2 changes | Table rename · column rename |

---

## 5. End-to-End Architecture Flow

```
╔══════════════════════════════════════════════════════════════════╗
║                    TOBICO (RunCache Side)                        ║
║                                                                  ║
║   RunCache Prod DB                                               ║
║   ├── Organization data  (org_id, stripe_customer_id)           ║
║   └── Consumption data   (org_id, utc_date, cache_hits)         ║
╚══════════════════════════════════════════════════════════════════╝
         │                              │
         │ Fivetran Connector            │ Fivetran Connector
         ▼                              ▼
╔═════════════════════╗     ╔═══════════════════════════╗
║ BigQuery             ║     ║ BigQuery                  ║
║ metrics_daily_agg    ║     ║ RunCache org data         ║
║ ├── org_id           ║     ║ (source for provisioning) ║
║ ├── utc_date         ║     ╚═══════════════════════════╝
║ ├── num_unique_      ║                  │
║ │   target_tables    ║                  │ BigQueryToAppRunCacheSync
║ └── loaded_at        ║                  │ (Java Task)
╚═════════════════════╝                  ▼
         │                  ╔════════════════════════════════════╗
         │                  ║       Fivetran Prod DB             ║
         │                  ║                                    ║
         │                  ║  run_cache_accounts                ║
         │                  ║  ├── run_cache_org_id  (PK)        ║
         │                  ║  └── billing_info_id               ║
         │                  ║                                    ║
         │                  ║  account_billing_info              ║
         │                  ║  ├── id  (run_cache_{})            ║
         │                  ║  └── stripe_customer_id            ║
         │                  ║                  │                 ║
         │                  ║                  │ Write           ║
         │                  ║                  ▼                 ║
         │                  ║             Stripe                 ║
         │                  ║   (billing_profile_id → metadata)  ║
         │                  ║                                    ║
         │                  ║  subscriptions                     ║
         │                  ║  └── type = 'RunCache_2026'        ║
         │                  ╚════════════════════════════════════╝
         │                                    │
         │ FillRunCacheRevenue                 │ Fivetran Connector
         │ (Java Task — daily)                 │ (Data Sync to BigQuery)
         │ applies pricing curve               │
         ▼                                    ▼
╔══════════════════════════════════════════════════════════════════╗
║                      Fivetran Prod DB                            ║
║   revenue_records                                                ║
║   ├── billing_account_id  →  run_cache_{generated_id}           ║
║   ├── revenue_date_utc    →  daily consumption date             ║
║   ├── credits_used        →  cache hits                         ║
║   ├── amount              →  dollars (pricing curve applied)    ║
║   ├── revenue_type        →  SELF_SERVICE                        ║
║   └── product_type        →  RUN_CACHE                          ║
╚══════════════════════════════════════════════════════════════════╝
         │
         │ Fivetran Connector (Data Sync)
         ▼
╔══════════════════════════════════════════════════════════════════╗
║                        BigQuery                                  ║
║                                                                  ║
║  stg_pg_public_revenue_records  ◄─── product_type = 'RUN_CACHE' ║
║  pg_public.run_cache_accounts                                    ║
║  pg_public.account_billing_info                                  ║
║  netsuite2.customer                                              ║
║  netsuite2.item  (RunCache_2026)                                 ║
╚══════════════════════════════════════════════════════════════════╝
         │
         │ monthly_run_cache_revenue_v2.sql  (DBT — monthly)
         │
         │  JOIN 1: revenue_records
         │          ↳ INNER JOIN run_cache_accounts
         │            (billing_account_id = billing_info_id)
         │            → org identity + run_cache_org_id
         │          ↳ INNER JOIN account_billing_info
         │            (billing_info_id = id)
         │            → stripe_customer_id
         │
         │  JOIN 2: netsuite2.customer
         │          → netsuite_customer_id, name, to_be_emailed
         │
         │  JOIN 3: netsuite2.item  (name = 'RunCache_2026')
         │          → item_id
         │
         │  TRANSFORMS: group by org + month · pricing already applied
         │              external_id = RCINV/RCCM + customer + YYYYMM
         │              payment_term = Autopay · transaction_type logic
         ▼
╔══════════════════════════════════════════════════════════════════╗
║             Invoice-Ready Dataset (BigQuery)                     ║
║                                                                  ║
║  Per org per month:                                              ║
║  external_id · billing_account_id · org_id · stripe_customer_id ║
║  netsuite_customer_id · netsuite_customer_name · to_be_emailed  ║
║  item_id · product_type · revenue_type · quantity · amount      ║
║  netsuite_quantity · netsuite_amount · rate                      ║
║  payment_term · transaction_type · line_number                   ║
╚══════════════════════════════════════════════════════════════════╝
         │
         │ BigQueryToAppSyncNetsuiteFinancials
         ▼
╔══════════════════════════════════════════════════════════════════╗
║                         NetSuite                                 ║
║                                                                  ║
║   Invoice  (RCINV{customer}{YYYYMM})                             ║
║   ├── Customer:   netsuite_customer_id                           ║
║   ├── Line item:  RunCache_2026 · quantity · amount              ║
║   ├── Email to:   to_be_emailed                                  ║
║   └── Term:       Autopay                                        ║
║                        │                                         ║
║                        │ Charge through Stripe                   ║
║                        ▼                                         ║
║              stripe_customer_id                                   ║
╚══════════════════════════════════════════════════════════════════╝


  ── FIVETRAN OLP PIPELINE (shielded from RunCache) ────────────────

  001_account_sync_v2.sql       → NOT EXISTS (run_cache_accounts)
  002_subscription_sync_v2.sql  → NOT EXISTS (run_cache_accounts)
  olp_overage_revenue.sql       → billing_account_type = 'FIVETRAN'
                                   (Phase 1 guard until Phase 2 rename)
```

---

## 6. Guard Summary — How Fivetran OLP Is Protected

| Query | Guard Mechanism | Protects Against |
|---|---|---|
| `001_account_sync_v2` | `NOT EXISTS (run_cache_accounts WHERE billing_info_id = acct_info.id)` | RunCache accounts entering Fivetran account sync |
| `002_subscription_sync_v2` | `NOT EXISTS (run_cache_accounts WHERE billing_info_id = ls.billing_account_id)` | RunCache subscriptions entering Fivetran SO pipeline |
| `olp_overage_revenue` | `account_billing_info.billing_account_type = 'FIVETRAN'` (Phase 1) | RunCache revenue entering Fivetran OLP invoicing |
| `monthly_run_cache_revenue_v2` | `INNER JOIN run_cache_accounts` (allowlist) | Fivetran accounts entering RunCache invoicing |

---

## 7. Phase Readiness Checklist

### Phase 1
- [ ] `run_cache_accounts` table created in Fivetran Prod DB
- [ ] `account_billing_info.id` and `stripe_customer_id` columns added and backfilled
- [ ] `accounts.stripe_customer_id` dropped after backfill confirmed
- [ ] `BigQueryToAppRunCacheSync` task deployed and tested
- [ ] `FillRunCacheRevenue` task deployed and tested
- [ ] `002_subscription_sync_v2.sql` deployed (RunCache bleed guard — P0)
- [ ] `001_account_sync_v2.sql` deployed
- [ ] `monthly_run_cache_revenue_v2.sql` deployed (post Phase 1 schema confirm)
- [ ] Finance UAT: verify `RCINV`/`RCCM` invoices visible and separate from Fivetran OLP

### Phase 2
- [ ] All SQL files updated: `account_billing_info` → `billing_info`
- [ ] All SQL files updated: `billing_account_id` → `billing_info_id`
- [ ] `002_subscription_sync` and `001_account_sync` joins rewritten via `billing_info_management`
- [ ] Regression test: zero Fivetran OLP row count change after Phase 2 deploy
- [ ] Regression test: zero RunCache invoice row count change after Phase 2 deploy
