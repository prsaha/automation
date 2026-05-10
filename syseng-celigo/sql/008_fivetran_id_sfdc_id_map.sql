with staging_subscriptions as (
  select
    *
  from pg_public.subscriptions
  where not _fivetran_deleted
  qualify row_number() over (partition by salesforce_id order by version desc) = 1 -- latest_version_only
)

select
  salesforce_account_id,
  string_agg(distinct billing_account_id, ', ') as billing_account_ids,
  count(distinct billing_account_id) as count_billing_accounts
from staging_subscriptions
where coalesce(product_code, '') not like 'Free%'
group by 1
order by 3 desc