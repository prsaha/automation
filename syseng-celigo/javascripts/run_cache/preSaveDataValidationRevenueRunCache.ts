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
function preSavePage(options) {
  const validData = [];
  const errors = options.errors || [];

  options.data.forEach((record) => {
    const keyFields = [
      'external_id',
      'netsuite_customer_id',
      'item_id',
      'to_be_emailed',
      'transaction_type',
      'netsuite_amount',
      'netsuite_quantity'
    ];

    const missingFields = keyFields.filter(field =>
      record[field] === null || record[field] === undefined || record[field] === ''
    );

    if (missingFields.length > 0) {
      console.log(
        `Record rejected | billing_account_id: ${record.billing_account_id} | Missing fields: [${missingFields.join(', ')}]`
      );
      errors.push({
        record,
        message: `Missing required fields: [${missingFields.join(', ')}] for billing_account_id: ${record.billing_account_id}`,
        code: 'missing_fields',
        source: 'validation'
      });
      return; // skip this record
    }

    validData.push(record);
  });

  return {
    data: validData,
    errors: errors,
    abort: false,
    newErrorsAndRetryData: []
  };
}