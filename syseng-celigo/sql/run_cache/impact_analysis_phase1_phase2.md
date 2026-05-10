# Impact Analysis: Phase 1 & Phase 2 Schema Changes
**Feature:** RD-1160536 — Pricing for Dbt Run Cache
**Date:** 2026-03-11
**Author:** Prabal Saha
**Scope:** `001_account_sync_v2.sql` · `002_subscription_sync.sql` · `monthly_run_cache_revenue_v2.sql`

---

## Phase Summary (from PDF TDD)

### Phase 1 — Introduce RunCache billing structure
| Change | Detail |
|---|---|
| New table | `run_cache_accounts` (`run_cache_org_id TEXT PK`, `billing_info_id TEXT FK → account_billing_info`) |
| `account_billing_info` new columns | `id TEXT` (PK, `run_cache_{generated_id}` for external), `stripe_customer_id TEXT` (moved from `accounts`) |
| `account_billing_info` new constraint | `UNIQUE(account_id)` |
| `accounts` | `DROP COLUMN stripe_customer_id` · `DROP CONSTRAINT accounts_billing_account_id_fkey` |

### Phase 2 — Full billing model rework
| Change | Detail |
|---|---|
| Table rename | `account_billing_info` → `billing_info` |
| Column removed | `account_billing_info.account_id` dropped |
| New junction table | `billing_info_management` (`billing_info_id PK/FK → billing_info`, `account_id FK → accounts`) |
| Column rename on `accounts` | `billing_account_id` → `billing_info_id` |
| Column rename across tables | `billing_account_id` → `billing_info_id` on: `revenue_records`, `subscriptions`, `daily_credit_usages`, `account_history`, `billing_invoices` |
| Column rename (different name) | `billing_account_id` → `billing_entity_id` on: `billing_payments`, `subscription_history` |

---

## 001_account_sync_v2.sql

### Current join chain
```
pg_public.subscriptions (billing_account_id)
  → pg_public.accounts (id)
  → pg_public.account_billing_info (account_id)
  → pg_public.run_cache_accounts (billing_info_id)   ← exclusion guard
```

### Phase 1 Impact

| Element | Impact | Severity | Action Required |
|---|---|---|---|
| `accounts.stripe_customer_id` dropped | Not referenced in this file | None | None |
| `accounts` FK constraint dropped | Join uses `acct.id`, not FK — unaffected | None | None |
| `account_billing_info.id` added | Left join uses `account_id` — still valid in Phase 1 | None | None |
| `run_cache_accounts` created | `NOT EXISTS` guard now has the table to reference | **Enabler** | Query is Phase 1-ready as written |

**Phase 1 verdict: No breaking changes. Query works as-is after Phase 1 deploys.**

---

### Phase 2 Impact

| Element | Current Reference | After Phase 2 | Severity | Action Required |
|---|---|---|---|---|
| `account_billing_info` table | `pg_public.account_billing_info AS acct_info` | `billing_info` | **BREAKING** | Rename table reference to `billing_info` |
| `account_billing_info.account_id` join | `ON acct.id = acct_info.account_id` | Column removed | **BREAKING** | Rewrite join via `billing_info_management`: `billing_info_management ON billing_info_id = billing_info.id` |
| `subscriptions.billing_account_id` | `ls.billing_account_id` (payer logic + QUALIFY) | `billing_info_id` | **BREAKING** | Rename to `billing_info_id` throughout |
| `run_cache_accounts.billing_info_id` guard | `WHERE billing_info_id = acct_info.id` | Unchanged | None | None |

**Phase 2 verdict: 3 breaking changes. Requires table rename, join rewrite via `billing_info_management`, and column rename.**

---

## 002_subscription_sync.sql

### Current join chain
```
pg_public.subscriptions (billing_account_id, third_party_payer_id)
  → pg_public.account_billing_info acct_payer  (ON third_party_payer_id = acct_payer.account_id)
  → pg_public.account_billing_info acct_customer (ON billing_account_id = acct_customer.account_id)
```

### Phase 1 Impact

| Element | Impact | Severity | Action Required |
|---|---|---|---|
| `account_billing_info.id` added | Joins use `account_id` — still valid in Phase 1 | None | None |
| `account_billing_info.stripe_customer_id` added | Not referenced | None | None |
| `accounts.stripe_customer_id` dropped | Not referenced | None | None |
| `run_cache_accounts` created | **No RunCache exclusion guard exists in this file** | **GAP** | Add `AND NOT EXISTS (SELECT 1 FROM pg_public.run_cache_accounts WHERE billing_info_id = ls.billing_account_id)` to prevent RunCache subscriptions from flowing into Fivetran SO pipeline |

**Phase 1 verdict: No breaking changes. However, a RunCache bleed risk exists — exclusion guard must be added before Phase 1 deploys.**

---

### Phase 2 Impact

| Element | Current Reference | After Phase 2 | Severity | Action Required |
|---|---|---|---|---|
| `account_billing_info` (payer join) | `pg_public.account_billing_info acct_payer ON third_party_payer_id = acct_payer.account_id` | `billing_info`, `account_id` removed | **BREAKING** | Rewrite: join `billing_info_management` ON `account_id = third_party_payer_id`, then join `billing_info` ON `billing_info_id` |
| `account_billing_info` (customer join) | `pg_public.account_billing_info acct_customer ON billing_account_id = acct_customer.account_id` | `billing_info`, `account_id` removed | **BREAKING** | Rewrite: join `billing_info_management` ON `account_id`, then join `billing_info` ON `billing_info_id` |
| `subscriptions.billing_account_id` | `ls.billing_account_id` in `payer_account_id` COALESCE and filter comments | `billing_info_id` | **BREAKING** | Rename to `billing_info_id` throughout |
| `PARTITION BY salesforce_id` | Unchanged in Phase 2 | Unchanged | None | None |
| `_fivetran_synced` filter on `acct_customer` / `acct_payer` | Unchanged column names | Unchanged | None | None |

**Phase 2 verdict: 3 breaking changes. Both `account_billing_info` joins must be rewritten to go through the new `billing_info_management` junction table.**

---

## monthly_run_cache_revenue_v2.sql

### Current join chain
```
stg_pg_public_revenue_records (billing_account_id, product_type = 'RUN_CACHE')
  → pg_public.run_cache_accounts (billing_info_id)
  → pg_public.account_billing_info (id)
  → netsuite2.customer
  → netsuite2.item
```

### Phase 1 Impact

| Element | Impact | Severity | Action Required |
|---|---|---|---|
| `run_cache_accounts` created | Core join now has the table to reference | **Enabler** | Query only works AFTER Phase 1 deploys |
| `account_billing_info.id` added | Join `ON run_cache_accounts.billing_info_id = account_billing_info.id` now valid | **Enabler** | Works after Phase 1 |
| `account_billing_info.stripe_customer_id` added | Referenced in first CTE — now available | **Enabler** | Works after Phase 1 |
| `revenue_records.billing_account_id` | Join to `run_cache_accounts.billing_info_id` — valid in Phase 1 | None | None |

**Phase 1 verdict: No breaking changes. Query is fully dependent on Phase 1 deploying — do not run before Phase 1 is complete.**

---

### Phase 2 Impact

| Element | Current Reference | After Phase 2 | Severity | Action Required |
|---|---|---|---|---|
| `account_billing_info` table | `pg_public.account_billing_info` | `billing_info` | **BREAKING** | Rename table reference to `billing_info` |
| `account_billing_info.id` join | `ON run_cache_accounts.billing_info_id = account_billing_info.id` | Table renamed only — `id` column unchanged | **BREAKING** (table name only) | Update table name to `billing_info` |
| `revenue_records.billing_account_id` | `revenue_records.billing_account_id` in first CTE and all subsequent CTEs | `billing_info_id` | **BREAKING** | Rename to `billing_info_id` throughout all 6 CTEs |
| `run_cache_accounts.billing_info_id` | Used as join key | Unchanged — column already uses Phase 2 naming | None | None |
| NetSuite joins | `netsuite2.customer`, `netsuite2.item` | Not in scope of Phase 2 | None | None |

**Phase 2 verdict: 2 breaking changes. Table rename (`account_billing_info` → `billing_info`) and column rename (`billing_account_id` → `billing_info_id`) across all CTEs.**

---

## Consolidated Impact Summary

| SQL File | Phase 1 Status | Phase 1 Actions | Phase 2 Status | Phase 2 Actions |
|---|---|---|---|---|
| `001_account_sync_v2` | **Ready** | None | **Breaks** | Rename table · Rewrite join via `billing_info_management` · Rename column |
| `002_subscription_sync` | **Gap** | Add RunCache exclusion guard | **Breaks** | Rename table (×2) · Rewrite both joins via `billing_info_management` · Rename column |
| `monthly_run_cache_revenue_v2` | **Ready\*** | \*Deploy after Phase 1 only | **Breaks** | Rename table · Rename column across all CTEs |

---

## Recommended Actions Before Phase 1

| Priority | File | Action |
|---|---|---|
| **P0** | `002_subscription_sync.sql` | Add RunCache exclusion guard (`NOT EXISTS run_cache_accounts`) — bleed risk |
| P1 | `monthly_run_cache_revenue_v2.sql` | Do not deploy until Phase 1 schema is confirmed complete |
| P2 | All files | Add Phase 2 rename TODOs as inline comments for the next sprint |

## Recommended Actions Before Phase 2

| File | Change |
|---|---|
| `001_account_sync_v2.sql` | `account_billing_info` → `billing_info` · `account_id` join → `billing_info_management` · `billing_account_id` → `billing_info_id` |
| `002_subscription_sync.sql` | Same table/join rewrites × 2 (payer + customer joins) · `billing_account_id` → `billing_info_id` |
| `monthly_run_cache_revenue_v2.sql` | `account_billing_info` → `billing_info` · `billing_account_id` → `billing_info_id` across all 6 CTEs |
