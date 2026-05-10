// Author: Prabal Saha
// Height - https://fivetran.height.app/T-894723
// Description: This code is a pre-save transformation function for a data pipeline.
// It processes incoming data records, specifically focusing on billing and shipping address fields.
// The function flattens these address fields into individual key-value pairs,
// handles special cases for concatenating names, and transforms contract types.
// It also includes error handling for JSON parsing and ensures that the original address fields are removed from the final output.

// This function is designed to be used in a data transformation pipeline, such as Fivetran or similar ETL tools.
// It processes incoming data records, specifically focusing on billing and shipping address fields.
// The function flattens these address fields into individual key-value pairs,
// handles special cases for concatenating names, and transforms contract types.
// It also includes error handling for JSON parsing and ensures that the original address fields are removed from the final output. 



function preSavePage(options) {
  options.data = options.data.map(record => {
    // Helper function to flatten address fields
    function parseAddress(addressStr, prefix) {
      let parsedData = {};
      try {
        let addressObj = JSON.parse(addressStr);
        Object.keys(addressObj).forEach(key => {
          parsedData[`${prefix}_${key}`] = addressObj[key]; // Dynamically add prefixed keys
        });

        // Special handling for billing name + last name concatenation
        if (prefix === "billing") {
          parsedData["billaddress_attention"] = `${addressObj.firstName} ${addressObj.lastName}`.trim();
        }

        // Special handling for shipping name + last name concatenation
        if (prefix === "shipping") {
          parsedData["shipping_attention"] = `${addressObj.firstName} ${addressObj.lastName}`.trim();
        }
      } catch (error) {
        console.log(`Error parsing ${prefix} address:`, error);
      }
      return parsedData;
    }

    // Flatten billing and shipping addresses
    let billingData = parseAddress(record.billing_address, "billing");
    let shippingData = parseAddress(record.shipping_address, "shipping");

    // Remove original billing_address and shipping_address fields
    let { billing_address, shipping_address, ...cleanedRecord } = record;

    // Special handling for legal_name → Append "_decoupling_unit_test"
     if (cleanedRecord.legal_name) {
        cleanedRecord.legal_name = `${cleanedRecord.legal_name}_decoupling`;
      }
    // Add a new element called salesrep
    cleanedRecord.salesrep = "";
    
     // Contract Type Transformation Logic
    if (cleanedRecord.contract_type) {
      let contractTypeLower = cleanedRecord.contract_type.toLowerCase();
      cleanedRecord.contract_type = contractTypeLower === "sales_assisted" ? "Prepaid" : "Self-Service";
    }

    return {
      ...cleanedRecord, // Retain existing fields except billing_address and shipping_address
      ...billingData,    // Add extracted billing fields
      ...shippingData    // Add extracted shipping fields
    };
  });

  return {
    data: options.data,
    errors: options.errors,
    abort: false,
    newErrorsAndRetryData: []
  };
}