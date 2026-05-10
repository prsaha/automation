-- Author  : Prabal Saha
-- Date    : 2026-04-16
-- Version : 1.06-STG
-- Purpose : RunCache monthly revenue sync to NetSuite via Celigo.
-- Step 1: Pre-filter and deduplicate account_billing_info.
--         Takes most recently updated row per billing account to prevent fanout.
with deduped_account_billing_info as (
  select
    billing_info.id,
    billing_info.stripe_customer_id
  from `dulcet-yew-246109`.`staging_billing_public`.`account_billing_info` billing_info
  where not billing_info._fivetran_deleted
  qualify row_number() over (
    partition by billing_info.id
    order by billing_info.updated_at desc
  ) = 1
),
-- Step 2: Pre-filter active NetSuite sandbox customers.
active_netsuite_customers as (
  select
    netsuite_customer.id,
    netsuite_customer.custentity_ft_account_id_sf,
    netsuite_customer.companyname,
    netsuite_customer.email,
    netsuite_customer.custentitycustentity_email
  from `private-internal`.`netsuite2_sandbox`.`customer` netsuite_customer
  where not netsuite_customer._fivetran_deleted
  and netsuite_customer.isinactive = 'F'  
  and netsuite_customer.entitystatus = 13 
  and netsuite_customer.isperson = 'F'       -- Only active customers
),
-- Step 3: Resolve the RunCache item from NetSuite.
netsuite_run_cache_item as (
  select
    netsuite_item.id
  from `private-internal`.`netsuite2_sandbox`.`item` netsuite_item
  where netsuite_item.itemid = 'RunCache'
    and not netsuite_item._fivetran_deleted
),
-- Step 4: Aggregate RunCache revenue records by billing account and month.
--         Only fact-level keys in GROUP BY — dimension attributes joined in Step 5.
credits_by_billing_account_and_month as (
  select
    revenue_records.billing_account_id,
    date(date_trunc(revenue_records.revenue_date_utc, month)) as revenue_month_start,
    revenue_records.type as revenue_type,
    revenue_records.product_type,
    revenue_records.status,
    sum(revenue_records.credits_used) as credits_used,
    sum(revenue_records.amount) as revenue_amount
  from `dulcet-yew-246109`.`staging_billing_public`.`revenue_records` revenue_records
  where revenue_records.product_type = 'DBT_RUN_CACHE'
    and not revenue_records._fivetran_deleted
  group by 1, 2, 3, 4, 5
),
-- Step 5: Join dimension attributes after aggregation — stripe_customer_id and NetSuite customer data.
credits_by_billing_account_with_netsuite_customer as (
  select
    credits.billing_account_id,
    billing_info.stripe_customer_id,
    credits.revenue_month_start,
    credits.revenue_type,
    credits.product_type,
    credits.status,
    credits.credits_used,
    credits.revenue_amount,
    netsuite_customer.companyname as netsuite_customer_name,
    safe_cast(netsuite_customer.id as string) as netsuite_customer_id,
    last_day(credits.revenue_month_start, month) as revenue_month_end,
    if(
      netsuite_customer.email = netsuite_customer.custentitycustentity_email,
      netsuite_customer.email,
      coalesce(
        concat(netsuite_customer.email, ',', netsuite_customer.custentitycustentity_email),
        netsuite_customer.email,
        netsuite_customer.custentitycustentity_email
      )
    ) as to_be_emailed
  from credits_by_billing_account_and_month credits
  left join deduped_account_billing_info billing_info
    on credits.billing_account_id = billing_info.id
  left join active_netsuite_customers netsuite_customer
    on credits.billing_account_id = netsuite_customer.custentity_ft_account_id_sf
),
-- Step 6: Resolve NetSuite item_id and compute quantity and amount.
revenue_by_billing_account_with_item as (
  select
    credits_with_customer.billing_account_id,
    credits_with_customer.stripe_customer_id,
    credits_with_customer.revenue_month_start,
    credits_with_customer.revenue_month_end,
    credits_with_customer.revenue_type,
    credits_with_customer.product_type,
    credits_with_customer.status,
    credits_with_customer.netsuite_customer_name,
    credits_with_customer.netsuite_customer_id,
    credits_with_customer.to_be_emailed,
    netsuite_run_cache_item.id as item_id,
    coalesce(
      credits_with_customer.credits_used,
      round(credits_with_customer.revenue_amount, 2)
    ) as quantity,
    round(credits_with_customer.revenue_amount, 2) as amount
  from credits_by_billing_account_with_netsuite_customer credits_with_customer
  left join netsuite_run_cache_item on true
  qualify row_number() over (
    partition by credits_with_customer.billing_account_id, credits_with_customer.revenue_month_start
    order by netsuite_run_cache_item.id
  ) = 1
),
-- Step 7: Classify rows as Invoice, Credit Memo, or None based on amount sign.
--         netsuite_quantity and netsuite_amount are always positive — sign carried by transaction_type.
revenue_by_billing_account_with_transaction_type as (
  select
    revenue_with_item.billing_account_id,
    revenue_with_item.stripe_customer_id,
    revenue_with_item.revenue_month_start,
    revenue_with_item.revenue_month_end,
    revenue_with_item.revenue_type,
    revenue_with_item.product_type,
    revenue_with_item.status,
    revenue_with_item.netsuite_customer_name,
    revenue_with_item.netsuite_customer_id,
    revenue_with_item.to_be_emailed,
    revenue_with_item.item_id,
    revenue_with_item.quantity,
    revenue_with_item.amount,
    abs(revenue_with_item.quantity) as netsuite_quantity,
    abs(revenue_with_item.amount) as netsuite_amount,
    safe_divide(revenue_with_item.amount, revenue_with_item.quantity) as rate,
    'Autopay' as payment_term,
    case
      when revenue_with_item.amount >= 1 then 'Invoice'
      when revenue_with_item.amount < 0  then 'Credit Memo'
      else 'None'
    end  as transaction_type
  from revenue_by_billing_account_with_item revenue_with_item
),
-- Step 8: Build deterministic external_id for Celigo idempotency.
--         Format: RCINV{ns_customer_id}{YYYYMM} for invoices,
--                 RCCM{ns_customer_id}{YYYYMM}  for credit memos.
invoices_with_external_id as (
  select
    case
      when revenue_with_txn.transaction_type = 'Credit Memo'
      then concat('RCCM',  revenue_with_txn.netsuite_customer_id, cast(revenue_with_txn.revenue_month_end as string format 'YYYYMM'))
      else concat('RCINV', revenue_with_txn.netsuite_customer_id, cast(revenue_with_txn.revenue_month_end as string format 'YYYYMM'))
    end as external_id,
    revenue_with_txn.billing_account_id,
    revenue_with_txn.stripe_customer_id,
    revenue_with_txn.revenue_month_start,
    revenue_with_txn.revenue_month_end,
    revenue_with_txn.revenue_type,
    revenue_with_txn.product_type,
    revenue_with_txn.status,
    revenue_with_txn.netsuite_customer_name,
    revenue_with_txn.netsuite_customer_id,
    revenue_with_txn.to_be_emailed,
    revenue_with_txn.item_id,
    revenue_with_txn.quantity,
    revenue_with_txn.amount,
    revenue_with_txn.netsuite_quantity,
    revenue_with_txn.netsuite_amount,
    revenue_with_txn.rate,
    revenue_with_txn.payment_term,
    revenue_with_txn.transaction_type
  from revenue_by_billing_account_with_transaction_type revenue_with_txn
)
-- Step 9: Final output for Celigo.
--         line_number partitions invoice lines per external_id for multi-org customers.
select
  invoices.external_id,
  invoices.revenue_month_start,
  invoices.revenue_month_end,
  invoices.netsuite_customer_id,
  invoices.billing_account_id,
  invoices.stripe_customer_id,
  invoices.netsuite_customer_name,
  invoices.product_type,
  invoices.revenue_type,
  invoices.item_id,
  invoices.status,
  invoices.quantity,
  invoices.amount,
  invoices.to_be_emailed,
  invoices.netsuite_quantity,
  invoices.netsuite_amount,
  invoices.rate,
  invoices.payment_term,
  invoices.transaction_type,
  row_number() over (
    partition by invoices.external_id, invoices.transaction_type
    order by invoices.billing_account_id
  ) as line_number,
  'monthly_run_cache_revenue' as billing_sync
from invoices_with_external_id invoices
order by invoices.revenue_month_start desc, invoices.netsuite_customer_id
