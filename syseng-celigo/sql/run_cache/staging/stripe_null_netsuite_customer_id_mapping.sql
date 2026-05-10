with stripe_extract as (
  /* Step 1: Extract Stripe data. 
     We look for the new RunCache anchor first, then fallback to legacy.
  */
  select
    id as stripe_id,
    json_value(metadata, '$.netsuite_customer_id') as stripe_netsuite_customer_id,
    coalesce(
      json_value(metadata, '$.billing_profile_id'), -- New RunCache 
      json_value(metadata, '$.fivetran_account_id')  -- Legacy Fivetran Anchor
    ) as billing_anchor_id,
    created as stripe_created_date
  from `private-internal`.`stripe`.`customer`
  where not is_deleted
), 
unified_internal_bridge as (
  /* Step 2: Create a unified map of Billing IDs to Stripe IDs.
     We pull from both the legacy Product DB and the new Billing Hub.
  */
  -- Path A: Legacy Fivetran Accounts
  select 
    billing_account_id as ns_lookup_key, 
    stripe_customer_id,
    'FIVETRAN' as product_line
  from `digital-arbor-400`.`pg_public`.`accounts`
  where not _fivetran_deleted

  union all

  -- Path B: New RunCache Hub (Currently in Staging Project)
  select 
    abi.id as ns_lookup_key, -- The 'word_word' identifier
    abi.stripe_customer_id,
    'RUN_CACHE' as product_line
  from `digital-arbor-400`.`pg_public`.`account_billing_info` abi
  inner join digital-arbor-400.pg_public.run_cache_accounts rca
    on abi.id = rca.billing_info_id
  where not abi._fivetran_deleted and not rca._fivetran_deleted
),
billing_extract as (
  /* Step 3: Join the internal bridge to NetSuite.
     The join is performed on 'ns_lookup_key' which handles both GUIDs and word_word strings.
  */
  select
    ub.stripe_customer_id,
    ub.product_line,
    ub.ns_lookup_key,
    safe_cast(ns.id as string) as netsuite_customer_id
  from unified_internal_bridge ub
  left join `private-internal`.`netsuite2`.`customer` ns 
    on ub.ns_lookup_key = ns.custentity_ft_account_id_sf
  where not ns._fivetran_deleted
)
/* Step 4: Final selection for Celigo.
   Only returns records where Stripe is missing the NetSuite ID, but we have found it in NetSuite.
*/
select
  be.stripe_customer_id as id,
  be.netsuite_customer_id,
  concat(
    'https://5260239.app.netsuite.com/app/common/entity/entity.nl?id=',
    be.netsuite_customer_id
  ) as netsuite_customer_link,
  be.product_line as debug_product_source,
  be.ns_lookup_key as debug_billing_id
from billing_extract be
inner join stripe_extract se on be.stripe_customer_id = se.stripe_id
where se.stripe_netsuite_customer_id is null 
  and be.netsuite_customer_id is not null