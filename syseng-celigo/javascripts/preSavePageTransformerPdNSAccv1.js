function preSavePage(options) {
  const validData = [];
  const newErrors = options.errors || [];

  const MARKETPLACE_PAYER_NAME_MAP = {
    'exist_calf': 'Snowflake Marketplace',
    'qua_canal': '1 Google Cloud Platform',
    'subjective_officially': 'Azure Marketplace',
    'repave_muck': 'AWS Marketplace',
    'playful_wonder': 'Softcat Plc.',
    'conversely_evening': 'Datum Studio (Partner)',
    'projecting_deformation': 'Tech Masters LLC (Partner)',
    'philanthropist_unashamed': 'Carahsoft (Partner)',
    'trimester_conjunctiva': 'S&E Cloud Experts Inc. (Partner)',
    'protecting_round': 'Biztory Group EMEA (Partner)',
    'glorification_frigate': 'Resultant (Partner)',
    'formation_interfering': 'Mantel Group (Partner)',
    'mosaic_overhand': 'CDW Corporation (Partner)',
    'isthmus_rebel': 'SHI International Corp. (Partner)',
    'verandah_creatable': 'DoIT International (Partner)',
    'seniority_explicitly': 'Cobry (Partner)',
    'localized_organised': 'Coforge FZ LLC',
    'accumulating_brace': 'CGI Nederland B.V. (Partner)',
    'councillors_expence': 'Bitekic [CREDODATA] (Partner)',
    'hereto_outboard': 'INSAITE SAPI DE CV (Partner)',
    'bid_alkali': 'Arctiq (Partner)',
    'undertook_pomp': 'megasoft IT GmbH & Co. KG (Partner)',
    'boondocks_thereof': 'SoftwareOne Deutschland GmbH (Partner)',
    'proofing_grasses': 'Triggo AI (Partner)',
    'spoonful_bagpipe': 'Kasmo Inc (Partner)',
    'fince_dedication': 'Cloud Mile Pte Ltd',
    'needy_float': 'Idea 11 (Partner)',
    'close_revoke': 'Presidio Global (Partner)',
    'peptide_amendment': 'Infinite Lambda (Singapore) Pte. Ltd. (Partner)',
    'stingray_solubility': 'Classmethod (Partner)',
    'remit_boiler': 'Promevo (Partner)',
    'laissez_milk': 'InterWorks GmbH (Partner)',
    'multitask_complimentary': 'Opkalla, Inc. (Partner)',
    'junkyard_scorch': 'K.K. Ashisuto (Partner)',
    'decidable_unfailing': 'Crayon Consulting (Partner)'

  };

  function parseAddress(addressStr, prefix) {
    const parsedData = {};
    try {
      const addressObj = JSON.parse(addressStr);

      // Transform state if it's "Ciudad Autónoma de Buenos Aires"
      if (addressObj.state === "Ciudad Autónoma de Buenos Aires") {
        addressObj.state = "Buenos Aires";
      }
      // Transform state if it's "Federal Territory of Kuala Lumpur" to "Kuala Lumpur"
      if (addressObj.state === "Federal Territory of Kuala Lumpur") {
        addressObj.state = "Kuala Lumpur";
      }

      Object.entries(addressObj).forEach(([key, value]) => {
        parsedData[`${prefix}_${key}`] = value;
      });

      const firstName = addressObj.firstName || '';
      const lastName = addressObj.lastName || '';
      const attentionValue = `${firstName} ${lastName}`.trim() || null;

      if (prefix === "billing") {
        parsedData["billaddress_attention"] = attentionValue;
      }
      if (prefix === "shipping") {
        parsedData["shipping_attention"] = attentionValue;
      }
    } catch (error) {
      console.log(`Error parsing ${prefix} address:`, error);
      if (prefix === "billing") {
        parsedData["billaddress_attention"] = null;
      }
      if (prefix === "shipping") {
        parsedData["shipping_attention"] = null;
      }
    }
    return parsedData;
  }
  // === Validation / Transform ===

  options.data.forEach((record, index) => {
    const missingFields = [];

    if (!record.billing_address) missingFields.push('billing_address');
    if (!record.shipping_address) missingFields.push('shipping_address');
    if (!record.legal_name || record.legal_name.trim() === "") missingFields.push('legal_name');
    if (!record.billing_account_id || record.billing_account_id.trim() === "") missingFields.push('billing_account_id');

    const billingIdInfo = record.billing_account_id ? ` (Billing Account ID: ${record.billing_account_id})` : '';
    const typeInfo = record.type ? ` (Type: ${record.type})` : '';

    if (missingFields.length > 0) {
      newErrors.push({
        recordIndex: index,
        record,
        message: `Record rejected due to missing required fields: ${missingFields.join(', ')}${billingIdInfo}${typeInfo}`,
        code: 'missing_fields',
        source: 'validation'
      });
      return;
    }

    const { billing_address, shipping_address, ...cleanedRecord } = record;

    Object.assign(cleanedRecord, parseAddress(billing_address, "billing"), parseAddress(shipping_address, "shipping"));

    cleanedRecord.legal_name = `${cleanedRecord.legal_name}`;
    cleanedRecord.salesrep = "";

    if (cleanedRecord.contract_type) {
      const typeLower = cleanedRecord.contract_type.toLowerCase();
      cleanedRecord.contract_type = typeLower === "sales_assisted" ? "Prepaid" : "Self-Service";
    }
    // === NEW: Validation for RESELLER payer type === 
    // https://fivetran.atlassian.net/browse/RD-1032530
    if (cleanedRecord.payer_type === 'RESELLER') {
      const billingId = (cleanedRecord.third_party_payer_id || '').trim();
      const hasMapping = !!MARKETPLACE_PAYER_NAME_MAP[billingId];
      if (!hasMapping) {
        newErrors.push({
          recordIndex: index,
          record,
          message: `Record rejected: RESELLER payer requires a mapped billing_account_id in MARKETPLACE_PAYER_NAME_MAP, but none was found for '${billingId}'.`,
          code: 'invalid_reseller_mapping',
          source: 'validation'
        });
        return; // fail validation for this record
      }
    }
    // === END NEW ===
    // ---- Email presence check (fail if null/empty) ----
    // https://fivetran.atlassian.net/browse/RD-1032530
    if (['Customer', 'Reseller'].includes(cleanedRecord.payer_type)) {
      const emailMissing = [];
      if (!cleanedRecord.billing_email) emailMissing.push('billing_email missing');
      if (!cleanedRecord.shipping_email) emailMissing.push('shipping_email missing');

      if (emailMissing.length) {
        newErrors.push({
          recordIndex: index,
          record,
          message: `Record rejected: ${emailMissing.join('; ')}`,
          code: 'missing_email',
          source: 'validation'
        });
        return;
      }
    }
    const partnerName = MARKETPLACE_PAYER_NAME_MAP[cleanedRecord.third_party_payer_id] || null;
    cleanedRecord.partner = partnerName;
    cleanedRecord.is_partner = (partnerName && ["MARKETPLACE", "RESELLER_MARKETPLACE"].includes(cleanedRecord.payer_type)) ? "true" : "false"; //RD-1014133 and RD-1000703

    validData.push(cleanedRecord);
  });

  return {
    data: validData,
    errors: newErrors,
    abort: false,
    newErrorsAndRetryData: []
  };
}