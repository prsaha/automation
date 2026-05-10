-- =================================================================================
-- CONFIGURATION SECTION
-- =================================================================================
DECLARE run_mode STRING DEFAULT 'ACCOUNT'; -- Options: 'DATE' or 'ACCOUNT'

-- Mode 1: Date Settings
DECLARE filter_start_date TIMESTAMP DEFAULT TIMESTAMP('2025-12-01 00:00:00');
DECLARE filter_end_date   TIMESTAMP DEFAULT TIMESTAMP('2026-01-02 00:00:00');

-- Mode 2: Account ID Settings
DECLARE filter_account_ids ARRAY<STRING> DEFAULT [
  'inconvenience_poetic',
  'merry_manifesting',
  'goofy_eloquent',
  'domination_mango',
  'flavorful_accord',
  'unfitted_lid',
  'upcountry_biting',
  'landlady_nomenclature',
  'scorched_sickle',
  'barrel_skimming',
  'tricycle_anything',
  'reparation_subvert',
  'latest_followed'
];
-- =================================================================================

WITH latest_subscriptions AS (
  SELECT  
    *,
    LOWER(TRIM(SAFE_CAST(order_number AS STRING))) AS order_number_norm,
    COALESCE(
      CASE
        WHEN payer_type IN ('RESELLER', 'MARKETPLACE', 'RESELLER_MARKETPLACE') THEN third_party_payer_id 
        ELSE NULL
      END,
      billing_account_id
    ) AS payer_account_id
  FROM
    `digital-arbor-400.pg_public.subscriptions`
  WHERE
    NOT _fivetran_deleted
    AND NOT is_evergreen

    -- *** DYNAMIC FILTERING LOGIC ***
    AND (
      -- MODE 1: DATE MODE
      (
        run_mode = 'DATE'
        AND created_at >= filter_start_date
        AND created_at <  filter_end_date
      )
      OR
      -- MODE 2: ACCOUNT MODE
      (
        run_mode = 'ACCOUNT'
        AND billing_account_id IN UNNEST(filter_account_ids)
        -- Optional: Keep a global safety date if needed, otherwise remove next line
        AND created_at >= TIMESTAMP('2025-06-15 00:00:00') 
      )
    )

  QUALIFY ROW_NUMBER() OVER (
      PARTITION BY salesforce_id 
      ORDER BY version DESC 
  ) = 1  
),

-- --- NETSUITE LOOKUP ---
ns_so AS (
  SELECT
    document_number,
    transaction_date,
    LOWER(TRIM(SAFE_CAST(transaction_memo AS STRING))) AS memo_norm
  FROM `private-internal.transforms_bi.netsuite_transaction_details`
  WHERE transaction_type = 'Sales Order'
),

ns_first AS (
  SELECT
    memo_norm,
    ARRAY_AGG(STRUCT(document_number, transaction_date)
              ORDER BY transaction_date ASC LIMIT 1)[OFFSET(0)] AS first_so
  FROM ns_so
  GROUP BY memo_norm
),

joined_data AS (
  SELECT
    ls.*,
    nf.first_so.document_number AS netsuite_sales_order_number,
    nf.first_so.transaction_date AS netsuite_sales_order_date,
    acct.status AS account_status,
    acct.freeze_reason,
    acct.platform_tier,
    
    CASE 
      WHEN ls.payer_type IN ('RESELLER', 'MARKETPLACE', 'RESELLER_MARKETPLACE') THEN acct_payer.billing_address
      ELSE acct_customer.billing_address
    END AS billing_address_json,
    acct_customer.shipping_address AS shipping_address_json,

    CASE 
      WHEN ls.payer_type IN ('RESELLER', 'MARKETPLACE', 'RESELLER_MARKETPLACE') THEN acct_payer.legal_name
      ELSE acct_customer.legal_name
    END AS legal_name,

    CASE 
      WHEN ls.payer_type IN ('RESELLER', 'MARKETPLACE', 'RESELLER_MARKETPLACE') THEN acct_payer.tax_id
      ELSE acct_customer.tax_id
    END AS tax_id,

    CASE UPPER(ls.payer_type)
      WHEN 'CUSTOMER' THEN 'Customer'
      WHEN 'RESELLER' THEN 'Reseller'
      WHEN 'MARKETPLACE' THEN 'Marketplace'
      WHEN 'RESELLER_MARKETPLACE' THEN 'Reseller_Marketplace'
      ELSE ls.payer_type
    END AS normalized_payer_type

  FROM
    latest_subscriptions ls
  LEFT JOIN ns_first nf ON ls.order_number_norm = nf.memo_norm
  LEFT JOIN `digital-arbor-400.pg_public.accounts` acct
    ON ls.billing_account_id = acct.id
    AND NOT acct._fivetran_deleted
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
    -- Note: Removed the redundant billing_account_id filter here. 
    -- Filtering is now fully handled in the first CTE based on the mode.
),

enriched_data AS (
  SELECT 
    *,
    JSON_VALUE(billing_address_json, '$.firstName') AS billing_firstName,
    JSON_VALUE(billing_address_json, '$.lastName') AS billing_lastName,
    JSON_VALUE(shipping_address_json, '$.firstName') AS shipping_firstName,
    JSON_VALUE(shipping_address_json, '$.lastName') AS shipping_lastName,
    SAFE_DIVIDE(amount, product_quantity) AS rate,
    
    CASE TRIM(third_party_payer_id)
      WHEN 'exist_calf' THEN 'Snowflake Marketplace'
      WHEN 'qua_canal' THEN '1 Google Cloud Platform'
      WHEN 'subjective_officially' THEN 'Azure Marketplace'
      WHEN 'repave_muck' THEN 'AWS Marketplace'
      WHEN 'playful_wonder' THEN 'Softcat Plc.'
      WHEN 'conversely_evening' THEN 'Datum Studio (Partner)'
      WHEN 'projecting_deformation' THEN 'Tech Masters LLC (Partner)'
      WHEN 'philanthropist_unashamed' THEN 'Carahsoft (Partner)'
      WHEN 'trimester_conjunctiva' THEN 'S&E Cloud Experts Inc. (Partner)'
      WHEN 'protecting_round' THEN 'Biztory Group EMEA (Partner)'
      WHEN 'glorification_frigate' THEN 'Resultant (Partner)'
      WHEN 'formation_interfering' THEN 'Mantel Group (Partner)'
      WHEN 'mosaic_overhand' THEN 'CDW Corporation (Partner)'
      WHEN 'isthmus_rebel' THEN 'SHI International Corp. (Partner)'
      WHEN 'verandah_creatable' THEN 'DoIT International (Partner)'
      WHEN 'seniority_explicitly' THEN 'Cobry (Partner)'
      WHEN 'localized_organised' THEN 'Coforge FZ LLC'
      WHEN 'accumulating_brace' THEN 'CGI Nederland B.V. (Partner)'
      WHEN 'councillors_expence' THEN 'Bitekic [CREDODATA] (Partner)'
      WHEN 'hereto_outboard' THEN 'INSAITE SAPI DE CV (Partner)'
      WHEN 'bid_alkali' THEN 'Arctiq (Partner)'
      WHEN 'undertook_pomp' THEN 'megasoft IT GmbH & Co. KG (Partner)'
      WHEN 'boondocks_thereof' THEN 'SoftwareOne Deutschland GmbH (Partner)'
      WHEN 'proofing_grasses' THEN 'Triggo AI (Partner)'
      WHEN 'spoonful_bagpipe' THEN 'Kasmo Inc (Partner)'
      WHEN 'fince_dedication' THEN 'Cloud Mile Pte Ltd'
      WHEN 'needy_float' THEN 'Idea 11 (Partner)'
      WHEN 'close_revoke' THEN 'Presidio Global (Partner)'
      WHEN 'peptide_amendment' THEN 'Infinite Lambda (Singapore) Pte. Ltd. (Partner)'
      WHEN 'stingray_solubility' THEN 'Classmethod (Partner)'
      WHEN 'remit_boiler' THEN 'Promevo (Partner)'
      WHEN 'laissez_milk' THEN 'InterWorks GmbH (Partner)'
      WHEN 'multitask_complimentary' THEN 'Opkalla, Inc. (Partner)'
      WHEN 'junkyard_scorch' THEN 'K.K. Ashisuto (Partner)'
      WHEN 'decidable_unfailing' THEN 'Crayon Consulting (Partner)'
      WHEN 'stride_galloping' THEN 'Climb Channel Solutions (Partner)'
      WHEN 'hastening_unwoven' THEN 'Data France (Partner)'
      WHEN 'sidewalk_journeyed' THEN 'United Resources Global Enterprise LLP (Partner)'
      WHEN 'burns_alternation' THEN 'Prenax Denmark, filial af Prenax AB'
      WHEN 'warmed_salted' THEN 'Ahead, Inc (Partner)'
      WHEN 'fibrin_mutable' THEN 'SFEIR (Partner)'
      WHEN 'prevention_impulse' THEN 'Interworks (Partner)'
      WHEN 'joined_bushes' THEN 'Aion-Tech Solutions Limited (Partner)'
      WHEN 'opaque_auxiliaries' THEN 'Infosys EMEA (GSI)'
      WHEN 'payroll_key' THEN 'Keyrus (Partner)'
      WHEN 'trumpet_viewing' THEN 'Civica Software (Partner)'
      WHEN 'neutralize_apple' THEN 'Protinus IT (Partner)'
      WHEN 'backing_ache' THEN 'Interloop.ai (Partner)'
      WHEN 'exercise_intensely' THEN 'SADA Systems Inc. (Partner)'
      WHEN 'together_cities' THEN 'Exture Inc (Partner)'
      WHEN 'tunic_elusive' THEN 'GOPOMELO X COMPANY LIMITED (Partner)'
      WHEN 'dazzling_resistance' THEN 'Tech Mahindra Global (GSI)'
      WHEN 'refreshment_baby' THEN 'Cloocus APAC (Partner)'
      WHEN 'occupied_rambling' THEN 'SoftwareOne UK Ltd (Partner)'
      WHEN 'unmanaged_pacemaker' THEN 'Accenture UK (GSI) (Partner)'
      WHEN 'presentment_hacking' THEN 'Capgemini NAMER (GSI)'
      WHEN 'direct_recharger' THEN 'Preferred Strategies, Inc. d/b/a QuickLaunch Analytics (Partner)'
      WHEN 'hereto_primer' THEN 'Tarento Technologies Pvt Limited (Partner)'
      WHEN 'jiffy_lullaby' THEN 'SEIDOR ANALYTICS NORTH AMERICA CORP(Partner)'
      WHEN 'inflated_shrouded' THEN 'ACCEND NETWORKS INC (Partner)'
      WHEN 'cypress_idly' THEN 'Advanced Chippewa Technologies Incorporated (Partner)'
      WHEN 'independently_sea' THEN 'Berca Hardaya Perkasa (Partner)'
      WHEN 'recognise_usurp' THEN 'World Wide Technology, LLC (Partner)'
      WHEN 'cordiality_repugnance' THEN 'AXI nv (Partner)'
      WHEN 'artful_southwest' THEN 'element61 NV/SA'
      WHEN 'penance_traceable' THEN 'Edgematics (Partner)'
      WHEN 'lot_grist' THEN 'Matrix IT Ltd (Partner)'
      WHEN 'snow_mit' THEN 'Devoteam EMEA (Partner)'
      WHEN 'heavenly_helplessly' THEN 'HITACHI SOLUTIONS EAST JAPAN, LTD. (Partner)'
      WHEN 'acquirements_engraved' THEN 'Bechtle Ltd (Partner)'
      WHEN 'repugnance_lump' THEN 'Intellection Corporation (Partner)'
      WHEN 'estrangement_preliminaries' THEN 'SCC FRANCE (Partner)'
      WHEN 'disc_swim' THEN 'BlueShift Brasil (Partner)'
      WHEN 'notified_spent' THEN 'CTCSP Corporation (Partner)'
      WHEN 'printer_dazzled' THEN 'Fujitsu Limited 富士通株式会社 (Partner)'
      ELSE NULL
    END AS partner_name,

    COALESCE(contract_start_date, start_date_utc) AS effective_start,
    COALESCE(contract_end_date, end_date_utc) AS effective_end

  FROM joined_data
),

logic_application AS (
  SELECT
    *,
    CASE 
      WHEN effective_end < effective_start THEN 0
      ELSE 
        DATE_DIFF(DATE(effective_end), DATE(effective_start), MONTH) + 
        CASE WHEN EXTRACT(DAY FROM effective_end) > EXTRACT(DAY FROM effective_start) THEN 1 ELSE 0 END
    END AS term_months,

    SUM(amount) OVER (PARTITION BY order_number) AS order_total_amount

  FROM enriched_data
),

final_calculations AS (
  SELECT
    *,
    CONCAT(COALESCE(billing_firstName, ''), ' ', COALESCE(billing_lastName, '')) AS billing_attention,
    CONCAT(COALESCE(shipping_firstName, ''), ' ', COALESCE(shipping_lastName, '')) AS shipping_attention,

    CASE 
      WHEN product_code IN ('ELA-On-Prem-Only', 'HVR-57', 'HVR-61') THEN
        CASE 
          WHEN term_months <= 17 THEN 'Y1'
          WHEN term_months <= 29 THEN 'Y2'
          ELSE 'Y3'
        END
      ELSE NULL 
    END AS term_band,
    
    (partner_name IS NOT NULL AND normalized_payer_type IN ('Reseller_Marketplace', 'Marketplace')) AS is_partner

  FROM logic_application
),

calculations_extended AS (
  SELECT 
    *,
    CASE 
      WHEN product_code = 'ELA-On-Prem-Only' AND term_band = 'Y1' THEN 17957
      WHEN product_code = 'ELA-On-Prem-Only' AND term_band = 'Y2' THEN 17958
      WHEN product_code = 'ELA-On-Prem-Only' AND term_band = 'Y3' THEN 17959
      WHEN product_code = 'HVR-57' AND term_band = 'Y1' THEN 17961
      WHEN product_code = 'HVR-57' AND term_band = 'Y2' THEN 17962
      WHEN product_code = 'HVR-57' AND term_band = 'Y3' THEN 17963
      WHEN product_code = 'HVR-61' AND term_band = 'Y1' THEN 17964
      WHEN product_code = 'HVR-61' AND term_band = 'Y2' THEN 17965
      WHEN product_code = 'HVR-61' AND term_band = 'Y3' THEN 17966
      
      WHEN product_code IN (
        'Census_X_Sell_Avenue_Plan', 'Census_X_Sell_Business_Plan', 'Census_X_Sell_Core_Plan',
        'Census_X_Sell_Embedded_Plan', 'Census_X_Sell_Grow_Plan', 'Census_X_Sell_Growth_Plan',
        'Census_X_Sell_Platform_Plan', 'Census_X_Sell_Scale_Plan', 'Census_X_Sell_Startup_Plan'
      ) THEN 18037
      ELSE NULL
    END AS product_code_branding,

    CASE 
      WHEN product_code IN (
        'ELA-Cloud-Only', 'ELA-Cloud-Plus-On-Prem', 'ELA-On-Prem-Only', 'PD-private_deployment',
        '1000', 'HVR-57', 'HVR-61', 'CLDW', 'HVR5.7_Extended_Support', 'HVR5.7_Extended_Support_Only',
        'HVR-Gold-Support', 'HVR_Perpetual_License_Extended_Support', 'HVR_Perpetual_License_Extended_Support_Only',
        'Premium_Support', 'US Only Support', 'Census-X-Sell-Pro', 'Census-X-Sell-Enterprise',
        'Census_X_Sell_Enterprise_Lite_Plan'
      ) THEN COALESCE(contract_start_date, start_date_utc)
      ELSE COALESCE(start_date_utc, contract_start_date)
    END AS rr_start_date,
    
    CASE 
      WHEN product_code IN (
        'ELA-Cloud-Only', 'ELA-Cloud-Plus-On-Prem', 'ELA-On-Prem-Only', 'PD-private_deployment',
        '1000', 'HVR-57', 'HVR-61', 'CLDW', 'HVR5.7_Extended_Support', 'HVR5.7_Extended_Support_Only',
        'HVR-Gold-Support', 'HVR_Perpetual_License_Extended_Support', 'HVR_Perpetual_License_Extended_Support_Only',
        'Premium_Support', 'US Only Support', 'Census-X-Sell-Pro', 'Census-X-Sell-Enterprise',
        'Census_X_Sell_Enterprise_Lite_Plan'
      ) THEN COALESCE(contract_end_date, end_date_utc)
      ELSE COALESCE(end_date_utc, contract_end_date)
    END AS rr_end_date

  FROM final_calculations
),

validation_layer AS (
  SELECT
    *,
    ARRAY_TO_STRING([
      -- 1. Required Fields Check
      CASE WHEN billing_address_json IS NULL THEN 'Missing billing_address' END,
      CASE WHEN shipping_address_json IS NULL THEN 'Missing shipping_address' END,
      CASE WHEN TRIM(COALESCE(legal_name, '')) = '' THEN 'Missing legal_name' END,
      CASE WHEN TRIM(COALESCE(billing_account_id, '')) = '' THEN 'Missing billing_account_id' END,

      -- 2. Reseller Check
      CASE WHEN normalized_payer_type = 'Reseller' AND partner_name IS NULL 
           THEN 'Invalid Reseller Mapping' 
      END,

      -- 3. Zero Total Check
      CASE WHEN order_total_amount = 0 THEN 'Zero Total Order' END,

      -- 4. Banding/Lookup Check
      CASE 
        WHEN product_code IN ('ELA-On-Prem-Only', 'HVR-57', 'HVR-61') AND product_code_branding IS NULL 
        THEN CONCAT('Missing Banding Lookup: ', product_code)
      END,

      -- 5. Account/Contract Checks
      CASE WHEN termination_date_utc IS NOT NULL THEN 'Subscription Terminated' END,
      CASE WHEN contract_end_date IS NOT NULL AND DATE(contract_end_date) < CURRENT_DATE THEN 'Contract Expired' END,
      CASE WHEN account_status NOT IN ('Customer', 'Frozen', 'Partner') AND type != 'CENSUS_X_SELL' THEN CONCAT('Invalid Account Status: ', COALESCE(account_status, 'NULL')) END,
      CASE WHEN freeze_reason = 'TRIAL_EXPIRED' THEN 'Account Frozen (Trial Expired)' END,
      CASE WHEN platform_tier IN ('Free_2024', 'Free_2022') THEN CONCAT('Invalid Platform Tier: ', platform_tier) END

    ], '; ') AS validation_error_message

  FROM calculations_extended
),

final_output AS (
  SELECT 
    * EXCEPT(effective_start, effective_end, order_number_norm),
    CASE 
      WHEN validation_error_message IS NOT NULL AND validation_error_message <> '' THEN 'INVALID'
      ELSE 'VALID'
    END AS validation_status,
    
    CASE
      WHEN validation_error_message LIKE '%Missing billing_address%' 
        OR validation_error_message LIKE '%Missing shipping_address%' 
        OR validation_error_message LIKE '%Missing legal_name%'
        THEN 'Data Quality Issue (Addresses/Names)'
      WHEN validation_error_message LIKE '%Invalid Account Status%' 
        OR validation_error_message LIKE '%Account Frozen%' 
        OR validation_error_message LIKE '%Subscription Terminated%'
        OR validation_error_message LIKE '%Contract Expired%'
        THEN 'Account Eligibility Issue'
      WHEN validation_error_message LIKE '%Zero Total Order%' 
        OR validation_error_message LIKE '%Invalid Reseller Mapping%'
        THEN 'Business Logic Failure'
      WHEN validation_error_message LIKE '%Missing Banding Lookup%' 
        OR validation_error_message LIKE '%Invalid Platform Tier%'
        THEN 'Product Configuration Issue'
      WHEN validation_error_message IS NOT NULL AND validation_error_message <> ''
        THEN 'Other Validation Error'
      ELSE NULL
    END AS rejection_category
  FROM validation_layer
)

SELECT * FROM final_output
WHERE validation_status in ('INVALID')
ORDER BY id ASC