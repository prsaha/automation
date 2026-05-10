/* --- Backup code as of 10/7 9:50 am PST ---- */

WITH latest_subscriptions AS (
    SELECT
        *,
        COALESCE(
            CASE
                -- Use third_party_payer_id if payer_type is Reseller/Marketplace
                -- Ref: https://fivetran.atlassian.net/browse/RD-1019884
                WHEN payer_type IN (
                    'RESELLER',
                    'MARKETPLACE',
                    'RESELLER_MARKETPLACE'
                ) THEN third_party_payer_id

                -- Default to billing_account_id otherwise (including NULL)
                ELSE NULL
            END,
            billing_account_id
        ) AS payer_account_id
    FROM
        `digital-arbor-400.pg_public.subscriptions`
    WHERE
        _fivetran_deleted = FALSE
        AND is_evergreen = FALSE               -- Filter Monthly subscriptions
        -- AND termination_date_utc IS NULL    -- Ref: https://fivetran.height.app/T-981338
        AND created_at >= TIMESTAMP('2025-06-15 00:00:00')
            -- New logic per https://fivetran.atlassian.net/browse/RD-1007931
    QUALIFY
        ROW_NUMBER() OVER (
            PARTITION BY salesforce_id         -- Track latest subscription per Salesforce ID
            ORDER BY version DESC
        ) = 1
)

SELECT
    ls.*,

    -- Billing address based on payer type (#T-952560, RD-1019884)
    CASE
        WHEN ls.payer_type IN (
            'RESELLER',
            'MARKETPLACE',
            'RESELLER_MARKETPLACE'
        ) THEN acct_payer.billing_address
        ELSE acct_customer.billing_address
    END AS billing_address,

    -- Shipping address always comes from customer (#T-952560)
    acct_customer.shipping_address AS shipping_address,

    -- Legal name based on payer type (#RD-1019884)
    CASE
        WHEN ls.payer_type IN (
            'RESELLER',
            'MARKETPLACE',
            'RESELLER_MARKETPLACE'
        ) THEN acct_customer.legal_name
        ELSE acct_customer.legal_name
    END AS legal_name,

    -- Tax ID based on payer type (#RD-1019884)
    CASE
        WHEN ls.payer_type IN (
            'RESELLER',
            'MARKETPLACE',
            'RESELLER_MARKETPLACE'
        ) THEN acct_payer.tax_id
        ELSE acct_customer.tax_id
    END AS tax_id

FROM
    latest_subscriptions ls

    -- Billing info for reseller/marketplace payer
    LEFT JOIN `digital-arbor-400.pg_public.account_billing_info` acct_payer
        ON ls.third_party_payer_id = acct_payer.account_id
        AND acct_payer._fivetran_deleted = FALSE

    -- Customer billing/shipping info
    LEFT JOIN `digital-arbor-400.pg_public.account_billing_info` acct_customer
        ON ls.billing_account_id = acct_customer.account_id
        AND acct_customer._fivetran_deleted = FALSE  -- Fixed: was incorrectly referencing acct_payer

WHERE
    ls.type NOT IN ('FREE_2024', 'FREE_2022', 'FREE_2026')
    AND ls.order_number IS NOT NULL
    AND ls.type <> 'CENSUS_LEGACY'
        -- Ref: https://fivetran.atlassian.net/browse/RD-1063527
    AND COALESCE(ls.product_code, '') <> 'Tobiko_Legacy_Pre_Migration'
        -- Ref: https://fivetran.atlassian.net/browse/RD-1179313

    /* Filter based on latest sync time
       Ref: https://fivetran.atlassian.net/browse/RD-1002486 */

AND (
           ls._fivetran_synced >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 28 HOUR)
        OR acct_customer._fivetran_synced >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 28 HOUR)
        OR acct_payer._fivetran_synced >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 28 HOUR))