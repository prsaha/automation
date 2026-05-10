WITH latest_subscriptions AS (
  SELECT *,
    COALESCE(
      CASE
        WHEN payer_type IN ('RESELLER', 'MARKETPLACE') THEN third_party_payer_id
        ELSE NULL
      END,
      billing_account_id
    ) AS payer_account_id
  FROM pg_public.subscriptions
  WHERE _fivetran_deleted = false
    /*AND _fivetran_synced >= TIMESTAMP('2025-06-01')
    AND _fivetran_synced < TIMESTAMP('2025-07-01')*/
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY salesforce_id
    ORDER BY version DESC
  ) = 1
),

final_result AS (
  SELECT
    ls.billing_account_id,
    ls.third_party_payer_id,
    ls.salesforce_account_id,
    ls._fivetran_synced subscription_sync_time,
    acct._fivetran_synced account_sync_time,
    acct_info._fivetran_synced billing_sync_time,
    acct_info.billing_address,
    acct_info.shipping_address,
    acct_info.legal_name,
    ls.payer_type,
   

    -- Field-level missing flags
    CASE 
      WHEN acct_info.billing_address IS NULL OR TRIM(acct_info.billing_address) = '' THEN TRUE 
      ELSE FALSE 
    END AS is_billing_missing,

    CASE 
      WHEN acct_info.shipping_address IS NULL OR TRIM(acct_info.shipping_address) = '' THEN TRUE 
      ELSE FALSE 
    END AS is_shipping_missing,

    CASE 
      WHEN acct_info.legal_name IS NULL OR TRIM(acct_info.legal_name) = '' THEN TRUE 
      ELSE FALSE 
    END AS is_legal_missing,

    -- Composite missing flag (all three fields missing)
    CASE
      WHEN (
        (acct_info.billing_address IS NULL OR TRIM(acct_info.billing_address) = '')
        AND (acct_info.shipping_address IS NULL OR TRIM(acct_info.shipping_address) = '')
        AND (acct_info.legal_name IS NULL OR TRIM(acct_info.legal_name) = '')
      ) THEN TRUE
      ELSE FALSE
    END AS is_missing_critical_info

  FROM
    latest_subscriptions ls
  FULL OUTER JOIN
    pg_public.accounts acct
      ON ls.billing_account_id = acct.id
  LEFT JOIN
    pg_public.account_billing_info acct_info
      ON acct.id = acct_info.account_id
  WHERE
    ls.billing_account_id IS NOT NULL
    AND acct.status IN ('Customer', 'Frozen', 'Partner')
    AND (acct.platform_tier NOT IN ('Free_2024', 'Free_2022') OR acct.platform_tier IS NULL)
    AND ls.type NOT IN ('FREE_2022', 'FREE_2024')
    AND (
      acct.freeze_reason IS NULL
      OR acct.freeze_reason != 'TRIAL_EXPIRED'
    )
    /*AND (
      (ls._fivetran_synced >= TIMESTAMP('2025-06-01') AND ls._fivetran_synced < TIMESTAMP('2025-07-10'))
      OR (acct_info._fivetran_synced >= TIMESTAMP('2025-06-01') AND acct_info._fivetran_synced < TIMESTAMP('2025-07-10'))
      OR (acct._fivetran_synced >= TIMESTAMP('2025-06-01') AND acct._fivetran_synced < TIMESTAMP('2025-07-10'))
    )*/
/*AND (
  (ls._fivetran_synced >= TIMESTAMP(DATE_TRUNC(CURRENT_DATE(), MONTH)) AND ls._fivetran_synced < TIMESTAMP(DATE_TRUNC(DATE_ADD(CURRENT_DATE(), INTERVAL 1 MONTH), MONTH)))
  OR (acct_info._fivetran_synced >= TIMESTAMP(DATE_TRUNC(CURRENT_DATE(), MONTH)) AND acct_info._fivetran_synced < TIMESTAMP(DATE_TRUNC(DATE_ADD(CURRENT_DATE(), INTERVAL 1 MONTH), MONTH)))
  OR (acct._fivetran_synced >= TIMESTAMP(DATE_TRUNC(CURRENT_DATE(), MONTH)) AND acct._fivetran_synced < TIMESTAMP(DATE_TRUNC(DATE_ADD(CURRENT_DATE(), INTERVAL 1 MONTH), MONTH)))
)*/
AND (
  (ls._fivetran_synced >= TIMESTAMP(DATE '2025-06-01') AND ls._fivetran_synced < TIMESTAMP(DATE_ADD(CURRENT_DATE(), INTERVAL 1 DAY)))
  OR (acct_info._fivetran_synced >= TIMESTAMP(DATE '2025-06-01') AND acct_info._fivetran_synced < TIMESTAMP(DATE_ADD(CURRENT_DATE(), INTERVAL 1 DAY)))
  OR (acct._fivetran_synced >= TIMESTAMP(DATE '2025-06-01') AND acct._fivetran_synced < TIMESTAMP(DATE_ADD(CURRENT_DATE(), INTERVAL 1 DAY)))
)
)

SELECT  DISTINCT *
FROM  final_result where is_missing_critical_info = true ;



select * from pg_public.account_billing_info where account_id ='textual_commander'