WITH staging_subscriptions AS (
  SELECT *
  FROM `digital-arbor-400.pg_public.subscriptions`
  WHERE NOT _fivetran_deleted
    AND NOT is_evergreen
    --AND created_at >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1095 DAY)
    AND salesforce_id IS NOT NULL
    AND order_number IS NOT NULL
    AND COALESCE(product_code, '') NOT LIKE 'Free%'
    AND payer_type = 'RESELLER'
  QUALIFY ROW_NUMBER() OVER (PARTITION BY salesforce_id ORDER BY version DESC) = 1
)

SELECT
  ss.salesforce_account_id,
  COUNT(DISTINCT ss.third_party_payer_id) AS reseller_count,
  STRING_AGG(DISTINCT ss.billing_account_id, ', ') AS billing_account_ids,
  STRING_AGG(DISTINCT ss.third_party_payer_id, ', ') AS partner_ids,
  STRING_AGG(DISTINCT reseller_abi.legal_name, ', ') AS reseller_names,
  STRING_AGG(DISTINCT customer_abi.legal_name, ', ') AS customer_names
FROM
  staging_subscriptions ss
LEFT JOIN `digital-arbor-400.pg_public.account_billing_info` reseller_abi
  ON ss.third_party_payer_id = reseller_abi.account_id
LEFT JOIN `digital-arbor-400.pg_public.account_billing_info` customer_abi
  ON ss.billing_account_id = customer_abi.account_id
GROUP BY
  ss.salesforce_account_id
ORDER BY
  reseller_count DESC;
