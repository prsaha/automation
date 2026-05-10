/**
 * @NApiVersion 2.x
 * @NScriptType MapReduceScript
 * @NModuleScope SameAccount
 *
 * -----------------------------------------------------------------------------
 * PURPOSE (one-off/backfill):
 *   For every ACTIVE customer with a Sales Rep who has an email:
 *     • Ensure a Contact exists under the customer for the Sales Rep’s email
 *     • Set "Create Dunning Recipient" = T on that Contact
 *     • Create/Update the Level 3 (internal) Dunning Recipient to that Contact
 *     • Stamp Contact/Dunning Recipient Update Date on the Customer
 *
 * PARAMS:
 *   custscript_ft_script_self_service (Free-form text)
 *     – Self-service email to exclude (owner recipients NOT created for this email)
 *   custscript_ft_rep_dunning_level_id (List/ID)
 *     – Dunning Level value used to detect owner/level-3 in existing recipients
 * -----------------------------------------------------------------------------
 */

define(['N/search','N/record','N/runtime'], function(search, record, runtime) {

  /* -------------------- Utils -------------------- */
  function normEmail(s){ return (s||'').toString().trim().toLowerCase(); }

  function stampCustomer(custId, msg){
    var values = {
      'custentity_ft_dunning_rec_update_date': new Date()
    };
    if (msg === '') values['custentity_ft_dunning_rec_aut_error'] = '';
    if (msg && msg.length) values['custentity_ft_dunning_rec_aut_error'] = msg;
    record.submitFields({
      type: record.Type.CUSTOMER,
      id: custId,
      values: values,
      options: { enableSourcing:false, ignoreMandatoryFields:true }
    });
  }

  /* -------------------- Contacts -------------------- */
  // Ensure a Contact exists on the customer for the given internal (rep) email.
  // Turns ON the "Create Dunning Recipient" flag.
  function ensureRepContact(custId, repEmail){
    repEmail = normEmail(repEmail);
    if(!repEmail) return null;

    var s = search.create({
      type: 'contact',
      filters: [['customer.internalid','anyof',custId]],
      columns: ['internalid','email']
    });

    var existingByEmail = {};
    s.run().each(function(r){
      existingByEmail[normEmail(r.getValue('email'))] = r.getValue('internalid');
      return true;
    });

    var existingId = existingByEmail[repEmail] || null;
    if (existingId){
      record.submitFields({
        type: record.Type.CONTACT,
        id: existingId,
        values: { 'custentity_ft_create_dunning_receipient': true },
        options: { enableSourcing:false, ignoreMandatoryFields:true }
      });
      return existingId;
    }

    var rec = record.create({ type: record.Type.CONTACT, isDynamic:true });
    rec.setValue({ fieldId:'entityid', value: repEmail });
    rec.setValue({ fieldId:'company',  value: custId   });
    rec.setValue({ fieldId:'email',    value: repEmail });
    rec.setValue({ fieldId:'custentity_ft_create_dunning_receipient', value:true });
    // Optional: set an internal category if you want (e.g., 1)
    // rec.setValue({ fieldId:'custentity_ft_dunning_contact_category', value: 1 });
    return rec.save();
  }

  /* -------------------- Dunning helpers -------------------- */
  function findExistingDunningDetails(custId){
    var scriptObj = runtime.getCurrentScript();
    var repDunLevel = scriptObj.getParameter({ name: 'custscript_ft_rep_dunning_level_id' });

    var s = search.create({
      type: 'customer',
      filters: [
        ['internalidnumber','equalto', custId], 'AND',
        ['custrecord_3805_dunning_recipient_cust.internalid','noneof','@NONE@']
      ],
      columns: [
        search.createColumn({ name: 'internalid' }),
        search.createColumn({ name: 'custrecord_3805_dunning_recipient_cont', join: 'CUSTRECORD_3805_DUNNING_RECIPIENT_CUST' }),
        search.createColumn({ name: 'custrecord_dl_recipient_email', join: 'CUSTRECORD_3805_DUNNING_RECIPIENT_CUST' }),
        search.createColumn({ name: 'custrecord_dl_dunning_level_recipients', join: 'CUSTRECORD_3805_DUNNING_RECIPIENT_CUST' }),
        search.createColumn({ name: 'internalid', join: 'CUSTRECORD_3805_DUNNING_RECIPIENT_CUST' })
      ]
    });

    var ownerDunningId = null;
    s.run().each(function(r){
      var level = r.getValue({ name:'custrecord_dl_dunning_level_recipients', join:'CUSTRECORD_3805_DUNNING_RECIPIENT_CUST' });
      if(level == repDunLevel){
        ownerDunningId = r.getValue({ name:'internalid', join:'CUSTRECORD_3805_DUNNING_RECIPIENT_CUST' });
        return false;
      }
      return true;
    });
    return { salesRepdunning: ownerDunningId };
  }

  function upsertOwnerDunningRecipient(custId, ownerContactId, ownerEmail){
    var scriptObj = runtime.getCurrentScript();
    var selfServ = normEmail(scriptObj.getParameter({ name:'custscript_ft_script_self_service' }));
    var repOk = ownerContactId && ownerEmail && normEmail(ownerEmail) !== selfServ;

    var dd = findExistingDunningDetails(custId);
    var existingOwnerDunId = dd.salesRepdunning;
    var updatedId;

    if (repOk){
      if (existingOwnerDunId){
        var rec = record.load({ type:'customrecord_3805_dunning_recipient', id: existingOwnerDunId });
        rec.setValue({ fieldId:'custrecord_3805_dunning_recipient_cont', value: ownerContactId });
        updatedId = rec.save();
      } else {
        var rec3 = record.create({ type:'customrecord_3805_dunning_recipient', isDynamic:true });
        rec3.setValue({ fieldId:'custrecord_3805_dunning_recipient_cust', value: custId });
        rec3.setValue({ fieldId:'custrecord_3805_dunning_recipient_cont', value: ownerContactId });
        rec3.setValue({ fieldId:'custrecord_dl_dunning_level_recipients', value: 3 });
        updatedId = rec3.save();
      }
    } else if (existingOwnerDunId){
      // Inactivate if not valid (e.g., self-service or missing)
      record.submitFields({
        type:'customrecord_3805_dunning_recipient',
        id: existingOwnerDunId,
        values: { inactive:true, 'custrecord_3805_dunning_recipient_cust':'' },
        options: { enableSourcing:false, ignoreMandatoryFields:true }
      });
    }

    if (updatedId){
      var custRec = record.load({ type: record.Type.CUSTOMER, id: custId });
      custRec.setValue({ fieldId:'custentity_ft_dunning_rep_dunning_rec_cr', value:false });
      custRec.setValue({ fieldId:'custentity_ft_dunning_rec_aut_error', value:'' });
      custRec.setValue({ fieldId:'custentity_ft_dunning_rec_update_date', value:new Date() });
      custRec.save();
    } else {
      // still stamp the update date (no error)
      stampCustomer(custId, '');
    }
  }

/* -------------------- MR: getInputData -------------------- */
  function getInputData(){
    // Pull ALL active customers with a Sales Rep (and Sales Rep email present)
    var s = search.create({
      type: 'customer',
      filters: [
        ['isinactive','is','F'], 'AND',
        ['salesrep','noneof','@NONE@'], 'AND',
        ['salesrep.email','isnotempty','']   // ensure the rep has an email
      ],
      columns: [
        search.createColumn({ name:'internalid' }),
        search.createColumn({ name:'salesrep' }),
        search.createColumn({ name:'email', join:'salesRep' }) // rep email
      ]
    });

    var paged = s.runPaged({ pageSize: 1000 });
    var out = [];
    log.audit('Customer Search', 'Total active customers with Sales Rep: ' + paged.count);

    paged.pageRanges.forEach(function(range){
      var page = paged.fetch({ index: range.index });
      page.data.forEach(function(r){
        out.push({
          custId: r.getValue({ name:'internalid' }),
          salesRepId: r.getValue({ name:'salesrep' }),
          salesRepEmail: normEmail(r.getValue({ name:'email', join:'salesRep' }))
        });
      });
      log.debug('Customer Search Paging', 'Fetched page index ' + range.index + ' with ' + page.data.length + ' customers');
    });

    log.audit('getInputData Summary', 
      'Total customers queued for reduce: ' + out.length +
      (out.length > 0 ? (' | Sample IDs: ' + out.slice(0,5).map(function(r){return r.custId;}).join(', ')) : '')
    );

    return out;
  }


  /* -------------------- MR: reduce -------------------- */
  function reduce(context){
    var row;
    try{
      row = JSON.parse(context.values[0]);

      // Ensure a Contact for the rep email on this customer
      var repContactId = ensureRepContact(row.custId, row.salesRepEmail);
      log.debug('repContactId', repContactId);

      // Create/update the Level-3 dunning recipient to this contact
      upsertOwnerDunningRecipient(row.custId, repContactId, row.salesRepEmail);

    } catch (e){
      log.error('reduce error', e);
      if (row && row.custId){
        stampCustomer(row.custId, (e && e.message) ? e.message : String(e));
      }
    }
  }

  function summarize(summary){
    // Optional: log errors & usage
    if (summary.inputSummary && summary.inputSummary.error){
      log.error('input error', summary.inputSummary.error);
    }
    summary.reduceSummary.errors.iterator().each(function(key, error){
      log.error('reduce error for key '+key, error);
      return true;
    });
  }

  /* -------------------- exports -------------------- */
  return {
    getInputData: getInputData,
    reduce: reduce,
    summarize: summarize
  };
});
