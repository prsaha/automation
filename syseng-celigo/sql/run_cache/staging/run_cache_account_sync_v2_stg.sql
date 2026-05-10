-- Author  : Prabal Saha
-- Date    : 2026-03-13
-- Version : 2.00-STG
-- Purpose : STAGING version of run_cache_account_sync_v2.sql
--           Compute: dulcet-yew-246109
--           Storage: dulcet-yew-246109.staging_billing_public
--           Do NOT deploy this file to production.
--           NOTE: stripe_customer_id filter removed — all NULL in staging
--           NOTE: 28hr recency filter removed for staging testing
--           NOTE: QUALIFY added to deduplicate account_billing_info fanout
--           NOTE: type = 'RUN_CACHE_2026' is the subscription SKU + pricing curve version
--                 (intentional — revenue_records uses product family 'DBT_RUN_CACHE' instead)
--                 When pricing curves change, this becomes RUN_CACHE_2027 etc.
--           TODO: restore where clause filters in production

with latest_run_cache_subscriptions as (
  select
    subs.*
  from `dulcet-yew-246109`.`staging_billing_public`.`subscriptions` as subs
  inner join `dulcet-yew-246109`.`staging_billing_public`.`run_cache_accounts`
    on subs.billing_account_id = run_cache_accounts.billing_info_id
    and not run_cache_accounts._fivetran_deleted
  where
    subs._fivetran_deleted = false
    and subs.termination_date_utc is null
    and (
      date(subs.contract_end_date) >= current_date
      or subs.contract_end_date is null
    )
   -- and subs.type = 'RUN_CACHE_2026'                                  -- ← confirmed 2026-03-18
  qualify
    row_number() over (
      partition by run_cache_accounts.run_cache_org_id
      order by subs.version desc
    ) = 1
)

select
  ls.*,
  rca.run_cache_org_id,
  abi.id                  as billing_info_id,
  abi.stripe_customer_id,
  abi.legal_name,
  abi.billing_address,
  abi.tax_id
from latest_run_cache_subscriptions as ls
inner join `dulcet-yew-246109`.`staging_billing_public`.`run_cache_accounts` as rca
  on ls.billing_account_id = rca.billing_info_id
  and not rca._fivetran_deleted
inner join `dulcet-yew-246109`.`staging_billing_public`.`account_billing_info` as abi
  on rca.billing_info_id = abi.id
  and not abi._fivetran_deleted
-- TODO: restore in production:
-- where abi.stripe_customer_id is not null
--   and (
--     ls._fivetran_synced  >= timestamp_sub(current_timestamp(), interval 28 hour)
--     or abi._fivetran_synced >= timestamp_sub(current_timestamp(), interval 28 hour)
--   )
qualify
  row_number() over (
    partition by ls.billing_account_id
    order by abi.stripe_customer_id desc nulls last                -- ← prefer row with stripe_customer_id
  ) = 1