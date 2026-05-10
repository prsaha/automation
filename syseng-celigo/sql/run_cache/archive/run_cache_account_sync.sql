-- Author  : Prabal Saha
-- Date    : 2026-03-10
-- Version : 1.00
-- Purpose : Syncs active RunCache organizations and their billing/subscription details.
--           Adapted from 001_account_sync.sql for RunCache external accounts.
--           Per TDD RD-1160536: RunCache orgs are external accounts — they have no
--           Fivetran platform account, no reseller/partner model, and are identified
--           via account_billing_info (billing_account_type = 'RUN_CACHE').
--
-- TODO: Confirm subscription type name for RunCache_2026 with engineering team
-- TODO: Confirm what "active" means for RunCache orgs (no account status field)
-- TODO: Confirm partition key for QUALIFY — org_id or billing_account_id?

with latest_run_cache_subscriptions as (
  select
    s.*
  from pg_public.subscriptions as s
  where
    s._fivetran_deleted = false
    and s.termination_date_utc is null
    and (
      date(s.contract_end_date) >= current_date
      or s.contract_end_date is null
    )
    -- RunCache uses a single SKU — no free tiers or reseller types to exclude
    and s.type = 'RunCache_2026'
  qualify
    row_number() over (
      -- TODO: no salesforce_id for RunCache orgs — partitioning by billing_account_id instead
      partition by s.billing_account_id
      order by s.version desc
    ) = 1
)

select
  ls.*,
  acct_info.*
from latest_run_cache_subscriptions as ls
inner join pg_public.account_billing_info as acct_info
  -- RunCache: billing_account_id on the subscription maps to account_billing_info.id
  -- (not account_billing_info.account_id, which is NULL for external accounts)
  on ls.billing_account_id = acct_info.id
  and acct_info.billing_account_type = 'RUN_CACHE'
where
  -- incremental sync: only pick up records changed in the last 28 hours
  (
    ls._fivetran_synced  >= timestamp_sub(current_timestamp(), interval 28 hour)
    or acct_info._fivetran_synced >= timestamp_sub(current_timestamp(), interval 28 hour)
  )

/*
  ============================================================
  DIAGNOSIS: KEY DIFFERENCES FROM 001_account_sync.sql
  ============================================================

  1. NO pg_public.accounts JOIN
     ─────────────────────────
     Original joins pg_public.accounts to get: status, platform_tier,
     salesforce_id, stripe_customer_id, freeze_reason.
     RunCache orgs are EXTERNAL accounts — account_billing_info.account_id
     is NULL for them, so there is no corresponding row in pg_public.accounts.
     All account-level data must come from account_billing_info instead.

  2. NO STATUS FILTER
     ─────────────────
     Original filters: acct.status IN ('Customer', 'Frozen', 'Partner')
     status lives on pg_public.accounts — unavailable for RunCache.
     OPEN QUESTION: What signals an "active" RunCache org?
     Candidates:
       a) acct_info.stripe_customer_id IS NOT NULL
          → org is fully provisioned (Stripe customer updated per TDD)
       b) termination_date_utc IS NULL on subscription
          → already covered in the WHERE clause above
       Recommendation: use (a) + (b) together until a dedicated
       status model is introduced for RunCache orgs.

  3. NO RESELLER / PAYER LOGIC
     ──────────────────────────
     Original computes payer_account_id to handle RESELLER, MARKETPLACE,
     and RESELLER_MARKETPLACE payer types.
     RunCache has no partner/reseller model per TDD — all orgs are direct
     self-service CBP customers. payer_account_id is dropped entirely.

  4. NO SALESFORCE_ID PARTITION
     ───────────────────────────
     Original deduplicates via PARTITION BY salesforce_id.
     RunCache orgs have no Salesforce account — partitioning by
     billing_account_id instead. Confirm with engineering if org_id
     (external_account_id from account_billing_info) is a better key.

  5. NO PLATFORM TIER / FREE TIER FILTERS
     ────────────────────────────────────
     Original excludes Free_2024, Free_2022 platform tiers and
     FREE_2022, FREE_2024, FREE_2026 subscription types.
     RunCache uses a single SKU (RunCache_2026) — no free tier variants
     exist yet. Filter replaced with: s.type = 'RunCache_2026'.

  ============================================================
*/
