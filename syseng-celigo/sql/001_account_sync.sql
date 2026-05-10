WITH latest_subscriptions AS (
  SELECT *,
    COALESCE(
      CASE
        WHEN payer_type IN ('RESELLER', 'MARKETPLACE','RESELLER_MARKETPLACE') THEN third_party_payer_id  --https://fivetran.atlassian.net/browse/RD-1010499
        ELSE NULL 
      END,
      billing_account_id
    ) AS payer_account_id
  FROM digital-arbor-400.pg_public.subscriptions
  WHERE not _fivetran_deleted
  AND (DATE(contract_end_date) >= CURRENT_DATE() or contract_end_date is null) -- https://fivetran.atlassian.net/browse/RD-1016623 and https://fivetran.atlassian.net/browse/RD-1022588
  -- AND _fivetran_synced >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 60 DAY)
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY salesforce_id
    ORDER BY version DESC
  ) = 1
)

SELECT
  ls.*,
  acct.*,
  acct_info.*

FROM
  latest_subscriptions ls
INNER JOIN
 digital-arbor-400.pg_public.accounts acct
    ON ls.billing_account_id = acct.id
LEFT JOIN
  digital-arbor-400.pg_public.account_billing_info acct_info
    ON acct.id = acct_info.account_id
WHERE
  ls.billing_account_id IS NOT NULL
  AND (acct.status IN ('Customer', 'Frozen', 'Partner') 
       OR ls.type ='CENSUS_X_SELL') -- https://fivetran.atlassian.net/browse/RD-1021465
  AND (acct.platform_tier NOT IN ('Free_2024', 'Free_2022') OR acct.platform_tier IS NULL)  -- as per T-979869
  AND ls.type NOT IN ('FREE_2022', 'FREE_2024')  -- as per T-979869
  AND (
    acct.freeze_reason IS NULL
    OR acct.freeze_reason != 'TRIAL_EXPIRED'
  )
  AND ls.order_number IS NOT NULL
 AND (
    ls._fivetran_synced >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 28 HOUR)
    OR acct_info._fivetran_synced >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 28 HOUR)
    OR acct._fivetran_synced >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 28 HOUR))

--AND ls.billing_account_id ='qwiklabs_acc'