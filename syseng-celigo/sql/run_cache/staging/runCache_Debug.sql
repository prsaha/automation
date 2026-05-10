SELECT COUNT(*), MIN(revenue_date_utc), MAX(revenue_date_utc)
FROM `dulcet-yew-246109`.`staging_billing_public`.`revenue_records`
WHERE product_type = 'DBT_RUN_CACHE'
  AND _fivetran_deleted IS FALSE;


  SELECT COUNT(*)
FROM `dulcet-yew-246109`.`staging_billing_public`.`revenue_records` AS rr
INNER JOIN `dulcet-yew-246109`.`staging_billing_public`.`run_cache_accounts` AS rca
  ON rr.billing_account_id = rca.billing_info_id
  AND rca._fivetran_deleted IS FALSE
WHERE rr.product_type = 'DBT_RUN_CACHE'
  AND rr._fivetran_deleted IS FALSE;

SELECT 
  TYPEOF(rr.billing_account_id)  AS rr_type,
  TYPEOF(rca.billing_info_id)    AS rca_type,
  rr.billing_account_id          AS rr_id,
  rca.billing_info_id            AS rca_id
FROM `dulcet-yew-246109`.`staging_billing_public`.`revenue_records` AS rr
CROSS JOIN `dulcet-yew-246109`.`staging_billing_public`.`run_cache_accounts` AS rca
WHERE rr.product_type = 'DBT_RUN_CACHE'
  AND rr._fivetran_deleted IS FALSE
  AND rca._fivetran_deleted IS FALSE
LIMIT 10;


SELECT *
FROM `dulcet-yew-246109`.`staging_billing_public`.`run_cache_accounts`
WHERE _fivetran_deleted IS FALSE
LIMIT 3;


SELECT *
FROM `dulcet-yew-246109`.`staging_billing_public`.`account_billing_info`
WHERE _fivetran_deleted IS FALSE
LIMIT 3;


SELECT rr.billing_account_id, rca.run_cache_org_id, rca.billing_info_id
FROM `dulcet-yew-246109`.`staging_billing_public`.`revenue_records` AS rr
LEFT JOIN `dulcet-yew-246109`.`staging_billing_public`.`run_cache_accounts` AS rca
  ON rr.billing_account_id = rca.run_cache_org_id
  AND rca._fivetran_deleted IS FALSE
WHERE rr.product_type = 'DBT_RUN_CACHE'
  AND rr._fivetran_deleted IS FALSE
LIMIT 10;



-- What org IDs are in revenue_records?
SELECT DISTINCT billing_account_id
FROM `dulcet-yew-246109`.`staging_billing_public`.`revenue_records`
WHERE product_type = 'DBT_RUN_CACHE'
  AND _fivetran_deleted IS FALSE;

-- What org IDs are in run_cache_accounts?
SELECT DISTINCT run_cache_org_id, billing_info_id
FROM `dulcet-yew-246109`.`staging_billing_public`.`run_cache_accounts`
WHERE _fivetran_deleted IS FALSE;