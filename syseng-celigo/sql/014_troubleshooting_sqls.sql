-- =============================================================================
-- 014_troubleshooting_sqls.sql
-- Debug queries derived from 001_account_sync.sql and 002_subscription_sync.sql
--
-- Usage: set the target account by replacing the DECLARE value below.
--        Comment/uncomment individual sections as needed.
-- =============================================================================

DECLARE target_account STRING DEFAULT 'alley_materialism';

-- =============================================================================
-- SECTION A: 001_account_sync.sql breakpoints
-- =============================================================================

-- ----------------------------------------------------------------------------
-- A1: Raw subscriptions for account — no dedup, no outer filters
--     Use this to confirm the account exists in pg_public.subscriptions
-- ----------------------------------------------------------------------------
/*
SELECT s.*
FROM `digital-arbor-400.pg_public.subscriptions` s
WHERE s.billing_account_id = target_account
  AND NOT s._fivetran_deleted
ORDER BY s.created_at DESC;
*/

-- ----------------------------------------------------------------------------
-- A2: Account status check — first thing to verify when 001 drops an account
--     Checks status, platform_tier, and freeze_reason all at once
-- ----------------------------------------------------------------------------
/*
SELECT
    a.id,
    a.status,
    a.platform_tier,
    a.freeze_reason,
    a._fivetran_synced,
    CASE
        WHEN a.status NOT IN ('Customer', 'Frozen', 'Partner') THEN 'FAIL: status not allowed'
        WHEN a.platform_tier IN ('Free_2024', 'Free_2022')     THEN 'FAIL: free tier'
        WHEN a.freeze_reason = 'TRIAL_EXPIRED'                 THEN 'FAIL: trial expired'
        WHEN a._fivetran_synced < TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 28 HOUR)
                                                               THEN 'WARN: stale acct sync'
        ELSE 'OK'
    END AS diagnosis
FROM `digital-arbor-400.pg_public.accounts` a
WHERE a.id = target_account;
*/

-- ----------------------------------------------------------------------------
-- A3: Full 001 CTE without recency filter
--     Shows what 001 would return if the 28-hour filter were removed.
--     If this returns rows but the live query doesn't → recency is the blocker.
--     If this returns nothing → status/freeze/tier filter is the blocker.
-- ----------------------------------------------------------------------------
/*
WITH latest_subscriptions AS (
    SELECT
        s.*,
        COALESCE(
            CASE
                WHEN s.payer_type IN ('RESELLER', 'MARKETPLACE', 'RESELLER_MARKETPLACE')
                    THEN s.third_party_payer_id
                ELSE NULL
            END,
            s.billing_account_id
        ) AS payer_account_id
    FROM `digital-arbor-400.pg_public.subscriptions` s
    WHERE NOT s._fivetran_deleted
        AND (DATE(s.contract_end_date) >= CURRENT_DATE OR s.contract_end_date IS NULL)
        AND s.billing_account_id = target_account
    QUALIFY ROW_NUMBER() OVER (PARTITION BY s.salesforce_id ORDER BY s.version DESC) = 1
)

SELECT
    ls.*,
    acct.status,
    acct.platform_tier,
    acct.freeze_reason,
    acct._fivetran_synced AS acct_synced_at,
    acct_info._fivetran_synced AS acct_info_synced_at
FROM latest_subscriptions ls
INNER JOIN `digital-arbor-400.pg_public.accounts` acct
    ON ls.billing_account_id = acct.id
LEFT JOIN `digital-arbor-400.pg_public.account_billing_info` acct_info
    ON acct.id = acct_info.account_id
    AND NOT acct_info._fivetran_deleted
WHERE
    ls.billing_account_id IS NOT NULL
    AND (acct.status IN ('Customer', 'Frozen', 'Partner') OR ls.type = 'CENSUS_X_SELL')
    AND (acct.platform_tier NOT IN ('Free_2024', 'Free_2022') OR acct.platform_tier IS NULL)
    AND ls.type NOT IN ('FREE_2022', 'FREE_2024')
    AND (acct.freeze_reason IS NULL OR acct.freeze_reason != 'TRIAL_EXPIRED');
    -- Recency filter intentionally omitted
*/

-- ----------------------------------------------------------------------------
-- A4: Accounts dropped by status / freeze_reason in the last 28-hour window
--     Useful for finding accounts that synced recently but failed the status gate
-- ----------------------------------------------------------------------------
/*
SELECT
    a.id,
    a.status,
    a.platform_tier,
    a.freeze_reason,
    a._fivetran_synced,
    CASE
        WHEN a.status NOT IN ('Customer', 'Frozen', 'Partner') THEN 'status'
        WHEN a.platform_tier IN ('Free_2024', 'Free_2022')     THEN 'platform_tier'
        WHEN a.freeze_reason = 'TRIAL_EXPIRED'                 THEN 'freeze_reason'
        ELSE 'unknown'
    END AS drop_reason
FROM `digital-arbor-400.pg_public.accounts` a
WHERE
    a._fivetran_synced >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 28 HOUR)
    AND NOT (
        a.status IN ('Customer', 'Frozen', 'Partner')
        AND (a.platform_tier NOT IN ('Free_2024', 'Free_2022') OR a.platform_tier IS NULL)
        AND (a.freeze_reason IS NULL OR a.freeze_reason != 'TRIAL_EXPIRED')
    )
ORDER BY a._fivetran_synced DESC;
*/


-- =============================================================================
-- SECTION B: 002_subscription_sync.sql breakpoints
-- =============================================================================

-- ----------------------------------------------------------------------------
-- B1: Raw subscriptions — no dedup, no filters
--     First stop: confirm the account and its rows exist at all
-- ----------------------------------------------------------------------------
/*
SELECT
    s.id,
    s.billing_account_id,
    s.salesforce_id,
    s.type,
    s.order_number,
    s.version,
    s.termination_date_utc,
    s.contract_start_date,
    s.contract_end_date,
    s._fivetran_synced,
    s._fivetran_deleted
FROM `digital-arbor-400.pg_public.subscriptions` s
WHERE s.billing_account_id = target_account
ORDER BY s.salesforce_id, s.version DESC;
*/

-- ----------------------------------------------------------------------------
-- B2: After dedup — latest version per salesforce_id
--     If a row you expect is missing here, an older/newer version is winning
-- ----------------------------------------------------------------------------
/*
SELECT
    s.id,
    s.billing_account_id,
    s.salesforce_id,
    s.type,
    s.order_number,
    s.version,
    s.termination_date_utc,
    s._fivetran_synced
FROM `digital-arbor-400.pg_public.subscriptions` s
WHERE NOT s._fivetran_deleted
    AND NOT s.is_evergreen
    AND s.created_at >= TIMESTAMP('2025-06-15 00:00:00')
    AND s.billing_account_id = target_account
QUALIFY ROW_NUMBER() OVER (PARTITION BY s.salesforce_id ORDER BY s.version DESC) = 1;
*/

-- ----------------------------------------------------------------------------
-- B3: Billing info join quality check
--     Shows payer and customer account_billing_info side-by-side.
--     NULL on both sides = join missed; investigate account_billing_info for that id.
-- ----------------------------------------------------------------------------
/*
WITH latest_subscriptions AS (
    SELECT
        *,
        COALESCE(
            CASE
                WHEN payer_type IN ('RESELLER', 'MARKETPLACE', 'RESELLER_MARKETPLACE')
                    THEN third_party_payer_id
                ELSE NULL
            END,
            billing_account_id
        ) AS payer_account_id
    FROM `digital-arbor-400.pg_public.subscriptions`
    WHERE NOT _fivetran_deleted
        AND NOT is_evergreen
        AND created_at >= TIMESTAMP('2025-06-15 00:00:00')
        AND billing_account_id = target_account
    QUALIFY ROW_NUMBER() OVER (PARTITION BY salesforce_id ORDER BY version DESC) = 1
)

SELECT
    ls.id,
    ls.billing_account_id,
    ls.payer_type,
    ls.third_party_payer_id,
    ls._fivetran_synced                    AS sub_synced_at,
    acct_payer.account_id                  AS payer_join_hit,
    acct_payer._fivetran_synced            AS payer_synced_at,
    acct_customer.account_id               AS customer_join_hit,
    acct_customer._fivetran_synced         AS customer_synced_at
FROM latest_subscriptions ls
LEFT JOIN `digital-arbor-400.pg_public.account_billing_info` acct_payer
    ON ls.third_party_payer_id = acct_payer.account_id
    AND NOT acct_payer._fivetran_deleted
LEFT JOIN `digital-arbor-400.pg_public.account_billing_info` acct_customer
    ON ls.billing_account_id = acct_customer.account_id
    AND NOT acct_customer._fivetran_deleted;
*/

-- ----------------------------------------------------------------------------
-- B4: Type / order filter check — without recency
--     Shows which rows survive the WHERE filters but are blocked by the
--     28-hour recency gate. If rows appear here but not in live 002 → recency blocker.
-- ----------------------------------------------------------------------------
/*
WITH latest_subscriptions AS (
    SELECT
        *,
        COALESCE(
            CASE
                WHEN payer_type IN ('RESELLER', 'MARKETPLACE', 'RESELLER_MARKETPLACE')
                    THEN third_party_payer_id
                ELSE NULL
            END,
            billing_account_id
        ) AS payer_account_id
    FROM `digital-arbor-400.pg_public.subscriptions`
    WHERE NOT _fivetran_deleted
        AND NOT is_evergreen
        AND created_at >= TIMESTAMP('2025-06-15 00:00:00')
        AND billing_account_id = target_account
    QUALIFY ROW_NUMBER() OVER (PARTITION BY salesforce_id ORDER BY version DESC) = 1
)

SELECT
    ls.id,
    ls.billing_account_id,
    ls.type,
    ls.order_number,
    ls.amount,
    ls._fivetran_synced,
    acct_customer._fivetran_synced AS customer_synced_at,
    acct_payer._fivetran_synced    AS payer_synced_at,
    GREATEST(
        ls._fivetran_synced,
        COALESCE(acct_customer._fivetran_synced, '1970-01-01'),
        COALESCE(acct_payer._fivetran_synced, '1970-01-01')
    )                              AS latest_any_sync,
    TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 28 HOUR) AS cutoff_28h
FROM latest_subscriptions ls
LEFT JOIN `digital-arbor-400.pg_public.account_billing_info` acct_payer
    ON ls.third_party_payer_id = acct_payer.account_id
    AND NOT acct_payer._fivetran_deleted
LEFT JOIN `digital-arbor-400.pg_public.account_billing_info` acct_customer
    ON ls.billing_account_id = acct_customer.account_id
    AND NOT acct_customer._fivetran_deleted
WHERE
    ls.type NOT IN ('FREE_2024', 'FREE_2022', 'FREE_2026')
    AND ls.order_number IS NOT NULL
    AND ls.type <> 'CENSUS_LEGACY'
    AND COALESCE(ls.product_code, '') <> 'Tobiko_Legacy_Pre_Migration';
    -- Recency filter intentionally omitted
*/

-- ----------------------------------------------------------------------------
-- B5: Zero-total order groups — find orders that will be silently dropped
--     Any order_number where SUM(amount) = 0 is rejected by Celigo.
--     Common cause: upsell + credit/expiry line netting to zero.
-- ----------------------------------------------------------------------------
/*
WITH latest_subscriptions AS (
    SELECT
        *,
        COALESCE(
            CASE
                WHEN payer_type IN ('RESELLER', 'MARKETPLACE', 'RESELLER_MARKETPLACE')
                    THEN third_party_payer_id
                ELSE NULL
            END,
            billing_account_id
        ) AS payer_account_id
    FROM `digital-arbor-400.pg_public.subscriptions`
    WHERE NOT _fivetran_deleted
        AND NOT is_evergreen
        AND created_at >= TIMESTAMP('2025-06-15 00:00:00')
    QUALIFY ROW_NUMBER() OVER (PARTITION BY salesforce_id ORDER BY version DESC) = 1
)

SELECT
    ls.order_number,
    ls.billing_account_id,
    COUNT(*)              AS line_count,
    SUM(SAFE_CAST(ls.amount AS FLOAT64)) AS total_amount,
    STRING_AGG(CAST(ls.id AS STRING) ORDER BY ls.id) AS subscription_ids,
    STRING_AGG(ls.type ORDER BY ls.id)               AS types
FROM latest_subscriptions ls
LEFT JOIN `digital-arbor-400.pg_public.account_billing_info` acct_payer
    ON ls.third_party_payer_id = acct_payer.account_id
    AND NOT acct_payer._fivetran_deleted
LEFT JOIN `digital-arbor-400.pg_public.account_billing_info` acct_customer
    ON ls.billing_account_id = acct_customer.account_id
    AND NOT acct_customer._fivetran_deleted
WHERE
    ls.type NOT IN ('FREE_2024', 'FREE_2022', 'FREE_2026')
    AND ls.order_number IS NOT NULL
    AND ls.type <> 'CENSUS_LEGACY'
    AND COALESCE(ls.product_code, '') <> 'Tobiko_Legacy_Pre_Migration'
GROUP BY 1, 2
HAVING SUM(SAFE_CAST(ls.amount AS FLOAT64)) = 0
ORDER BY ls.billing_account_id;
*/
