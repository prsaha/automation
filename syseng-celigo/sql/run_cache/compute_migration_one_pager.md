# BigQuery Compute Migration — One Pager
**Author:** Prabal Saha | **Date:** 2026-03-16 | **Epic:** RD-1161737

---

## What Changed

The infra team separated **compute** (query execution) from **storage** (where data lives). Data does not move — only where queries run changes.

| | Before | After |
|---|---|---|
| Compute | `digital-arbor-400` | `internal-analytics-data-access` |
| Storage | `digital-arbor-400` / `private-internal` | unchanged |

---

## Architecture

```
                    BEFORE
    ┌──────────────────────────────────┐
    │        digital-arbor-400         │
    │   compute  +  pg_public storage  │
    │                                  │
    │  pg_public.accounts  ← unqualified refs worked
    └──────────────────────────────────┘


                    AFTER
    ┌─────────────────────────────┐
    │ internal-analytics-data-    │
    │ access  (COMPUTE only)      │
    └──────────┬──────────────────┘
               │ queries
       ┌───────┴────────────────────────────┐
       │                                    │
       ▼                                    ▼
┌─────────────────────┐      ┌──────────────────────────┐
│  digital-arbor-400  │      │     private-internal      │
│  (STORAGE)          │      │     (STORAGE)             │
│  └── pg_public      │      │  ├── netsuite2            │
│      ├── accounts   │      │  ├── staging              │
│      ├── subscript. │      │  └── share_celigo ◄── Celigo reads views here
│      ├── acct_bill. │      └──────────────────────────┘
│      └── run_cache_ │
│          accounts   │
└─────────────────────┘
```

---

## The Fix: Explicit Storage Prefix

Without a project prefix, BigQuery assumes storage = compute project.
After migration, that assumption breaks for `pg_public` tables.

```sql
-- BROKEN after migration
SELECT * FROM pg_public.accounts

-- CORRECT
SELECT * FROM `digital-arbor-400`.`pg_public`.`accounts`
```

`private-internal` refs were already explicit → no changes needed.

---

## Files Updated

| File | References Fixed |
|---|---|
| `001_account_sync_v2.sql` | `subscriptions`, `accounts`, `account_billing_info`, `run_cache_accounts` |
| `002_subscription_sync_v2.sql` | `subscriptions`, `account_billing_info` ×2, `run_cache_accounts` |
| `run_cache_account_sync_v2.sql` | `subscriptions`, `run_cache_accounts`, `account_billing_info` |
| `monthly_run_cache_revenue_v2.sql` | Already compliant ✅ |
| `olp_and_overage_monthly_billing.sql` | Already compliant ✅ |

---

## Open Item

> Confirm with infra team: is `private-internal` the friendly name for `internal-analytics-data-access`?
> If yes, `share_celigo` RunCache views will be at `internal-analytics-data-access.share_celigo.*`
