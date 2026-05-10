-- Author  : Prabal Saha
-- Date    : 2026-04-16
-- Purpose : Seed dulcet-yew-246109.stripe.customer with 4 dummy rows so that
--           stripe_null_netsuite_customer_id_mapping_both.sql returns cleanly:
--             - 2 FIVETRAN rows  (whipping_intermittent, recorder_fairness)
--             - 2 RunCache rows  (run_cache_org_1, run_cache_org_2)
--
-- Pre-req : bq mk --dataset dulcet-yew-246109:stripe  (one-time, if dataset doesn't exist)
--
-- All 4 rows have no netsuite_customer_id in metadata → pass the final WHERE filter.
-- stripe.customer.id must match stripe_customer_id in accounts / account_billing_info.

CREATE OR REPLACE TABLE `dulcet-yew-246109`.`stripe`.`customer` AS
SELECT * FROM UNNEST([
  STRUCT(
    'cus_RfadXYmmo00fso'                    AS id,
    '{"fivetran_account_id":"accrue_dungeon"}' AS metadata,
    false                                    AS is_deleted,
    TIMESTAMP '2024-06-01 00:00:00'          AS created,
    false                                    AS _fivetran_deleted,
    CURRENT_TIMESTAMP()                      AS _fivetran_synced
  ),
  STRUCT(
    'cus_UDc8cZsk9jyb7X',
    '{"fivetran_account_id":"amplifier_jawless"}',
    false, TIMESTAMP '2024-06-01 00:00:00', false, CURRENT_TIMESTAMP()
  ),
  STRUCT(
    'rc_customer_1',
    '{"billing_profile_id":"external_run_cache_org_1"}',
    false, TIMESTAMP '2025-11-01 00:00:00', false, CURRENT_TIMESTAMP()
  ),
  STRUCT(
    'cus_UFbqk4yi9v18ld',
    '{"billing_profile_id":"onstage_cystic"}',
    false, TIMESTAMP '2026-01-10 00:00:00', false, CURRENT_TIMESTAMP()
  )
]);
