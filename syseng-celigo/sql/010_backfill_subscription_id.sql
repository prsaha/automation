with product_mapping as (
  select * from unnest([
    struct('Starter_2022' as product_code, '17804' as netsuite_id),
    struct('Standard_2022', '17807'),
    struct('BCF_2022', '17806'),
    struct('Enterprise_2022', '17805'),
    struct('HVR-PS-Hours-T&M Billing', '17803'),
    struct('HVR-ProServe-Training', '17802'),
    struct('HVR-Gold-Support', '17799'),
    struct('HVR-61', '17801'),
    struct('HVR-57', '17797'),
    struct('3100', '17817'),
    struct('1000', '17818'),
    struct('CLDW', '17825'),
    struct('US Only Support', '17865'),
    struct('RSA-Fivetran-Fundamentals', '17856'),
    struct('Services', '17844'),
    struct('Custom-Services', '17845'),
    struct('HVR5.7_Exatended_Support', '17860'),
    struct('HVR_Perpetual_License_Extended_Support', '17862'),
    struct('HVR_Perpetual_License_Extended_Support_Only', '17863'),
    struct('HVR5.7_Extended_Support_Only', '17861'),
    struct('ELA-Cloud-Only', '17902'),
    struct('ELA-On-Prem-Only', '17904'),
    struct('ELA-Cloud-Plus-On-Prem', '17903'),
    struct('Standard_2024', '17923'),
    struct('Enterprise_2024', '17924'),
    struct('BCF_2024', '17925'),
    struct('Premium_Support', '17905'),
    struct('Census-X-Sell-Enterprise', '17933'),
    struct('Census-X-Sell-Pro', '17932')
  ])
),
staging_subscriptions as (
  select *
  from `digital-arbor-400.pg_public.subscriptions`
  where not _fivetran_deleted
    and not is_evergreen
    and created_at >= timestamp_sub(current_timestamp(), interval 1095 day)
    and salesforce_id is not null
    and order_number is not null
  qualify row_number() over (partition by salesforce_id order by version desc) = 1
)

select
  ss.order_number,
  count(distinct ss.id) as subscription_count,
  string_agg(distinct cast(ss.id as string), ', ') as subscription_ids,
  string_agg(distinct ss.billing_account_id, ', ') as billing_account_ids,
  string_agg(distinct ss.product_code, ', ') as item_code,
  string_agg(distinct pm.netsuite_id, ', ') as netsuite_item_ids
from staging_subscriptions ss
left join product_mapping pm
  on ss.product_code = pm.product_code
where coalesce(ss.product_code, '') not like 'Free%'
--and ss.order_number ='00081570'
group by ss.order_number
having count(distinct ss.id) >= 1
order by subscription_count desc