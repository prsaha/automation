/**
 * @NApiVersion 2.1
 * @NScriptType MapReduceScript
 */
define(['N/search', 'N/file', 'N/runtime'], function (search, file, runtime) {

    /**
     * Formats a date to MM/DD/YYYY string for NetSuite search compatibility.
     * @param {string|Date} dateInput - The date input (ISO string or Date object).
     * @returns {string} - Formatted date string (e.g., '7/1/2025').
     */
    function formatDateForSearch(dateInput) {
        try {
            const date = new Date(dateInput);
            if (isNaN(date.getTime())) {
                throw new Error('Invalid date');
            }
            const month = (date.getMonth() + 1).toString().padStart(2, '0');
            const day = date.getDate().toString().padStart(2, '0');
            const year = date.getFullYear();
            return `${month}/${day}/${year}`;
        } catch (e) {
            log.error('Step: Date Formatting Failed', `Input: ${dateInput}, Error: ${e.message}`);
            throw e;
        }
    }

    /**
     * Validates if a folder ID exists and is accessible.
     * @param {string} folderId - The folder ID to validate.
     * @returns {boolean} - True if valid, false otherwise.
     */
    function isValidFolder(folderId) {
        try {
            const folderSearch = search.create({
                type: 'folder',
                filters: [['internalid', 'anyof', folderId]],
                columns: ['internalid']
            });
            const result = folderSearch.run().getRange({ start: 0, end: 1 });
            return result.length > 0;
        } catch (e) {
            log.error('Step: Folder Validation Failed', `Folder ID: ${folderId}, Error: ${e.message}`);
            return false;
        }
    }

    /**
     * Retrieves the file IDs to be deleted based on a date range and parent folder.
     * @returns {search.Search} A search object of files to be processed.
     */
    function getInputData() {
        log.debug('Step: getInputData Started', 'Initializing getInputData function');
        const script = runtime.getCurrentScript();
        const startDateParam = script.getParameter({ name: 'custscriptcustscript_start_date' });
        const endDateParam = script.getParameter({ name: 'custscriptcustscript_end_date' });
        const folderIdParam = script.getParameter({ name: 'custscriptcustscript_folder_id' });

        log.debug('Step: Retrieved Parameters', `startDateParam: ${startDateParam}, endDateParam: ${endDateParam}, folderIdParam: ${folderIdParam}`);

        if (!startDateParam || !endDateParam || !folderIdParam) {
            log.error('Step: Parameter Validation Failed', 'Start date, end date, or folder ID parameters are missing.');
            throw new Error('Script execution halted due to missing parameters.');
        }

        // Validate folder ID
        log.debug('Step: Validating Folder ID', `Checking folder ID: ${folderIdParam}`);
        if (!isValidFolder(folderIdParam)) {
            log.error('Step: Invalid Folder ID', `Folder ID ${folderIdParam} does not exist or is inaccessible.`);
            throw new Error(`Invalid or inaccessible folder ID: ${folderIdParam}`);
        }

        // Format dates to MM/DD/YYYY
        let formattedStartDate, formattedEndDate;
        try {
            formattedStartDate = formatDateForSearch(startDateParam);
            formattedEndDate = formatDateForSearch(endDateParam);
            log.debug('Step: Formatted Dates', `Formatted startDate: ${formattedStartDate}, endDate: ${formattedEndDate}`);
        } catch (e) {
            log.error('Step: Date Formatting Failed', `Error formatting dates: ${e.message}`);
            throw e;
        }

        const filters = [
            ['created', 'onorafter', formattedStartDate],
            'AND',
            ['created', 'onorbefore', formattedEndDate],
            'AND',
            ['folder', 'anyof', folderIdParam]
        ];

        log.debug('Step: Search Filters Created', `Filters: ${JSON.stringify(filters)}`);

        let searchObj;
        try {
            searchObj = search.create({
                type: 'file',
                filters: filters,
                columns: ['internalid', 'name', 'created']
            });
            log.debug('Step: Search Object Created', `Search created for type: file, folder ID: ${folderIdParam}`);
        } catch (e) {
            log.error('Step: Search Creation Failed', `Error creating search: ${e.message}`);
            throw e;
        }

        // Check if search returns results
        try {
            const resultCount = searchObj.run().getRange({ start: 0, end: 1 }).length;
            log.debug('Step: Search Result Check', `Found ${resultCount} files to process`);
            if (resultCount === 0) {
                log.audit('Step: No Files Found', 'No files match the search criteria.');
            }
        } catch (e) {
            log.error('Step: Search Execution Failed', `Error executing search: ${e.message}`);
            throw e;
        }

        return searchObj;
    }

    /**
     * The map stage processes each file record and deletes the file.
     * @param {Object} context The map context object.
     */
    function map(context) {
        log.debug('Step: Map Stage Started', `Processing map stage for key: ${context.key}`);

        // Check governance limits
        const remainingUsage = runtime.getCurrentScript().getRemainingUsage();
        log.debug('Step: Governance Check', `Remaining usage units: ${remainingUsage}`);
        if (remainingUsage < 100) {
            log.error('Step: Governance Limit Reached', 'Insufficient usage units to continue processing.');
            throw new Error('Governance limit reached. Consider rescheduling the script.');
        }

        let searchResult;
        try {
            searchResult = JSON.parse(context.value);
            log.debug('Step: Parsed Search Result', `Parsed result for key: ${context.key}, ID: ${searchResult.id}`);
        } catch (e) {
            log.error('Step: JSON Parse Failed', `Failed to parse context.value for key: ${context.key}, Error: ${e.message}`);
            return; // Skip to the next record
        }

        const fileId = searchResult.id;
        const fileName = searchResult.values.name || 'Unknown';
        const createdDate = searchResult.values.created || 'Unknown';

        log.debug('Step: File Details', `Processing file: ${fileName} (ID: ${fileId}, Created: ${createdDate})`);

        try {
            file.delete({ id: fileId });
            log.audit('Step: File Deleted', `Successfully deleted file: ${fileName} (ID: ${fileId}, Created: ${createdDate})`);
        } catch (e) {
            log.error('Step: File Deletion Failed', `File: ${fileName} (ID: ${fileId}), Error: ${e.message}`);
        }
    }

    /**
     * The summarize stage logs the results of the entire process.
     * @param {Object} context The summarize context object.
     */
    function summarize(context) {
        log.debug('Step: Summarize Stage Started', 'Initializing summarize stage');
        let deletionCount = 0;
        let errorCount = 0;

        log.debug('Step: Processing Map Errors', 'Checking for errors in map stage');
        context.mapSummary.errors.iterator().each(function (key, error, repetitions) {
            log.error('Step: Map Error Encountered', `File ID: ${key}, Error: ${error}, Repetitions: ${repetitions}`);
            errorCount++;
            return true;
        });

        log.debug('Step: Counting Deleted Files', 'Iterating over output to count deletions');
        context.output.iterator().each(function (key, value) {
            deletionCount++;
            log.debug('Step: File Deletion Counted', `File ID: ${key}, Deletion count: ${deletionCount}`);
            return true;
        });

        const folderId = runtime.getCurrentScript().getParameter({ name: 'custscript_folder_id' });
        log.audit('Step: Map/Reduce Summary', `Processed ${deletionCount} files in folder ${folderId} with ${errorCount} errors.`);
    }

    return {
        getInputData: getInputData,
        map: map,
        summarize: summarize
    };
});