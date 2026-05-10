WITH owner_changes_28h AS (
  SELECT
    ah.account_id   AS sf_account_id,
    ah.old_value    AS old_owner_user_id,
    ah.new_value    AS new_owner_user_id,
    ah.created_date AS created_date
  FROM `digital-arbor-400.salesforce.account_history` AS ah
  JOIN `digital-arbor-400.salesforce.account` AS a
    ON ah.account_id = a.id
  WHERE
    ah.is_deleted = FALSE
    AND a.is_deleted = FALSE
    AND ah.field = 'Owner'
    AND ah.data_type = 'EntityId'
    AND ah.created_date >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 28 HOUR)
  QUALIFY
    ROW_NUMBER() OVER (
      PARTITION BY ah.account_id
      ORDER BY ah.created_date DESC
    ) = 1
),
sf_account_mapping AS (
  SELECT
    fac.fivetran_account_id_c AS billing_account_id,
    fac.account_c             AS sf_account_id
  FROM `digital-arbor-400.salesforce.fivetran_account_c` AS fac
  WHERE
    fac.fivetran_account_id_c IS NOT NULL
    AND fac.account_c IS NOT NULL
),
sf_user_email AS (
  SELECT
    u.id    AS sf_user_id,
    u.email AS owner_email
  FROM `digital-arbor-400.salesforce.user` AS u
),
pg_accounts AS (
  SELECT
    id     AS billing_account_id,
    status AS status,
  FROM pg_public.accounts
)

SELECT
  sam.billing_account_id,
  oc.sf_account_id,
  newu.owner_email AS new_owner_email,
  oldu.owner_email AS old_owner_email,
  oc.created_date  AS owner_change_created_date,
  pga.status       AS status
FROM owner_changes_28h AS oc
LEFT JOIN sf_account_mapping AS sam
  ON oc.sf_account_id = sam.sf_account_id
LEFT JOIN sf_user_email AS newu
  ON oc.new_owner_user_id = newu.sf_user_id
LEFT JOIN sf_user_email AS oldu
  ON oc.old_owner_user_id = oldu.sf_user_id
LEFT JOIN pg_accounts AS pga
  ON sam.billing_account_id = pga.billing_account_id
WHERE
  sam.billing_account_id IS NOT NULL
  AND newu.owner_email IS NOT NULL
  AND LOWER(newu.owner_email) <> 'selfserviceuser@fivetran.com'
  AND pga.status  IN ('Customer','Frozen')
  AND sam.billing_account_id = 'imply_appurtenances'
ORDER BY
  oc.created_date DESC;