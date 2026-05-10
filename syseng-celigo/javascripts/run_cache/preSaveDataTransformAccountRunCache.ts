function preSavePage(options) {
  const validData = [];
  const newErrors = options.errors || [];

  options.data.forEach((record, index) => {
    const billingIdInfo = record.billing_account_id
      ? ` (Billing Account ID: ${record.billing_account_id})`
      : '';

    // Validate required fields
    if (!record.billing_address) {
      newErrors.push({
        recordIndex: index,
        record,
        message: `Record rejected due to missing required fields: billing_address${billingIdInfo}`,
        code: 'missing_fields',
        source: 'validation'
      });
      return;
    }

    const cleanedRecord = { ...record };

    // Parse billing_address and extract the three target fields
    try {
      const addressObj = JSON.parse(record.billing_address);
      cleanedRecord.billing_email   = addressObj.email      || null;
      cleanedRecord.billing_country = addressObj.country    || null;
      cleanedRecord.billing_zip     = addressObj.postalCode || null;

      // ✅ Collect all missing fields first, then throw ONE fatal exception
      const missingFields = [];
      if (!cleanedRecord.billing_email)   missingFields.push('billing_email');
      if (!cleanedRecord.billing_country) missingFields.push('billing_country');
      if (!cleanedRecord.billing_zip)     missingFields.push('billing_zip');

      if (missingFields.length > 0) {
        throw new Error(
          `Fatal: missing or empty fields after parsing billing_address: [${missingFields.join(', ')}]${billingIdInfo}. Halting flow.`
        );
      }

      // Default legal_name to billing_email if null/undefined/empty
      if (!cleanedRecord.legal_name) {
        cleanedRecord.legal_name = cleanedRecord.billing_email;
      }

    } catch (error) {

      // Re-throw if it's our intentional fatal exception — halts entire Celigo flow
      if (error.message && error.message.startsWith('Fatal:')) {
        throw error; // 🛑 Stops the entire flow
      }

      // Otherwise treat as soft parse error — reject record, continue flow
      console.log('Error parsing billing_address:', error);
      newErrors.push({
        recordIndex: index,
        record,
        message: `Record rejected: failed to parse billing_address${billingIdInfo}`,
        code: 'invalid_billing_address',
        source: 'validation'
      });
      return;
    }

    validData.push(cleanedRecord);
  });

  return {
    data: validData,
    errors: newErrors,
    abort: false,
    newErrorsAndRetryData: []
  };
}