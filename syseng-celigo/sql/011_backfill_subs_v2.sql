-- Combined query
WITH staging_subscriptions AS (
  SELECT *
  FROM `digital-arbor-400.pg_public.subscriptions`
  WHERE NOT _fivetran_deleted
    AND NOT is_evergreen
    AND created_at >= TIMESTAMP '2022-01-01 00:00:00 UTC'
    AND created_at <  TIMESTAMP '2025-01-01 00:00:00 UTC'
   /* AND created_at >= TIMESTAMP_SUB(TIMESTAMP '2025-06-13 00:00:00 UTC', INTERVAL 1095 DAY)
    AND created_at < TIMESTAMP '2025-06-14 00:00:00 UTC'*/
    AND salesforce_id IS NOT NULL
    AND order_number  IS NOT NULL
    --AND order_number = '00072362'
  QUALIFY
    -- keep order_numbers that map to exactly one distinct subscription id
    COUNT(DISTINCT id) OVER (PARTITION BY order_number) > 0
    -- keep latest version per salesforce_id
    AND ROW_NUMBER() OVER (PARTITION BY salesforce_id ORDER BY version DESC) = 1
)
SELECT
  ss.order_number,
  ss.id,
  ss.billing_account_id,
  ss.product_code,
  pm.netsuite_conn_net_suite_id_c,
 FORMAT_TIMESTAMP('%m/%d/%Y', ss.start_date_utc) AS service_start_date,
  FORMAT_TIMESTAMP('%m/%d/%Y', ss.end_date_utc)   AS service_end_date,
  ss.amount,
  ss.salesforce_id,
  ss.contract_start_date,
  ss.contract_end_date

FROM staging_subscriptions ss
LEFT JOIN salesforce.product_2 pm
  ON ss.product_code = pm.product_code
WHERE COALESCE(ss.product_code, '') NOT LIKE 'Free%'
--AND ss.billing_account_id = 'outline_passover'
--AND ss.order_number ='00080421' -- order with 1 line AND ss.order_number ='00065546' -- order with 2 lines
--and ss.salesforce_account_id ='801PY000008u4YzYAI'   -- example filter; remove or parametrize as needed
ORDER BY ss.start_date_utc, ss.end_date_utc