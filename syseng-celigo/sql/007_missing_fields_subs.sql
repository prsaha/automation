WITH latest_subscriptions AS (
  SELECT
    *,
    COALESCE(
      CASE
        WHEN payer_type IN ('RESELLER', 'MARKETPLACE') THEN third_party_payer_id
        ELSE NULL
      END,
      billing_account_id
    ) AS payer_account_id
  FROM
    pg_public.subscriptions
  WHERE
    _fivetran_deleted = false
    AND is_evergreen = false
    AND _fivetran_synced >= TIMESTAMP(DATE '2025-07-01')
    AND _fivetran_synced < TIMESTAMP(DATE_ADD(CURRENT_DATE(), INTERVAL 1 DAY))
   -- AND billing_account_id ='muster_uncharted'
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY salesforce_id
    ORDER BY version DESC
  ) = 1
),

subscription_data AS (
  SELECT
    ls.billing_account_id,
    ls.salesforce_account_id,
    ls.payer_type,
    ls._fivetran_synced ,
    ls.third_party_payer_id,
    ls.order_number,

    -- Unified address and name fields
    CASE 
      WHEN ls.payer_type IN ('RESELLER', 'MARKETPLACE') THEN acct_payer.billing_address
      ELSE acct_customer.billing_address
    END AS billing_address,

    acct_customer.shipping_address AS shipping_address,

    CASE 
      WHEN ls.payer_type IN ('RESELLER', 'MARKETPLACE') THEN acct_payer.legal_name
      ELSE acct_customer.legal_name
    END AS legal_name

  FROM
    latest_subscriptions ls
  FULL OUTER JOIN pg_public.account_billing_info acct_payer
    ON ls.third_party_payer_id = acct_payer.account_id
  LEFT JOIN pg_public.account_billing_info acct_customer
    ON ls.billing_account_id = acct_customer.account_id
  WHERE
    ls.type NOT IN ('FREE_2024', 'FREE_2022')
    AND ls.order_number IS NOT NULL
)

SELECT *
FROM (
  SELECT distinct
    billing_account_id,
    third_party_payer_id,
    salesforce_account_id,
    order_number,
    _fivetran_synced subscription_synced_time,
    payer_type,
    billing_address,
    shipping_address,
    legal_name,

    -- Field-level missing flags
    CASE WHEN billing_address IS NULL OR TRIM(billing_address) = '' THEN TRUE ELSE FALSE END AS is_billing_missing,
    CASE WHEN shipping_address IS NULL OR TRIM(shipping_address) = '' THEN TRUE ELSE FALSE END AS is_shipping_missing,
    CASE WHEN legal_name IS NULL OR TRIM(legal_name) = '' THEN TRUE ELSE FALSE END AS is_legal_missing,

    -- Combined missing information flag
    CASE
      WHEN (
        (billing_address IS NULL OR TRIM(billing_address) = '') OR
        (shipping_address IS NULL OR TRIM(shipping_address) = '') OR
        (legal_name IS NULL OR TRIM(legal_name) = '')
      ) THEN TRUE
      ELSE FALSE
    END AS _is_missing_information
  FROM subscription_data
)
WHERE _is_missing_information = TRUE;
