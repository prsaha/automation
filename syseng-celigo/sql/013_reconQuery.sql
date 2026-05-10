-- ============================================================
-- SF <> NetSuite — Full Outer Join for order 00100361
-- ============================================================

WITH sf_order AS (
  SELECT
    order_number,
    id                                          AS sf_order_id,
    account_id                                  AS sf_account_id,
    status                                      AS sf_status,
    type                                        AS sf_order_type,
    effective_date                              AS sf_effective_date,
    end_date                                    AS sf_end_date,
    SAFE_CAST(total_amount AS NUMERIC)          AS sf_total_amount,
    celigo_sfnsio_net_suite_id_c                AS sf_ns_id,
    celigo_sfnsio_net_suite_order_number_c      AS sf_ns_order_number,
    celigo_sfnsio_skip_export_to_net_suite_c    AS sf_skip_export,
    celigo_sfnsio_test_mode_record_c            AS sf_test_mode,
    netsuite_conn_net_suite_id_c                AS sf_legacy_ns_id,
    synced_to_net_suite_c                       AS sf_synced_flag,
    sbqq_quote_c                                AS sf_quote_id,
    opportunity_id                              AS sf_opportunity_id,
    activated_date                              AS sf_activated_date

  FROM `digital-arbor-400.salesforce.order`
  WHERE _fivetran_deleted = false
    --AND order_number = '00100361'
),

ns_order AS (
  SELECT DISTINCT
    LOWER(TRIM(transaction_memo))               AS memo_norm,
    document_number                             AS ns_document_number,
    transaction_id                              AS ns_transaction_id,
    transaction_date                            AS ns_transaction_date,
    transaction_status                          AS ns_transaction_status,
    transaction_type                            AS ns_transaction_type,
    SAFE_CAST(transaction_amount AS NUMERIC)    AS ns_transaction_amount,
    billing_account_id                          AS ns_billing_account_id,
    customer_company_name                       AS ns_customer_name
  FROM `private-internal.transforms_bi.netsuite2_transaction_details`
  WHERE transaction_type = 'SalesOrd'
    AND accounting_book_name = 'Primary Accounting Book'
   -- AND LOWER(TRIM(transaction_memo)) = '00100361'
)

SELECT
  -- ── Presence indicator ────────────────────────────────
  CASE
    WHEN sf.order_number IS NOT NULL AND ns.memo_norm IS NOT NULL THEN 'MATCHED'
    WHEN sf.order_number IS NOT NULL AND ns.memo_norm IS NULL     THEN 'SF ONLY — missing in NS'
    WHEN sf.order_number IS NULL     AND ns.memo_norm IS NOT NULL THEN 'NS ONLY — missing in SF'
  END AS record_status,

  -- ── SF fields ─────────────────────────────────────────
  sf.order_number,
  sf.sf_order_id,
  sf.sf_account_id,
  sf.sf_status,
  sf.sf_order_type,
  DATE(sf.sf_effective_date)                    AS sf_effective_date,
  sf.sf_total_amount,
  sf.sf_synced_flag,
  sf.sf_skip_export,
  sf.sf_test_mode,
  sf.sf_ns_id,
  sf.sf_legacy_ns_id,
  sf.sf_ns_order_number,
  sf.sf_opportunity_id,
  sf.sf_quote_id,
  sf.sf_activated_date,

  -- ── NS fields ─────────────────────────────────────────
  ns.ns_document_number,
  ns.ns_transaction_id,
  ns.ns_transaction_date,
  ns.ns_transaction_status,
  ns.ns_transaction_amount,
  ns.ns_billing_account_id,
  ns.ns_customer_name,

  -- ── Amount variance (only meaningful when MATCHED) ────
  CASE
    WHEN sf.sf_total_amount IS NOT NULL AND ns.ns_transaction_amount IS NOT NULL
      THEN ROUND(ns.ns_transaction_amount - sf.sf_total_amount, 4)
  END AS amount_variance,

  -- ── Likely reason when SF ONLY ────────────────────────
  CASE
    WHEN ns.memo_norm IS NOT NULL THEN NULL  -- matched, no reason needed
    WHEN SAFE_CAST(sf.sf_skip_export AS BOOL) = true             THEN 'Skip export flag set'
    WHEN SAFE_CAST(sf.sf_test_mode   AS BOOL) = true             THEN 'Test mode record'
    WHEN SAFE_CAST(sf.sf_synced_flag AS BOOL) = false
     AND sf.sf_ns_id IS NULL
     AND sf.sf_legacy_ns_id IS NULL                              THEN 'Never synced to NS'
    WHEN SAFE_CAST(sf.sf_synced_flag AS BOOL) = true
     AND sf.sf_ns_id IS NULL                                     THEN 'Synced flag true but NS ID missing'
    ELSE                                                              'Unknown — investigate'
  END AS likely_reason

FROM sf_order sf
FULL OUTER JOIN ns_order ns
  ON LOWER(TRIM(sf.order_number)) = ns.memo_norm

ORDER BY record_status