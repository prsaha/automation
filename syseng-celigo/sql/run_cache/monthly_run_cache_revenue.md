# monthly_run_cache_revenue — One Pager
**TDD:** RD-1160536 · Pricing for Run Cache
**Author:** Prabal Saha
**Query:** `sql/monthly_run_cache_revenue.sql`

---

## Purpose

Produces one invoice-ready row per RunCache organization per month for NetSuite invoicing. Reads RunCache revenue records (populated upstream by the `FillRunCacheRevenue` Java task) and enriches them with billing, customer, and SKU information.

---

## Table Architecture

```
┌─────────────────────────────────────────────────────┐
│         Tobico (upstream, out of scope here)         │
│  metrics_daily_agg → FillRunCacheRevenue Java task   │
│         ↓ writes revenue_records (product_type=RUN_CACHE)
└─────────────────────────────────────────────────────┘
                         │
                         ▼
┌──────────────────────────────────────────────────────────────────┐
│  private-internal.staging.stg_pg_public_revenue_records          │
│  Role: Source of truth for RunCache revenue amounts              │
│  Key columns: billing_account_id, revenue_date_utc,              │
│               credits_used, amount, product_type, type, status   │
│  Filter: product_type = 'RUN_CACHE'                              │
└──────────────────────────────────────────────────────────────────┘
                         │
                         ▼
┌──────────────────────────────────────────────────────────────────┐
│  digital-arbor-400.pg_public.account_billing_info                │
│  Role: Links revenue records to RunCache billing accounts        │
│  Join: billing_account_id = account_billing_info.id              │
│  Filter: billing_account_type = 'RUN_CACHE'                      │
│  Provides: stripe_customer_id, org_id (external_account_id)      │
└──────────────────────────────────────────────────────────────────┘
                         │
                         ▼
┌──────────────────────────────────────────────────────────────────┐
│  private-internal.netsuite2.customer                             │
│  Role: Enriches with NetSuite customer details for invoicing     │
│  Join: billing_account_id = customer.custentity_ft_account_id_sf │
│  Provides: netsuite_customer_id, company name, invoice email(s)  │
└──────────────────────────────────────────────────────────────────┘
                         │
                         ▼
┌──────────────────────────────────────────────────────────────────┐
│  private-internal.netsuite2.item                                 │
│  Role: Resolves the RunCache SKU for the invoice line item       │
│  Join: item.name = 'RunCache_2026'                               │
│  Provides: item_id                                               │
└──────────────────────────────────────────────────────────────────┘
                         │
                         ▼
┌──────────────────────────────────────────────────────────────────┐
│  OUTPUT: monthly_run_cache_revenue                               │
│  One row per RunCache org per month, ready for NetSuite          │
└──────────────────────────────────────────────────────────────────┘
```

---

## Business Logic

| Step | Rule |
|---|---|
| **Billing period** | Revenue records are grouped by `billing_account_id` and truncated to month start. Month end is derived as the last calendar day of that month. |
| **Product filter** | Only records with `product_type = 'RUN_CACHE'` are included. This isolates RunCache from Fivetran OLP revenue at the source. |
| **Quantity** | Monthly sum of `credits_used` (cache hits). Falls back to `revenue_amount` if `credits_used` is null. |
| **Amount** | Monthly sum of `revenue_amount`, rounded to 2 decimal places. Pricing curve is applied upstream by `FillRunCacheRevenue` before writing to `revenue_records`. |
| **Transaction type** | `amount ≥ 1` → Invoice · `amount < 0` → Credit Memo · otherwise → None |
| **Payment term** | Always `Autopay`. RunCache customers are self-service CBP (consumption-based pricing), billed monthly with no reseller/partner involvement. |
| **NetSuite amounts** | `netsuite_quantity` and `netsuite_amount` are always positive (`abs()`). Sign is captured in `transaction_type`. |
| **External ID** | Unique deduplication key for NetSuite: `RCINV{netsuite_customer_id}{YYYYMM}` for invoices, `RCCM{netsuite_customer_id}{YYYYMM}` for credit memos. `RC` prefix separates RunCache from Fivetran (`CBPINV` / `CBPCM`). |
| **Invoice email** | If primary email = billing email → use one. If different → concatenate both with `,`. |

---

## Key Architectural Decisions

| Decision | Rationale |
|---|---|
| Source from `stg_pg_public_revenue_records` not `metrics_daily_agg` | Pricing curve is applied by the Java task. This query only needs the pre-calculated revenue amounts. |
| Join `account_billing_info` not `accounts` | Per TDD, `accounts.stripe_customer_id` will be dropped post-migration. `account_billing_info` is the new central billing table. |
| No `salesforce.fivetran_account_c` join | RunCache orgs are external accounts (`external_` prefix IDs). They have no entries in the Fivetran→Salesforce mapping table. |
| No `netsuite2.partner` join | RunCache has no reseller/third-party payer model. All accounts are direct self-service. |
| `billing_account_type = 'RUN_CACHE'` guard on both joins | Ensures no Fivetran OLP accounts bleed into RunCache revenue, and vice versa. |

---

## Output Fields

| Field | Source | Description |
|---|---|---|
| `external_id` | Derived | NetSuite dedup key — `RCINV` or `RCCM` + customer + YYYYMM |
| `revenue_month_start` | revenue_records | First day of billing month |
| `revenue_month_end` | Derived | Last day of billing month |
| `billing_account_id` | revenue_records | Internal RunCache billing account ID |
| `org_id` | account_billing_info | Tobico RunCache organization ID |
| `stripe_customer_id` | account_billing_info | Stripe customer ID for payment |
| `netsuite_customer_id` | netsuite2.customer | NetSuite customer record ID |
| `netsuite_customer_name` | netsuite2.customer | Company name in NetSuite |
| `to_be_emailed` | netsuite2.customer | Invoice recipient email(s) |
| `item_id` | netsuite2.item | NetSuite item ID for RunCache_2026 SKU |
| `product_type` | revenue_records | Always `RUN_CACHE` |
| `revenue_type` | revenue_records | Always `SELF_SERVICE` |
| `status` | revenue_records | Revenue record status |
| `quantity` | revenue_records | Monthly billable cache hits |
| `amount` | revenue_records | Dollar value (signed) |
| `netsuite_quantity` | Derived | `abs(quantity)` — always positive |
| `netsuite_amount` | Derived | `abs(amount)` — always positive |
| `rate` | Derived | Unit price = amount ÷ quantity |
| `payment_term` | Hardcoded | Always `Autopay` |
| `transaction_type` | Derived | `Invoice` / `Credit Memo` / `None` |
| `line_number` | Derived | Line sequence within the invoice |
