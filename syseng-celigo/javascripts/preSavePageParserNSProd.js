/*
* preSavePageFunction stub:
*
* The name of the function can be changed to anything you like.
*
* The function will be passed one 'options' argument that has the following fields:
*   'data' - an array of records representing one page of data. A record can be an object {} or array [] depending on the data source.
*   'files' - file exports only. files[i] contains source file metadata for data[i]. i.e. files[i].fileMeta.fileName.
*   'errors' - an array of errors where each error has the structure {code: '', message: '', source: '', retryDataKey: ''}.
*   'retryData' - a dictionary object containing the retry data for all errors: {retryDataKey: { data: <record>, stage: '', traceKey: ''}}.
*   '_exportId' - the _exportId currently running.
*   '_connectionId' - the _connectionId currently running.
*   '_flowId' - the _flowId currently running.
*   '_integrationId' - the _integrationId currently running.
*   '_apiId' - the _apiId currently running.
*   '_parentIntegrationId' - the parent of the _integrationId currently running.
*   'pageIndex' - 0 based. context is the batch export currently running.
*   'lastExportDateTime' - delta exports only.
*   'currentExportDateTime' - delta exports only.
*   'settings' - all custom settings in scope for the export currently running.
*   'sandbox' - boolean value indicating whether the script is invoked for sandbox.
*   'testMode' - boolean flag indicating test mode and previews.
*   'job' - the job currently running.
*
* The function needs to return an object that has the following fields:
*   'data' - your modified data.
*   'errors' - your modified errors.
*   'abort' - instruct the batch export currently running to stop generating new pages of data.
*   'newErrorsAndRetryData' - return brand new errors linked to retry data: [{retryData: <record>, errors: [<error>]}].
* Throwing an exception will signal a fatal error and stop the flow.
*/
/* eslint-env es6 */
/* jshint esversion: 9 */
/* Author : Prabal Saha */

function preSavePage(options) {
  function cleanValue(value) {
    return (value === null || value === undefined || value.toString().trim() === "" || value.toString().trim() === ".00") ? "0.00" : value;
  }

  function determineInvoiceType(itemValue) {
    if (!itemValue) return "Overage";

    const lowerItemValue = itemValue.toLowerCase();

    if (lowerItemValue.includes("prepaid") || lowerItemValue.includes("services")) {
      return "Prepaid";
    } else if (lowerItemValue.includes("evergreen")) {
      return "Self Service";
    } else {
      return "Overage";
    }
  }

  const fieldsToClean = [
    "Amount Trxn Currency",
    "Amount Remaining Trxn Currency",
    "Amount Paid Trxn Currency",
    "ATT Amount Paid",
    "ATT Amount Remaining",
    "ATT Amount",
    "ATL Amount"
  ];

  const cleanedData = options.data.map(item => {
    const cleanedItem = { ...item };

    // Clean fields
    fieldsToClean.forEach(field => {
      if (field in cleanedItem) {
        cleanedItem[field] = cleanValue(cleanedItem[field]);
      }
    });

    // Add Invoice Type only if Type is Invoice
    const typeValue = cleanedItem["Type"];
    const itemValue = cleanedItem["Item"];

    if (typeValue && typeValue.toLowerCase() === "invoice") {
      cleanedItem["Invoice Type"] = determineInvoiceType(itemValue);
    }

    return cleanedItem;
  });

  return {
    data: cleanedData,
    errors: options.errors,
    abort: false,
    newErrorsAndRetryData: []
  };
}
