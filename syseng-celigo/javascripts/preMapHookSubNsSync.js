function preMap(options) {
  // ---- Config ----
  var CONFIG = {
    AMOUNT_FIELD: 'amount',
    ID_FIELD: 'billing_account_id',
    SKIP_INVALID: false,
    MAX_LOG_DETAILS: 100,
    CONTROL_FIELDS: {
      recordCount: 'control_record_count',
      validRecords: 'control_valid_records',
      totalAmount: 'control_total_amount',
      hashTotal: 'control_hash_total',
      averageAmount: 'control_average_amount'
    }
  };

  // ---- Logging ----
  var DEBUG = true;
  function safeStringify(x) {
    try { return JSON.stringify(x, null, 2); } catch (e) { return String(x); }
  }
  function logDebug(msg, obj) {
    if (!DEBUG) return;
    try {
      if (typeof obj !== 'undefined') {
        console.log('[preMap:reconciliation] ' + msg + ' ' + safeStringify(obj));
      } else {
        console.log('[preMap:reconciliation] ' + msg);
      }
    } catch (e) { /* ignore */ }
  }

  // ---- Guardrails ----
  var resultEmpty = [];
  if (!options || !options.data || Object.prototype.toString.call(options.data) !== '[object Array]') {
    var errInvalid = { code: 'invalid_input', message: 'options.data must be an array', source: 'preMap' };
    if (options && options.errors && Object.prototype.toString.call(options.errors) === '[object Array]') {
      options.errors.push(errInvalid);
    }
    logDebug('ERROR invalid_input', errInvalid);
    return resultEmpty; // zero in, zero out
  }

  var input = options.data;
  var outErrors = (options.errors && Object.prototype.toString.call(options.errors) === '[object Array]') ? options.errors : null;

  logDebug('START', { recordCount: input.length });

  if (input.length === 0) {
    logDebug('No data provided');
    return resultEmpty; // zero in, zero out
  }

  // ---- Pass 1: compute control totals across valid records ----
  var recordCount = input.length;
  var validCount = 0;
  var totalAmount = 0;
  var hashTotal = 0;
  var invalidDetails = [];

  for (var i = 0; i < input.length; i++) {
    var rec = input[i] || {};
    var rawAmt = (typeof rec[CONFIG.AMOUNT_FIELD] !== 'undefined') ? rec[CONFIG.AMOUNT_FIELD] : 0;
    var amount = Number(rawAmt);
    var rawId = (typeof rec[CONFIG.ID_FIELD] !== 'undefined' && rec[CONFIG.ID_FIELD] !== null) ? String(rec[CONFIG.ID_FIELD]) : '';
    var id = rawId.trim();

    var isValid = !!id;
    if (isValid) {
      validCount += 1;
      totalAmount += amount;
      for (var j = 0; j < id.length; j++) {
        hashTotal += id.charCodeAt(j);
      }
    } else if (invalidDetails.length < CONFIG.MAX_LOG_DETAILS) {
      invalidDetails.push({
        index: i,
        recordId: id || 'N/A',
        amount: amount,
        reason: 'Missing/invalid ID'
      });
    }
  }

  var averageAmount = (validCount > 0) ? Number((totalAmount / validCount).toFixed(2)) : 0;
  var invalidCount = recordCount - validCount;

  // ---- Pass 2: build output shape (same length as input) ----
  var result = new Array(input.length);
  for (var k = 0; k < input.length; k++) {
    var src = input[k] || {};

    var amtRaw = (typeof src[CONFIG.AMOUNT_FIELD] !== 'undefined') ? src[CONFIG.AMOUNT_FIELD] : 0;
    var amt = Number(amtRaw);
    var idRaw = (typeof src[CONFIG.ID_FIELD] !== 'undefined' && src[CONFIG.ID_FIELD] !== null) ? String(src[CONFIG.ID_FIELD]) : '';
    var sid = idRaw.trim();

    var elemErrors = [];
    var rowValid = !!sid;

    if (!rowValid) {
      var err = {
        code: 'invalid_record',
        message: 'Record rejected: Missing/invalid ID (Index: ' + k + ', ID: ' + (sid || 'N/A') + ')',
        source: 'preMap'
      };
      elemErrors.push(err);
      if (outErrors) outErrors.push(err);
    }

    // clone src without spread (ES5)
    var outputRecord = {};
    for (var key in src) {
      if (Object.prototype.hasOwnProperty.call(src, key)) {
        outputRecord[key] = src[key];
      }
    }

    if (rowValid) {
      outputRecord[CONFIG.CONTROL_FIELDS.recordCount]   = recordCount;
      outputRecord[CONFIG.CONTROL_FIELDS.validRecords]  = validCount;
      outputRecord[CONFIG.CONTROL_FIELDS.totalAmount]   = Number(totalAmount.toFixed(2));
      outputRecord[CONFIG.CONTROL_FIELDS.hashTotal]     = hashTotal;
      outputRecord[CONFIG.CONTROL_FIELDS.averageAmount] = averageAmount;
    }

    result[k] = (elemErrors.length > 0) ? { data: outputRecord, errors: elemErrors } : { data: outputRecord };
  }

  // ---- Metrics ----
  var metrics = {
    recordCount: recordCount,
    validRecords: validCount,
    invalidRecords: invalidCount,
    totalAmount: Number(totalAmount.toFixed(2)),
    hashTotal: hashTotal,
    averageAmount: averageAmount,
    invalidDetails: invalidDetails
  };

  logDebug('METRICS', {
    recordCount: metrics.recordCount,
    validRecords: metrics.validRecords,
    invalidRecords: metrics.invalidRecords,
    totalAmount: metrics.totalAmount,
    hashTotal: metrics.hashTotal,
    averageAmount: metrics.averageAmount,
    invalidDetails: metrics.invalidDetails.slice(0, CONFIG.MAX_LOG_DETAILS)
  });

  if (outErrors) {
    outErrors.push({
      code: 'reconciliation_metrics',
      message: 'Reconciliation totals: ' + safeStringify(metrics),
      source: 'preMap'
    });
  }

  return result;
}
