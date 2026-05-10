-- Author  : Prabal Saha
-- Date    : 2026-03-13
-- Version : 2.00
-- Purpose : RunCache account sync — surfaces active RunCache subscriptions with billing
--           and Stripe customer data for downstream Celigo flows.
--           type = 'RUN_CACHE_2026' is the subscription SKU + pricing curve version
--           (intentional — revenue_records uses product family 'DBT_RUN_CACHE' instead).
--           When pricing curves change, this becomes RUN_CACHE_2027 etc.

with latest_run_cache_subscriptions as (
  select
    subs.*
  from `digital-arbor-400`.`pg_public`.`subscriptions` as subs
  inner join `digital-arbor-400`.`pg_public`.`run_cache_accounts`
    on subs.billing_account_id = run_cache_accounts.billing_info_id
    and not run_cache_accounts._fivetran_deleted
  where
    not subs._fivetran_deleted
    and subs.termination_date_utc is null
    and (
      date(subs.contract_end_date) >= current_date
      or subs.contract_end_date is null
    )
    and subs.type = 'RUN_CACHE_2026'
  qualify
    row_number() over (
      partition by run_cache_accounts.run_cache_org_id
      order by subs.version desc
    ) = 1
)

select
  ls.*,
  rca.run_cache_org_id,
  abi.id as billing_info_id,
  abi.stripe_customer_id,
  abi.legal_name,
  abi.billing_address,
  abi.tax_id
from latest_run_cache_subscriptions as ls
inner join `digital-arbor-400`.`pg_public`.`run_cache_accounts` as rca
  on ls.billing_account_id = rca.billing_info_id
  and not rca._fivetran_deleted
inner join `digital-arbor-400`.`pg_public`.`account_billing_info` as abi
  on rca.billing_info_id = abi.id
  and not abi._fivetran_deleted
where abi.stripe_customer_id is not null
  and (
    ls._fivetran_synced >= timestamp_sub(current_timestamp(), interval 28 hour)
    or abi._fivetran_synced >= timestamp_sub(current_timestamp(), interval 28 hour)
  )
qualify
  row_number() over (
    partition by ls.billing_account_id
    order by abi.stripe_customer_id desc nulls last
  ) = 1
