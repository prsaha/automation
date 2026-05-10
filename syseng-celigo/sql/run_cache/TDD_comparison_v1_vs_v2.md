# TDD Comparison: Original Text Spec vs Actual PDF TDD
**Feature:** RD-1160536 — Pricing for Dbt Run Cache
**Date:** 2026-03-11
**Author:** Prabal Saha

---

## Summary

The original text-based TDD shared for review contained several schema assumptions that **do not match** the authoritative PDF TDD. These differences materially affect the SQL queries and integration logic built for the system engineering implementation.

---

## Side-by-Side Differences

### 1. How RunCache Orgs Are Identified

| | Original Text TDD | Actual PDF TDD |
|---|---|---|
| Mechanism | `billing_account_type` ENUM on `account_billing_info` (`FIVETRAN` \| `RUN_CACHE`) | Dedicated `run_cache_accounts` table with FK → `account_billing_info` |
| Org ID field | `account_billing_info.external_account_id` | `run_cache_accounts.run_cache_org_id` |
| Filtering queries | `WHERE billing_account_type = 'RUN_CACHE'` | `INNER JOIN run_cache_accounts ON billing_info_id = account_billing_info.id` |
| **Impact** | All v1 SQL filters are invalid — column does not exist | Requires explicit join to `run_cache_accounts` in all queries |

---

### 2. New Table: `run_cache_accounts`

| | Original Text TDD | Actual PDF TDD |
|---|---|---|
| Table exists | No | **Yes** — introduced in Phase 1 |
| Schema | — | `run_cache_org_id TEXT (PK)`, `billing_info_id TEXT (FK → account_billing_info)` |
| Purpose | — | Junction between Tobico org and Fivetran billing profile |
| **Impact** | Not joined in any v1 SQL | Must be joined in `run_cache_account_sync`, `monthly_run_cache_revenue`, and `001_account_sync` guard |

---

### 3. `account_billing_info.id` Prefix Convention

| | Original Text TDD | Actual PDF TDD |
|---|---|---|
| Prefix for external accounts | `external_{generated_id}` | `run_cache_{generated_id}` |
| **Impact** | External ID prefix assumptions in comments/docs are wrong | Update all documentation and any string-matching logic |

---

### 4. Phase 2 — Column Renames (PDF only, not in original text TDD)

The PDF TDD describes a Phase 2 that renames `billing_account_id` → `billing_info_id` across the entire platform. This is **absent** from the original text TDD.

| Table | Original column | Phase 2 renamed column |
|---|---|---|
| `revenue_records` | `billing_account_id` | `billing_info_id` |
| `subscriptions` | `billing_account_id` | `billing_info_id` |
| `daily_credit_usages` | `billing_account_id` | `billing_info_id` |
| `account_history` | `billing_account_id` | `billing_info_id` |
| `billing_invoices` | `billing_account_id` | `billing_info_id` |
| `billing_payments` | `billing_account_id` | `billing_entity_id` |
| `subscription_history` | `billing_account_id` | `billing_entity_id` |
| `accounts` | `billing_account_id` | `billing_info_id` (renamed) |

**Impact:** All v1 and v2 SQL join keys (`billing_account_id`) will break when Phase 2 is deployed.

---

### 5. Phase 2 — Table Renames and New Tables (PDF only)

| | Original Text TDD | Actual PDF TDD |
|---|---|---|
| `account_billing_info` renamed | No | **Yes** → renamed to `billing_info` in Phase 2 |
| New junction table | No | **Yes** → `billing_info_management` (`billing_info_id PK/FK`, `account_id FK → accounts`) |
| `account_billing_info.account_id` | Retained | **Removed** in Phase 2 (migrated to `billing_info_management`) |
| **Impact** | All queries referencing `account_billing_info` by name need update in Phase 2 | Plan for table alias changes in all SQL files |

---

### 6. Architecture Flow Diagram

| | Original Text TDD | Actual PDF TDD |
|---|---|---|
| Diagram present | No | **Yes** — explicit flow diagram on page 3 |
| Flow | Described in prose only | `RunCache → Stripe` / `RunCache Prod DB → BigQuery → BigQueryToAppRunCacheSync → FillRunCacheRevenue → Fivetran Prod DB → BigQuery → NetSuite` |
| Stripe metadata update timing | Mentioned | **Explicit:** must happen as close to BigQuery sync task start as possible (fail-fast on Stripe API unavailable) |

---

### 7. `billing_account_type` ENUM

| | Original Text TDD | Actual PDF TDD |
|---|---|---|
| Column exists on `account_billing_info` | Yes — `ENUM(fivetran \| run_cache)` | **No** — not present in any Phase 1 or Phase 2 schema |
| Used as RunCache filter | Yes | **No** — `run_cache_accounts` table serves this purpose |
| **Impact** | All v1 SQL filters invalid | Replaced with `NOT EXISTS / INNER JOIN run_cache_accounts` in v2 SQL |

---

## SQL Files Affected

| File | v1 Issue | v2 Fix Applied |
|---|---|---|
| `monthly_run_cache_revenue.sql` | `billing_account_type` filter + `external_account_id` — both invalid | `monthly_run_cache_revenue_v2.sql` — joins `run_cache_accounts` |
| `run_cache_account_sync.sql` | `billing_account_type` filter — invalid | `run_cache_account_sync_v2.sql` — `run_cache_accounts` as entry point |
| `001_account_sync.sql` | `billing_account_type` guard — invalid | `001_account_sync_v2.sql` — `NOT EXISTS (run_cache_accounts)` guard |

---

## What Stays the Same

| Area | Status |
|---|---|
| Source table: `stg_pg_public_revenue_records` | Unchanged |
| NetSuite joins: `netsuite2.customer`, `netsuite2.item` | Unchanged |
| SKU name: `RunCache_2026` | Unchanged |
| External ID prefix: `RCINV` / `RCCM` | Unchanged |
| Payment term: `Autopay` | Unchanged |
| `revenue_type = SELF_SERVICE`, `product_type = RUN_CACHE` | Unchanged |
| 28-hour incremental sync window | Unchanged |
| Finance separation from Fivetran OLP | Unchanged — mechanism updated but goal same |

---

## Open Items for Phase 2 Readiness

| # | Item |
|---|---|
| 1 | All SQL files use `billing_account_id` — must be renamed to `billing_info_id` when Phase 2 deploys |
| 2 | All SQL files reference `account_billing_info` — must be updated to `billing_info` when Phase 2 deploys |
| 3 | `billing_info_management` junction table needs to be accounted for in any query that currently joins `account_billing_info ON account_id` |
| 4 | Confirm `run_cache_accounts` BigQuery sync cadence with engineering — 28-hour window assumes it is Fivetran-synced |
