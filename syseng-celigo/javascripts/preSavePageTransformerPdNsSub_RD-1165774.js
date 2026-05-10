// Author: Prabal Saha
// Height: https://fivetran.height.app/T-894723
// JIRA: RD-1010532 (ELA HVR Intra-Allocations),
//       RD-899810 (Pricing Model Subscription date mapping),
//       RD-1029971 (Census legacy mapping),
//       RD-1060067 (RR dates from Service min/max),
//       RD-927162 (Auto-set Billing Schedules) [LOGIC COMMENTED OUT]
//       RD-1165774 (Remove NS internal id lookup; use source product_code in product_code_branding)
//
// Summary:
// - Validations, address parsing, payer/partner normalization
// - RD-1010532 + RD-1165774: banding only for allowed SKUs, compute term_months (ceil), term_band,
//   set product_code_branding to the source product_code (no NS internal id lookup)
// - RD-899810 + RD-1060067: For subscription products, Service Start/End from billing period,
//   RR Start/End based on Service dates, then min/max across lines per order+product;
//   for non-subscription products, RR/Service from billing period as before
// - RD-1029971: Map Netsuite internal ID 18037 (Reverse ETL - Annual Plan) for Census legacy product_codes
// - RD-927162: [DISABLED] Suggest Billing Schedules per line based on Contract vs Service Start Dates and Billing Frequency

function preSavePage(options) {
    // ===== Debug helper =====
    var DEBUG = true;
    function dbg(step, extra) {
        if (!DEBUG) return;
        try {
            var msg = '[preSavePage] ' + step;
            if (extra !== undefined) msg += ' ' + (typeof extra === 'string' ? extra : JSON.stringify(extra));
            console.log(msg);
        } catch (e) {
            // swallow logging errors
        }
    }
    dbg('START', { hasOptions: !!options });

    const CONFIG = {
        CONTRACT_TYPES: { sales_assisted: 'Prepaid', default: 'Self-service' },
        DEFAULT_FIELDS: { salesrep: '', rate: null },

        // RD-1010532: Apply banding ONLY to these products
        ALLOWED_BANDING_PRODUCTS: ['ELA-On-Prem-Only', 'HVR-57', 'HVR-61'],

        // Bands
        TERM_BANDS: { Y1: '1 Year', Y2: '2 Year', Y3: '3 Year' },

        // RD-1029971: Census legacy products mapping to single NS internal ID
        CENSUS_LEGACY_PRODUCTS: [
            'Census_X_Sell_Avenue_Plan',
            'Census_X_Sell_Business_Plan',
            'Census_X_Sell_Core_Plan',
            'Census_X_Sell_Embedded_Plan',
            'Census_X_Sell_Grow_Plan',
            'Census_X_Sell_Growth_Plan',
            'Census_X_Sell_Platform_Plan',
            'Census_X_Sell_Scale_Plan',
            'Census_X_Sell_Startup_Plan'
        ],
        CENSUS_LEGACY_NS_ID: 18037,

        // RD-899810: Celigo_Pricing_Model_Subscription lookup — Fivetran Product Codes
        PRICING_MODEL_SUBSCRIPTION_SET: {
            'ELA-Cloud-Only': true,
            'ELA-Cloud-Plus-On-Prem': true,
            'ELA-On-Prem-Only': true,
            'PD-private_deployment': true,
            '1000': true,
            'HVR-57': true,
            'HVR-61': true,
            'CLDW': true,
            'HVR5.7_Extended_Support': true,
            'HVR5.7_Extended_Support_Only': true,
            'HVR-Gold-Support': true,
            'HVR_Perpetual_License_Extended_Support': true,
            'HVR_Perpetual_License_Extended_Support_Only': true,
            'Premium_Support': true,
            'US Only Support': true,
            'Census-X-Sell-Pro': true,
            'Census-X-Sell-Enterprise': true,
            'Census_X_Sell_Enterprise_Lite_Plan': true
        },

        COUNTRY_MAP: { 'United States': 'US', USA: 'US' },

        PAYER_TYPE_MAP: {
            CUSTOMER: 'Customer',
            RESELLER: 'Reseller',
            MARKETPLACE: 'Marketplace',
            RESELLER_MARKETPLACE: 'Reseller_Marketplace'
        },

        MARKETPLACE_PAYER_NAME_MAP: {
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
    'decidable_unfailing': 'Crayon Consulting (Partner)',
    'stride_galloping': 'Climb Channel Solutions (Partner)',
    'hastening_unwoven': 'Data France (Partner)',
    'sidewalk_journeyed': 'United Resources Global Enterprise LLP (Partner)',
    'burns_alternation': 'Prenax Denmark, filial af Prenax AB',
    'warmed_salted': 'Ahead, Inc (Partner)',
    'fibrin_mutable': 'SFEIR (Partner)',
    'prevention_impulse': 'Interworks (Partner)',
    'joined_bushes': 'Aion-Tech Solutions Limited (Partner)',
    'opaque_auxiliaries': 'Infosys EMEA (GSI)',
    'payroll_key': 'Keyrus (Partner)',
    'trumpet_viewing': 'Civica Software (Partner)',
    'neutralize_apple': 'Protinus IT (Partner)',
    'backing_ache': 'Interloop.ai (Partner)',
    'exercise_intensely': 'SADA Systems Inc. (Partner)',
    'together_cities': 'Exture Inc (Partner)',
    'tunic_elusive': 'GOPOMELO X COMPANY LIMITED (Partner)',
    'dazzling_resistance': 'Tech Mahindra Global (GSI)',
    'refreshment_baby': 'Cloocus APAC (Partner)',
    'occupied_rambling': 'SoftwareOne UK Ltd (Partner)',
    'unmanaged_pacemaker': 'Accenture UK (GSI) (Partner)',
    'presentment_hacking': 'Capgemini NAMER (GSI)',
    'direct_recharger': 'Preferred Strategies, Inc. d/b/a QuickLaunch Analytics (Partner)',
    'hereto_primer': 'Tarento Technologies Pvt Limited (Partner)',
    'jiffy_lullaby': 'SEIDOR ANALYTICS NORTH AMERICA CORP(Partner)',
    'inflated_shrouded': 'ACCEND NETWORKS INC (Partner)',
    'cypress_idly':'Advanced Chippewa Technologies Incorporated (Partner)',
    'independently_sea':'Berca Hardaya Perkasa (Partner)',
    'recognise_usurp':'World Wide Technology, LLC (Partner)',
    'cordiality_repugnance':'AXI nv (Partner)',
    'artful_southwest':'element61 NV/SA',
    'imperative_comedy':'AOSIS (Partner)',
    'procure_overtime':'onPar Advisors LLC (Partner)',
    'hypertension_disregarded':'Izeno (Partner)',
    'predilection_exonerate':'Academia - the Technology Group (Partner)',
    'lot_grist':'Matrix IT Ltd (Partner)'
        }

        // ===== RD-927162: Billing Schedule suggestion config [COMMENTED OUT] =====
        /*
        ,
        BILLING_SCHEDULES: {
            ANNUAL: {
                Y1: 'Annual - Yr 1',
                Y2: 'Annual - Yr 2',
                Y3: 'Annual - Yr 3'
            },
            QUARTERLY: {
                Y1: 'Quarterly - Yr 1',
                Y2: 'Quarterly - Yr 2',
                Y3: 'Quarterly - Yr 3'
            },
            SEMI_ANNUAL: {
                Y1: 'Semi-Annual - Yr 1',
                Y2: 'Semi-Annual - Yr 2',
                Y3: 'Semi-Annual - Yr 3'
            },
            MONTHLY: {
                Y1: 'Monthly - Yr 1',
                Y2: 'Monthly - Yr 2',
                Y3: 'Monthly - Yr 3'
            },
            REVIEW: 'REVIEW NEEDED'
        }
        */
    };

    // ===== Date helpers (UTC-safe) — RD-1010532 =====
    function parseISODate(dateStr) {
        if (!dateStr) return null;
        var s = String(dateStr).slice(0, 10);
        var parts = s.split('-');
        var y = Number(parts[0]);
        var m = Number(parts[1]);
        var d = Number(parts[2]);
        if (!y || !m || !d) return null;
        return new Date(Date.UTC(y, m - 1, d));
    }

    function daysInMonthUTC(y, m0) {
        return new Date(Date.UTC(y, m0 + 1, 0)).getUTCDate();
    }

    function addMonthsClampedUTC(date, monthsToAdd) {
        var y0 = date.getUTCFullYear();
        var m0 = date.getUTCMonth();
        var d0 = date.getUTCDate();
        var target = new Date(Date.UTC(y0, m0 + monthsToAdd, 1));
        var dim = daysInMonthUTC(target.getUTCFullYear(), target.getUTCMonth());
        var d = Math.min(d0, dim);
        return new Date(Date.UTC(target.getUTCFullYear(), target.getUTCMonth(), d));
    }

    // Ceiling month difference with 30/31/Feb edges handled
    function monthsBetweenCeil(startStr, endStr) {
        var start = parseISODate(startStr);
        var end = parseISODate(endStr);
        if (!start || !end) return null;
        if (end.getTime() < start.getTime()) return 0;
        var months =
            (end.getUTCFullYear() - start.getUTCFullYear()) * 12 +
            (end.getUTCMonth() - start.getUTCMonth());
        var candidate = addMonthsClampedUTC(start, months);
        if (candidate.getTime() > end.getTime()) {
            months -= 1;
            candidate = addMonthsClampedUTC(start, months);
        }
        if (candidate.getTime() === end.getTime()) return months; // exact boundary
        return months + 1; // ceil partials
    }

    // ===== Helpers =====
    function parseAddress(addressStr, prefix) {
        var parsed = {};
        try {
            var o = JSON.parse(addressStr);
            if (o.country && CONFIG.COUNTRY_MAP[o.country]) o.country = CONFIG.COUNTRY_MAP[o.country];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) parsed[prefix + '_' + k] = o[k];
        } catch (e) {
            console.log('Error parsing ' + prefix + ' address:', e);
        }
        return parsed;
    }

    function toNumber(val) {
        if (val === null || val === undefined) return null;
        var num = Number(String(val).replace(/,/g, ''));
        return isFinite(num) ? num : null;
    }

    function toDateStr(x) {
        if (!x) return null;
        return String(x).slice(0, 10); // YYYY-MM-DD, works for ISO timestamps and plain dates
    }

    var validData = [];
    var newErrors = options.errors || [];

    (options.data || []).forEach(function (record, index) {
        // --- Required fields ---
        var missing = [];
        if (!record.billing_address) missing.push('billing_address');
        if (!record.shipping_address) missing.push('shipping_address');
        if (!record.legal_name || String(record.legal_name).trim() === '') missing.push('legal_name');
        if (!record.billing_account_id || String(record.billing_account_id).trim() === '') missing.push('billing_account_id');

        if (missing.length) {
            newErrors.push({
                recordIndex: index,
                record: record,
                message: 'Record rejected due to missing required fields: ' + missing.join(', ') +
                    ' (Billing Account ID: ' + (record.billing_account_id || '') + ')',
                code: 'missing_fields',
                source: 'validation'
            });
            return;
        }

        // --- Build cleaned record ---
        var billing_address = record.billing_address;
        var shipping_address = record.shipping_address;
        var cleaned = {};

        for (var key in record) {
            if (key !== 'billing_address' &&
                key !== 'shipping_address' &&
                Object.prototype.hasOwnProperty.call(record, key)) {
                cleaned[key] = record[key];
            }
        }

        for (var kdf in CONFIG.DEFAULT_FIELDS) {
            cleaned[kdf] = CONFIG.DEFAULT_FIELDS[kdf];
        }

        var parsedBill = parseAddress(billing_address, 'billing');
        var parsedShip = parseAddress(shipping_address, 'shipping');
        for (var pb in parsedBill) cleaned[pb] = parsedBill[pb];
        for (var ps in parsedShip) cleaned[ps] = parsedShip[ps];

        // Rate
        var amt = toNumber(cleaned.amount);
        var qty = toNumber(cleaned.product_quantity);
        cleaned.rate = (amt !== null && qty !== null && qty !== 0) ? (amt / qty) : null;

        // Payer type map (case-insensitive)
        if (cleaned.payer_type) {
            var k = String(cleaned.payer_type).toUpperCase();
            cleaned.payer_type = CONFIG.PAYER_TYPE_MAP[k] || cleaned.payer_type;
        }

        // third_party_payer_id name mapping when certain payer types
        if (
            (cleaned.payer_type === 'Marketplace' ||
                cleaned.payer_type === 'Reseller' ||
                cleaned.payer_type === 'Reseller_Marketplace') &&
            cleaned.third_party_payer_id
        ) {
            var tppKey = String(cleaned.third_party_payer_id).trim();
            var tppName = CONFIG.MARKETPLACE_PAYER_NAME_MAP[tppKey] || null;
            cleaned.third_party_payer_id = tppKey; // keep the key as-is
            cleaned.third_party_payer_name = tppName; // optional display name
        }

        // Partner and is_partner
        var partnerName = CONFIG.MARKETPLACE_PAYER_NAME_MAP[record.third_party_payer_id];
        cleaned.partner = partnerName || null;
        cleaned.is_partner = !!(partnerName &&
            (cleaned.payer_type === 'Reseller_Marketplace' || cleaned.payer_type === 'Marketplace'));

        // RESELLER payer: third_party_payer_id must exist and be mapped in MARKETPLACE_PAYER_NAME_MAP
        if (cleaned.payer_type === 'Reseller') {
            var tppId = String(cleaned.third_party_payer_id || '').trim();
            var mapped = tppId && !!CONFIG.MARKETPLACE_PAYER_NAME_MAP[tppId];
            if (!mapped) {
                newErrors.push({
                    recordIndex: index,
                    record: record,
                    message: "Record rejected: RESELLER payer requires third_party_payer_id to be present and mapped in MARKETPLACE_PAYER_NAME_MAP, but got '" +
                        (tppId || '(empty)') + "'.",
                    code: 'invalid_reseller_mapping',
                    source: 'validation'
                });
                return;
            }
        }

        // Canonical attention fields
        cleaned.billing_attention =
            (cleaned.billing_firstName || cleaned.billing_lastName)
                ? (String(cleaned.billing_firstName || '') + ' ' + String(cleaned.billing_lastName || '')).trim()
                : null;
        cleaned.shipping_attention =
            (cleaned.shipping_firstName || cleaned.shipping_lastName)
                ? (String(cleaned.shipping_firstName || '') + ' ' + String(cleaned.shipping_lastName || '')).trim()
                : null;

        // Default for all records: internal-id branding null
        cleaned.product_code_branding = null;

        // ===== RD-1010532 + RD-1165774: banding only for allowed products =====
        (function applyElaHvrIfAllowed() {
            var pc = (cleaned.product_code || '').trim();
            if (CONFIG.ALLOWED_BANDING_PRODUCTS.indexOf(pc) === -1) {
                // Not banded → default path
                cleaned.term_months = null;
                cleaned.term_band = null;
                cleaned.alloc_strategy = cleaned.alloc_strategy || 'default_no_banding';
                return;
            }
            // Compute term months
            var start = cleaned.contract_start_date || cleaned.start_date_utc;
            var end = cleaned.contract_end_date || cleaned.end_date_utc;
            var termMonths = monthsBetweenCeil(start, end);
            cleaned.term_months = termMonths;
            if (termMonths == null) {
                newErrors.push({
                    recordIndex: index,
                    record: record,
                    message: "Term calculation failed (invalid dates). start='" + start + "' end='" + end + "'",
                    code: 'term_calc_failed',
                    source: 'validation'
                });
                cleaned.alloc_strategy = 'band_term_error';
                return;
            }
            // Band
            var band;
            if (termMonths <= 17) band = CONFIG.TERM_BANDS.Y1;
            else if (termMonths <= 29) band = CONFIG.TERM_BANDS.Y2;
            else band = CONFIG.TERM_BANDS.Y3;
            cleaned.term_band = band;

            // RD-1165774: carry source product_code through instead of NS internal id
            cleaned.product_code_branding = pc;
            cleaned.alloc_strategy = 'banded';
        })();

        // ===== RD-1029971: Census legacy mapping =====
        (function applyCensusLegacyMapping() {
            var pc = (cleaned.product_code || '').trim();
            if (CONFIG.CENSUS_LEGACY_PRODUCTS.indexOf(pc) === -1) {
                // Not a Census legacy product → default path
                cleaned.alloc_strategy = cleaned.alloc_strategy || 'default_no_mapping';
                return;
            }
            // Success → set internal id only
            cleaned.product_code_branding = CONFIG.CENSUS_LEGACY_NS_ID; // NS Item internal id
            cleaned.record_code_branding = true;
            cleaned.alloc_strategy = 'census_legacy';
            if (!cleaned.source_product_code) cleaned.source_product_code = pc;
        })();

        // ===== RD-899810 + RD-1060067: Pricing model subscription date mapping + RR from Service dates =====
        (function applyPricingModelDates() {
            var pc = (cleaned.product_code || '').trim();
            var inPricingLookup = !!CONFIG.PRICING_MODEL_SUBSCRIPTION_SET[pc];

            // Normalize all candidate dates to YYYY-MM-DD (or null)
            var contractStart = toDateStr(cleaned.contract_start_date);
            var contractEnd = toDateStr(cleaned.contract_end_date);
            var periodStart = toDateStr(cleaned.start_date_utc);
            var periodEnd = toDateStr(cleaned.end_date_utc);

            if (inPricingLookup) {
                // Subscription pricing model:
                // 1) Service dates from billing period (or fallback to contract)
                var serviceStart = periodStart || contractStart || null;
                var serviceEnd = periodEnd || contractEnd || null;

                cleaned.service_start_date = serviceStart;
                cleaned.service_end_date = serviceEnd;

                // 2) RR dates initially equal to Service dates (min/max applied later across lines)
                cleaned.rr_start_date = serviceStart;
                cleaned.rr_end_date = serviceEnd;

            } else {
                // Non-subscription (or not in lookup):
                // RR dates and Service dates both from billing period (unchanged behavior)
                var s = periodStart || contractStart || null;
                var e = periodEnd || contractEnd || null;
                cleaned.rr_start_date = s;
                cleaned.rr_end_date = e;
                cleaned.service_start_date = s;
                cleaned.service_end_date = e;
            }
        })();

        // ===== RD-927162: Auto-set Billing Schedules based on Contract vs Service Start Dates [COMMENTED OUT] =====
        /*
        (function applyBillingScheduleSuggestion() {
            try {
                // Normalize frequency from available fields
                var rawFreq = cleaned.billing_frequency || cleaned.subscription_billing_frequency || cleaned.billing_schedule || '';
                var freq = String(rawFreq || '').toUpperCase().trim();

                // Use contract_start_date and service_start_date (post RD-899810/RD-1060067 mapping)
                var contractStartStr = toDateStr(cleaned.contract_start_date || cleaned.rr_start_date);
                var serviceStartStr = toDateStr(cleaned.service_start_date || cleaned.start_date_utc);

                var cStart = parseISODate(contractStartStr);
                var sStart = parseISODate(serviceStartStr);

                var suggested = CONFIG.BILLING_SCHEDULES.REVIEW;
                var scenario = 'Scenario 3: Non-Standard';
                var yearOffset = null;
                var needsReview = true;

                if (!cStart || !sStart) {
                    // Missing date inputs → cannot safely compute offset
                    scenario = 'Invalid/Missing Dates';
                } else {
                    var diffMonths =
                        (sStart.getUTCFullYear() - cStart.getUTCFullYear()) * 12 +
                        (sStart.getUTCMonth() - cStart.getUTCMonth());

                    if (diffMonths < 0) {
                        // Service starts before contract → definitely non-standard
                        scenario = 'Scenario 3: Non-Standard';
                    } else {
                        yearOffset = Math.floor(diffMonths / 12); // 0 = Year 1, 1 = Year 2, 2 = Year 3, etc.

                        // Decide scenario classification
                        if (yearOffset === 0) {
                            scenario = 'Scenario 1: 1 Year';
                        } else if (yearOffset > 0 && yearOffset <= 2) {
                            scenario = 'Scenario 2: Multi-Year';
                        } else {
                            scenario = 'Scenario 3: Non-Standard';
                        }

                        // Only auto-map for offsets we explicitly support (0..2)
                        if (yearOffset >= 0 && yearOffset <= 2) {
                            var yrKey = 'Y' + (yearOffset + 1); // 'Y1', 'Y2', 'Y3'

                            // Map frequency → schedule family
                            var familyKey = null;
                            if (freq.indexOf('ANNUAL') >= 0 || freq.indexOf('UPFRONT') >= 0 || freq.indexOf('UP FRONT') >= 0) {
                                familyKey = 'ANNUAL';
                            } else if (freq.indexOf('QUARTER') >= 0) {
                                familyKey = 'QUARTERLY';
                            } else if (freq.indexOf('SEMI') >= 0 || freq.indexOf('HALF') >= 0) {
                                familyKey = 'SEMI_ANNUAL';
                            } else if (freq.indexOf('MONTH') >= 0) {
                                familyKey = 'MONTHLY';
                            }

                            if (familyKey && CONFIG.BILLING_SCHEDULES[familyKey] && CONFIG.BILLING_SCHEDULES[familyKey][yrKey]) {
                                suggested = CONFIG.BILLING_SCHEDULES[familyKey][yrKey];
                                needsReview = false;
                            } else {
                                suggested = CONFIG.BILLING_SCHEDULES.REVIEW;
                                needsReview = true;
                            }
                        }
                    }
                }

                cleaned.billing_schedule_suggested = suggested;
                cleaned.billing_schedule_year_offset = yearOffset;
                cleaned.billing_schedule_scenario = scenario;
                cleaned.billing_schedule_needs_review = !!needsReview;
            } catch (e) {
                cleaned.billing_schedule_suggested = CONFIG.BILLING_SCHEDULES.REVIEW;
                cleaned.billing_schedule_year_offset = null;
                cleaned.billing_schedule_scenario = 'Error in billing schedule logic';
                cleaned.billing_schedule_needs_review = true;
                newErrors.push({
                    recordIndex: index,
                    record: record,
                    message: 'RD-927162 billing schedule logic failed: ' +
                        (e && e.message ? e.message : String(e)),
                    code: 'billing_schedule_logic_failed',
                    source: 'RD-927162'
                });
            }
        })();
        */

        validData.push(cleaned);
    });

    // ===== RD-1060067: RR Start/End min/max per subscription group (based on Service Start/End) =====
    (function applyRevRecMinMaxByGroup() {
        var rrGroups = {};

        validData.forEach(function (r) {
            var pc = (r.product_code || '').trim();
            if (!CONFIG.PRICING_MODEL_SUBSCRIPTION_SET[pc]) return; // only subscription products

            var orderNumber = r.order_number || '';
            // Group at least by order_number + product_code; adjust key if you need different grouping
            var key = String(orderNumber) + '||' + pc;

            if (!rrGroups[key]) {
                rrGroups[key] = {
                    items: [],
                    minServiceStart: null,
                    maxServiceEnd: null
                };
            }

            rrGroups[key].items.push(r);

            var s = toDateStr(r.service_start_date);
            var e = toDateStr(r.service_end_date);

            if (s) {
                if (!rrGroups[key].minServiceStart || s < rrGroups[key].minServiceStart) {
                    rrGroups[key].minServiceStart = s;
                }
            }
            if (e) {
                if (!rrGroups[key].maxServiceEnd || e > rrGroups[key].maxServiceEnd) {
                    rrGroups[key].maxServiceEnd = e;
                }
            }
        });

        Object.keys(rrGroups).forEach(function (gKey) {
            var g = rrGroups[gKey];
            var rrStart = g.minServiceStart;
            var rrEnd = g.maxServiceEnd;

            g.items.forEach(function (r) {
                r.rr_start_date = rrStart;
                r.rr_end_date = rrEnd;
            });
        });
    })();

    // --- Group by order_number; drop zero-total groups ---
    var groups = validData.reduce(function (acc, r) {
        var on = r.order_number;
        if (!acc[on]) acc[on] = { total: 0, items: [] };
        acc[on].total += toNumber(r.amount) || 0;
        acc[on].items.push(r);
        return acc;
    }, {});

    var removedOrders = [];
    var finalData = Object.keys(groups).map(function (k) { return groups[k]; })
        .filter(function (g) {
            if (g.total === 0) {
                var first = g.items[0];
                removedOrders.push({
                    order_number: first ? first.order_number : null,
                    billing_account_id: first ? first.billing_account_id : null,
                    total_amount: g.total,
                    record_count: g.items.length
                });
                return false;
            }
            return true;
        })
        .reduce(function (arr, g) { return arr.concat(g.items); }, []);

    // --- Sort final payload by numeric id ascending (id guaranteed numeric)
    finalData.sort(function (a, b) { return Number(a.id) - Number(b.id); });

    if (removedOrders.length) {
        Array.prototype.push.apply(
            newErrors,
            removedOrders.map(function (o) {
                return {
                    message: "Didn't compute order " + o.order_number + " for " + o.billing_account_id +
                        " due to zero total amount. These subscriptions are rejected in Celigo.",
                    code: 'zero_total',
                    source: 'BQ'
                };
            })
        );
    }

    // --- Metrics ---
    var total_input = Array.isArray(options.data) ? options.data.length : 0;
    var total_ingested = finalData.length;
    var validationErrorIndices = newErrors
        .filter(function (e) { return e.code === 'missing_fields' && typeof e.recordIndex === 'number'; })
        .map(function (e) { return e.recordIndex; })
        .reduce(function (set, idx) { if (set.indexOf(idx) === -1) set.push(idx); return set; }, []);

    var rejected_due_to_zero_total = removedOrders.reduce(function (s, o) {
        return s + (o.record_count || 0);
    }, 0);

    var total_errored = validationErrorIndices.length + rejected_due_to_zero_total;
    var difference_ingested_vs_errored = total_ingested - total_errored;

    var metrics = {
        total_input: total_input,
        total_ingested: total_ingested,
        total_errored: total_errored,
        difference_ingested_vs_errored: difference_ingested_vs_errored,
        breakdown: {
            validation_error_records: validationErrorIndices.length,
            zero_total_rejected_records: rejected_due_to_zero_total
        }
    };

    dbg('METRICS', metrics);
    console.log('[preSavePage:metrics RD-1010532 RD-899810 RD-1029971 RD-1060067 RD-927162 RD-1165774]', JSON.stringify(metrics));
    dbg('END', { output_records: finalData.length, errors: newErrors.length });

    return {
        data: finalData,
        errors: newErrors,
        abort: false,
        newErrorsAndRetryData: [],
        metrics: metrics
    };
}
