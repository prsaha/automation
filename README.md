# automation

Monorepo for Fivetran's Systems Engineering automation tooling — Celigo integration code, BigQuery SQL, dbt models, JavaScript transformers, and Google Cloud infrastructure for the billing pipeline from BigQuery → Celigo → NetSuite.

---

## Repositories

| Directory | Language | Purpose |
|---|---|---|
| [`syseng-celigo/`](./syseng-celigo/) | SQL · JavaScript · TypeScript | BigQuery queries, dbt models, and Celigo JS transformers for Fivetran OLP and RunCache billing |
| [`celigo-netsuite-gcs-worker/`](./celigo-netsuite-gcs-worker/) | Python | Google Cloud Function that downloads NetSuite invoice PDFs and archives them to GCS |

---

## Architecture Overview

```
BigQuery (pg_public / staging / netsuite2 / stripe)
    │
    ▼
dbt models  ──────────────────────────────────────────────────────────┐
(private-internal.share_celigo.*)                                     │
    │                                                                  │
    ▼                                                                  │
Celigo Integration Platform                                            │
  ├── BQ Extract (SQL queries)                                         │
  ├── JS Pre-map hook  (preMapHookSubNsSync.js)                        │
  ├── JS Pre-save page (preSavePageTransformer*.js / *.ts)             │
  └── NetSuite Write                                                   │
          │                                                            │
          ▼                                                            │
     NetSuite (Sales Orders / Invoices / Credit Memos)                │
          │                                                            │
          └── Invoice PDFs ──▶ celigo-netsuite-gcs-worker ────────────┘
                                (Cloud Function → GCS bucket)
```

**Two billing pipelines run through this stack:**

| Pipeline | BQ Source | SKU | NS External ID |
|---|---|---|---|
| Fivetran OLP | `pg_public.subscriptions` | SELF_SERVICE / OVERAGE | `CBPINV` / `CBPCM` |
| RunCache | `stg_pg_public_revenue_records` (type=`DBT_RUN_CACHE`) | `RUN_CACHE_2026` | `RCINV` / `RCCM` |

---

## Quick Links

- [syseng-celigo README](./syseng-celigo/README.md) — SQL, dbt, and JS transformer docs
- [celigo-netsuite-gcs-worker README](./celigo-netsuite-gcs-worker/README.md) — Cloud Function docs
- [RunCache Deployment Guide](./syseng-celigo/sql/run_cache/RunCache_Integration_Deployment_Document.md)
- [RunCache TDD](./syseng-celigo/sql/run_cache/RD-1160536_run_cache_billing_revenue_tdd.md)
- [dbt Deployment Guide](./syseng-celigo/dbt/run_cache/DEPLOYMENT.md)

---

## Key Jira Epics

| Epic | Title |
|---|---|
| RD-1160536 | Pricing for Run Cache (parent) |
| RD-1161737 | RunCache Billing & Revenue Integration |
| RD-1010532 | ELA HVR Intra-Allocations |
| RD-899810 | Pricing Model Subscription date mapping |
| RD-1029971 | Census legacy product mapping |
| RD-1060067 | RR dates from Service min/max |
| RD-927162 | Auto-set Billing Schedules |

---

## License

Internal — Fivetran Systems Engineering
