-- Author   : Prabal Saha 
-- Date     : 2024-06-17
-- version  : 1.00
-- Purpose  : This query calculates the monthly revenue for RunCache product for NetSuite invoicing. It sources data from the stg_pg_public_revenue_records table, filters for RunCache product type, and joins with account billing info to get Stripe customer ID and org ID. It then enriches the data with NetSuite customer information and item details to prepare a final revenue table with necessary transformations for invoicing or credit memo generation in NetSuite.
-- Per TDD RD-1160536: Pricing for Run Cache product will be based on credits used, and the revenue records are populated in stg_pg_public_revenue_records by the FillRunCacheRevenue task. This query focuses on extracting that data, enriching it with billing and customer information, and preparing it for NetSuite invoicing.


with run_cache_revenue as (
  select
    revenue_records.billing_account_id,
    date(
      date_trunc(revenue_records.revenue_date_utc, month)
    ) as revenue_month_start,
    revenue_records.type as revenue_type,
    revenue_records.product_type,
    revenue_records.status,
    sum(revenue_records.credits_used) as credits_used,
    sum(revenue_records.amount) as revenue_amount
  from `private-internal`.`staging`.`stg_pg_public_revenue_records` as revenue_records
  inner join `digital-arbor-400`.`pg_public`.`account_billing_info`
    on revenue_records.billing_account_id = account_billing_info.id
    and account_billing_info.billing_account_type = 'RUN_CACHE'
  where revenue_records.product_type = 'RUN_CACHE'
  group by 1, 2, 3, 4, 5
), revenue_with_billing as (
  select
    run_cache_revenue.*,
    account_billing_info.stripe_customer_id,
    account_billing_info.external_account_id as org_id
  from run_cache_revenue
  inner join `digital-arbor-400`.`pg_public`.`account_billing_info`
    on run_cache_revenue.billing_account_id = account_billing_info.id
    and account_billing_info.billing_account_type = 'RUN_CACHE'
), revenue_with_netsuite as (
  select
    revenue_with_billing.*,
    customer.companyname as netsuite_customer_name,
    safe_cast(customer.id as string) as netsuite_customer_id,
    last_day(
      revenue_with_billing.revenue_month_start, month
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
  from revenue_with_billing
  left join `private-internal`.`netsuite2`.`customer`
    on revenue_with_billing.billing_account_id = customer.custentity_ft_account_id_sf
    and not customer._fivetran_deleted
), revenue_table_final as (
  select
    revenue_month_start,
    revenue_month_end,
    netsuite_customer_id,
    billing_account_id,
    org_id,
    stripe_customer_id,
    netsuite_customer_name,
    product_type,
    revenue_type,
    item.id as item_id,
    status,
    coalesce(credits_used, round(revenue_amount, 2)) as quantity,
    round(revenue_amount, 2) as amount,
    to_be_emailed
  from revenue_with_netsuite
  left join `private-internal`.`netsuite2`.`item`
    on item.name = 'RunCache'
    and not item._fivetran_deleted
), add_transformation as (
  select
    revenue_table_final.*,
    if(quantity >= 0, quantity, abs(quantity)) as netsuite_quantity,
    if(amount >= 0, amount, abs(amount)) as netsuite_amount,
    safe_divide(amount, quantity) as rate,
    'Autopay' as payment_term,
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
    -- RC prefix separates RunCache from Fivetran (CBPINV/CBPCM) for Finance reporting
    case
      when transaction_type = 'Credit Memo'
      then
        concat(
          'RCCM',
          netsuite_customer_id,
          cast(revenue_month_end as string format 'YYYYMM')
        )
      else
        concat(
          'RCINV',
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
