{{
  config(
    materialized = 'view',
    project      = 'private-internal',
    alias        = 'syseng_stripe_null_netsuite_customer_id_mapping'
  )
}}

-- Author  : Prabal Saha
-- Date    : 2026-04-16
-- Version : 1.00
-- Purpose : Identifies Stripe customers missing netsuite_customer_id in metadata
--           where a matching NetSuite customer exists via the internal billing bridge.
--           Covers both legacy Fivetran accounts (Path A) and new RunCache hub (Path B).
--           Output is consumed by Celigo to backfill netsuite_customer_id in Stripe metadata.
-- Step 1: Active Stripe customers with metadata extracted.
--         New RunCache anchor (billing_profile_id) takes precedence over legacy (fivetran_account_id).
with stripe_customers as (
  select
    stripe_customer.id as stripe_customer_id,
    json_value(stripe_customer.metadata, '$.netsuite_customer_id') as stripe_netsuite_customer_id,
    coalesce(
      json_value(stripe_customer.metadata, '$.billing_profile_id'), -- New RunCache anchor
      json_value(stripe_customer.metadata, '$.fivetran_account_id')  -- Legacy Fivetran anchor
    ) as billing_anchor_id,
    stripe_customer.created as stripe_created_at
  from {{ source('stripe', 'customer') }} stripe_customer
  where not stripe_customer.is_deleted
),
-- Step 2: Active NetSuite customers, pre-filtered before joining.
netsuite_customers as (
  select
    safe_cast(netsuite_customer.id as string) as netsuite_customer_id,
    netsuite_customer.custentity_ft_account_id_sf as billing_account_id
  from {{ source('netsuite2', 'customer') }} netsuite_customer
  where not netsuite_customer._fivetran_deleted
),
-- Step 3: Unified map of billing account IDs to Stripe customer IDs, by product line.
--         Path A — legacy Fivetran accounts.
--         Path B — new RunCache hub.
billing_ids_by_product_line as (
  select
    fivetran_account.billing_account_id as billing_account_id,
    fivetran_account.stripe_customer_id,
    'FIVETRAN' as product_line
  from {{ source('pg_public', 'accounts') }} fivetran_account
  where not fivetran_account._fivetran_deleted
  union all
  select
    billing_info.id as billing_account_id,
    billing_info.stripe_customer_id,
    'RUN_CACHE' as product_line
  from {{ source('pg_public', 'account_billing_info') }} billing_info
  inner join {{ source('pg_public', 'run_cache_accounts') }} run_cache_account
    on billing_info.id = run_cache_account.billing_info_id
  where not billing_info._fivetran_deleted
    and not run_cache_account._fivetran_deleted
  qualify row_number() over (
    partition by billing_info.id
    order by billing_info.stripe_customer_id desc nulls last
  ) = 1
),
-- Step 4: Join billing bridge to NetSuite to resolve netsuite_customer_id per Stripe customer.
--         QUALIFY deduplicates NS fanout (multiple customer rows per billing_account_id).
netsuite_id_by_stripe_customer as (
  select
    billing_id.stripe_customer_id,
    billing_id.product_line,
    billing_id.billing_account_id,
    netsuite_customer.netsuite_customer_id
  from billing_ids_by_product_line billing_id
  left join netsuite_customers netsuite_customer
    on billing_id.billing_account_id = netsuite_customer.billing_account_id
  qualify row_number() over (
    partition by billing_id.stripe_customer_id
    order by netsuite_customer.netsuite_customer_id
  ) = 1
)
-- Step 5: Final output for Celigo.
--         Only rows where Stripe is missing netsuite_customer_id but NS has it.
select
  netsuite_id_by_stripe.stripe_customer_id as id,
  netsuite_id_by_stripe.netsuite_customer_id,
  concat(
    'https://5260239.app.netsuite.com/app/common/entity/entity.nl?id=',
    netsuite_id_by_stripe.netsuite_customer_id
  ) as netsuite_customer_link,
  netsuite_id_by_stripe.product_line as product_source,
  netsuite_id_by_stripe.billing_account_id as acct_billing_id
from netsuite_id_by_stripe_customer netsuite_id_by_stripe
inner join stripe_customers
  on netsuite_id_by_stripe.stripe_customer_id = stripe_customers.stripe_customer_id
where stripe_customers.stripe_netsuite_customer_id is null
  and netsuite_id_by_stripe.netsuite_customer_id is not null
