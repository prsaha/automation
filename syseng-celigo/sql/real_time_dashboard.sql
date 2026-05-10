{{
  config(
    schema='share_celigo',
    cron='15 * * * *',
    materialized='view'
  )
}}


with olp_overage_revenue as (
  select
    revenue_records.billing_account_id,
    revenue_records.salesforce_account_id as sfdc_account_id, -- TODO this is just for QA purposes only
    accounts.stripe_customer_id,
    date(
      date_trunc(revenue_records.revenue_date_utc, month)
    ) as revenue_month_start,
    revenue_records.account_tier,
    revenue_records.type as revenue_type,
    revenue_records.status,
    sum(revenue_records.credits_used) as credits_used,
    sum(revenue_records.amount) as revenue_amount
  from {{ ref('stg_pg_public_revenue_records') }} as revenue_records
  inner join {{source('pg_public', 'accounts')}} on revenue_records.billing_account_id = accounts.id
  where (
    upper(revenue_records.type) like '%OVERAGE%'
    or upper(revenue_records.type) like '%SELF%'
  )
  group by 1, 2, 3, 4, 5, 6, 7
), revenue_table_with_netsuite_id as (
  select
    olp_overage_revenue.*,
    partner.custentity_sfdc_third_party_payer as sfdc_third_party_payer,
    partner.id as partner_id,
    customer.companyname as netsuite_customer_name,
    safe_cast(customer.id as string) as netsuite_customer_id,
    if(
      upper(olp_overage_revenue.revenue_type) like '%OVERAGE%', 2, 3
    ) as usage_revenue_type_id,
    last_day(
      olp_overage_revenue.revenue_month_start, month
    ) as revenue_month_end,
    if(
      customer.email = customer.custentitycustentity_email,
      customer.email,
      coalesce(
        concat(customer.email, ',', customer.custentitycustentity_email),
        customer.email,
        customer.custentitycustentity_email
      )
    ) as to_be_emailed
  from olp_overage_revenue
  left join {{source('netsuite2', 'customer')}} on olp_overage_revenue.billing_account_id = customer.custentity_ft_account_id_sf
    and not customer._fivetran_deleted
  left join {{source('netsuite2', 'partner')}} on customer.partner = partner.id
    and not partner._fivetran_deleted
), revenue_table_final as (
  select
    revenue_month_start,
    revenue_month_end,
    netsuite_customer_id,
    billing_account_id,
    sfdc_account_id,
    stripe_customer_id,
    netsuite_customer_name,
    partner_id is not null
    and revenue_type not like '%OVERAGE%' as is_third_party_payer,
    sfdc_third_party_payer,
    case
      when revenue_type like '%OVERAGE%' then null else partner_id
    end as partner_id,
    account_tier,
    revenue_type,
    item.id as item_id,
    status,
    coalesce(credits_used, round(revenue_amount, 2)) as quantity,
    round(revenue_amount, 2) as amount,
    to_be_emailed
  from revenue_table_with_netsuite_id
  left join {{source('netsuite2', 'item')}} on revenue_table_with_netsuite_id.account_tier = item.custitem_account_tier
    and revenue_table_with_netsuite_id.usage_revenue_type_id = item.custitem1
), add_transformation as (
  select
    revenue_table_final.*,
    is_third_party_payer as tax_override,
    if(quantity >= 0, quantity, abs(quantity)) netsuite_quantity,
    if(amount >= 0, amount, abs(amount)) netsuite_amount,
    safe_divide(amount, quantity) as rate,
    case
      when revenue_type = 'SELF_SERVICE' and not is_third_party_payer
      then 'Autopay'
      else 'Net 30'
    end as payment_term,
    case
      when amount >= 1
      then 'Invoice'
      when amount < 0
      then 'Credit Memo'
      else 'None'
    end as transaction_type
  from revenue_table_final
), add_external_id as (
  select
    case
      when transaction_type = 'Credit Memo'
      then
        concat(
          'CBPCM',
          netsuite_customer_id,
          cast(revenue_month_end as string format 'YYYYMM')
        )
      else
        concat(
          'CBPINV',
          netsuite_customer_id,
          cast(revenue_month_end as string format 'YYYYMM')
        )
    end as external_id,
    add_transformation.*
  from add_transformation
)
select
  add_external_id.*,
  row_number() over (partition by external_id, transaction_type) as line_number
from add_external_id
order by revenue_month_start desc, netsuite_customer_id


{% if var('dry_run') %}
  limit 0 
{% endif %}