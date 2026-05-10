# Celigo NetSuite GCS Worker

A Google Cloud Function that receives NetSuite invoice file references from Celigo and stores the actual PDF files in Google Cloud Storage.

## Overview

This service acts as a bridge between NetSuite (via Celigo integration) and Google Cloud Storage. It:

1. Authenticates requests using bearer token authentication
2. Accepts HTTP POST requests containing NetSuite file information
3. Downloads the referenced PDF files from NetSuite's servers
4. Stores them in a Google Cloud Storage bucket with original metadata
5. Returns a response with storage details

## Authentication

The service uses bearer token authentication to secure the API endpoint:

- Each request must include an `Authorization` header with a valid bearer token
- Valid tokens are stored in Google Secret Manager and accessed via the `AUTHORIZED_TOKENS` environment variable
- Requests without a valid token will be rejected with a 401 Unauthorized response
- The function is deployed with `--allow-unauthenticated` to enable Celigo integration, but authentication is enforced at the application level

Example:

```
Authorization: Bearer YOUR_TOKEN
```

## API Endpoints

The service provides a single HTTP endpoint that supports two different payload formats:

### Batch Processing Format

The primary format expects a list of files to process:

```json
{
  "success": true,
  "status": "COMPLETE",
  "files": [
    {
      "rownumber": 1,
      "id": 2856923,
      "name": "INV23112430044.pdf",
      "url": "/core/media/media.nl?id=2856923&c=5260239_SB1&h=...",
      "fullUrl": "https://5260239-sb1.app.netsuite.com/core/media/media.nl?id=2856923&c=5260239_SB1&h=...",
      "invoiceNumber": "INV23112430044",
      "customerName": "Acme Corporation",
      "invoiceDate": "2023-11-24"
      // ... any other metadata fields will be stored with the file
    },
    {
      // additional files
    }
  ]
}
```

### Single File Format

For processing individual files, the service supports a format that expects a `fullUrl` field:

```json
{
  "fullUrl": "https://5260239.app.netsuite.com/core/media/media.nl?id=2856923&c=5260239_SB1&h=...",
  "billingAccountId": "surprisingly_zebra",
  "name": "INV23112430044.pdf",
  // ... any other metadata fields will be stored with the file
}
```

## Storage Details

- Files are organized into folders based on the `billingAccountId` field (expected format: `word_word`, e.g., `surprisingly_zebra`)
- Invalid or missing billing account IDs will default to `unknown_billing_account_id` or `invalid_billing_account_format`
- Files are named based on the `name` field from the request, with `.pdf` extension enforced
- All metadata from the request is preserved and attached to the GCS object
- The service returns detailed information about successful and failed operations

## Security Features

- **URL Validation**: Only PDFs from the configured NetSuite host are allowed (default: `https://5260239.app.netsuite.com`)
- **Path Sanitization**: The `billingAccountId` is sanitized to prevent path traversal attacks
- **Bearer Token Authentication**: Requests must include a valid bearer token
- **PDF Verification**: Files are verified to be valid PDFs before storage

## Deployment to Dev

```bash
gcloud functions deploy celigo-gcs-worker \
  --runtime python310 \
  --trigger-http \
  --service-account celigo-netsuite-wildwest@fivetran-wild-west.iam.gserviceaccount.com \
  --allow-unauthenticated \
  --set-env-vars DESTINATION_BUCKET=edc-celigo-netsuite-test \
  --set-secrets AUTHORIZED_TOKENS=celigo-gcs-worker-tokens:latest \
  --project your-project-id \
  --stage-bucket gcf-v2-uploads-818218529370 \
  --entry-point main
```

Ensure the service account has:

- Storage Object Admin on the destination bucket
- Secret Manager Secret Accessor on the tokens secret

## Deployment to Staging

Handled by `deploy_staging.sh`. The script will provision necessary resources if they do not exist.

## Deployment to Production

Handled by `deploy_prod.sh`. This script will deploy the function to Cloud Run in the `fivetran-automation` project. It expects the following resources to exist:

- The deployment service account, passed into the script
- The destination bucket, passed into the script
- The authorized tokens secret location, stored in Secrets Manager, passed into the script

The service account should be granted read on the authorized tokens secret as well as object admin on the destination bucket. The deployment script will not check these conditions.

## Local Development

To run the service locally:

1. Authenticate with Google Cloud: `gcloud auth application-default login`
2. Set required environment variables in a .env file:
   - `DESTINATION_BUCKET` - The GCS bucket where files will be stored
   - `AUTHORIZED_TOKENS` - Comma-separated list of valid bearer tokens (e.g. "token1,token2")
   - `ALLOWED_NETSUITE_HOST` - (Optional) Allowed NetSuite host for PDF downloads (default: `https://5260239.app.netsuite.com`)
   - `GOOGLE_APPLICATION_CREDENTIALS` - Path to your service account key file for GCS access
3. Start the local server: `functions-framework --target=main` or `source scripts.sh && run_local`
4. Test with the provided example payloads in `scripts.sh` (including a valid token):
   ```bash
   source scripts.sh
   test_legacy_simple your-test-token
   test_batch_local your-test-token
   ```

## Token Management

To generate new secure tokens for the service:

```bash
# Generate tokens for the default project (fivetran-automation)
./generate_tokens.sh

# Generate tokens for a custom project and secret
./generate_tokens.sh my-project my-secret-name
```

This script will:
- Generate cryptographically secure 32-character tokens
- Update the specified secret in Google Secret Manager
- Display the generated tokens for distribution to authorized clients

## Scripts and Testing

The `scripts.sh` file provides various testing and deployment utilities:

```bash
# Source the scripts
source scripts.sh

# Test locally with different formats
test_legacy_simple YOUR_TOKEN   # Test single file format
test_batch_local YOUR_TOKEN     # Test batch format

# Deploy to test environment
deploy_test
```

## Requirements

See requirements.txt for the full dependencies list. Key requirements:

- Python 3.10+
- Functions Framework 3.8.2
- Google Cloud Storage client 3.0.0
- Requests library 2.32.3
- python-dotenv 1.0.1 (for local development)
