# celigo-netsuite-gcs-worker

A Google Cloud Function (Python 3.10) that receives NetSuite invoice file references from Celigo, downloads the PDF from NetSuite, and archives it to Google Cloud Storage with full metadata preservation.

This service is the final stage of the Fivetran billing pipeline:
```
NetSuite (generates invoice PDF)
    │
    ▼ Celigo triggers HTTP POST
celigo-netsuite-gcs-worker  ← this service
    │
    ▼ uploads with metadata
Google Cloud Storage (edc-celigo-netsuite-* bucket)
```

---

## Repository Layout

```
celigo-netsuite-gcs-worker/
├── main.py                        # Cloud Function entrypoint; request routing + GCS write
├── auth.py                        # Bearer token authentication
├── config.py                      # Environment variable loading and validation
├── validation.py                  # Billing account ID sanitization; log scrubbing
├── logging_config.py              # Structured JSON logger setup
├── manual_processing/
│   └── process_invoices.py        # Offline utility: reprocess invoices from a manifest
├── scripts/
│   ├── deploy_prod.sh             # Cloud Run production deployment
│   ├── deploy_staging.sh          # Cloud Functions staging deployment
│   ├── generate_tokens.sh         # Token generation + Secret Manager update
│   ├── scripts.sh                 # Local dev helpers: run_local, test_legacy_simple, test_batch_local
│   └── test_logging.sh            # Log output verification script
├── requirements.txt               # Production dependencies
├── requirements-dev.txt           # Dev/test dependencies
└── pyproject.toml                 # Project metadata
```

---

## Module Reference

### `main.py` — Cloud Function entrypoint

Registers the HTTP handler via `@functions_framework.http`. On every incoming request:

1. Generates a UUID `request_id` for log correlation across all downstream calls.
2. Calls `authenticate_request()` — returns `401` on failure.
3. Parses the JSON body — returns `400` on malformed/empty payload.
4. Dispatches to `process_files_payload()` if `"files"` key is present (batch mode), or `process_single_file()` if `"fullUrl"` is present (legacy single-file mode).

**`retrieve_pdf_from_url(pdf_url)`**

Downloads the PDF from the provided NetSuite URL. Security checks:
- **SSRF prevention**: Parses the URL with `urllib.parse.urlparse` and compares scheme + netloc against `config.ALLOWED_NETSUITE_HOST`. Returns `403` if the host doesn't match.
- **PDF validation (three-factor OR)**:
  - `Content-Type: application/pdf` header present, **or**
  - URL ends with `.pdf`, **or**
  - First 5 bytes of the response body equal `b"%PDF-"` (magic bytes check)

  If none of the three pass, returns `400`.

**`save_file_to_gcs(file_name, folder, content, metadata)`**

Writes `content` (bytes) to GCS at path `{folder}/{file_name}`. Sets all metadata fields from the request payload as GCS object metadata (values coerced to `str`). Raises on GCS error.

**`process_files_payload(payload, request_id)`**

Batch mode. Iterates over `payload["files"]`. For each file:
- Extracts `fullUrl`, `name`, `billingAccountId`
- Sanitizes `billingAccountId` via `sanitize_billing_account_id()`
- Calls `retrieve_pdf_from_url()` then `save_file_to_gcs()`
- Collects per-file results and errors

Returns HTTP `207` (Multi-Status) when at least one file succeeded, `400` when none succeeded.

**`process_single_file(request_json, request_id)`**

Legacy single-file mode. Handles `_PARENT` nested metadata by flattening it as `_PARENT_{key}` fields. Returns `200` on success, `500` on GCS error.

---

### `auth.py` — Bearer token authentication

`authenticate_request(request, request_id)` → `bool`

Checks the `Authorization` header for the `Bearer <token>` pattern. Strips the token and looks it up in `config.VALID_TOKENS` (set loaded from the `AUTHORIZED_TOKENS` env var). Returns `True` if the token matches, `False` otherwise. All failures are logged as `WARNING` with IP and user-agent (token value is never logged).

---

### `config.py` — Environment variable configuration

All settings are loaded at module import time from environment variables (with `.env` file support via `python-dotenv` when running locally).

| Variable | Required | Default | Description |
|---|---|---|---|
| `DESTINATION_BUCKET` | Yes | — | GCS bucket name where PDFs are stored |
| `AUTHORIZED_TOKENS` | Yes | — | Comma-separated list of valid bearer tokens |
| `GCP_PROJECT` | No | Inferred from credentials | GCP project ID for the GCS client |
| `ALLOWED_NETSUITE_HOST` | No | `https://5260239.app.netsuite.com` | Allowed origin for PDF downloads (SSRF allowlist) |
| `LOG_LEVEL` | No | `INFO` | Python log level: `DEBUG`, `INFO`, `WARNING`, `ERROR` |
| `LOG_SUCCESSFUL_RESPONSES` | No | `true` | Log INFO entries for successful uploads |
| `LOG_RESPONSE_DETAILS` | No | `false` | Log detailed payload/metadata in DEBUG; enables verbose batch summaries |

The `Config` class raises `ValueError` at startup if `DESTINATION_BUCKET` or `AUTHORIZED_TOKENS` are missing — Cloud Function will fail fast rather than accept requests it cannot service.

**Billing account ID pattern** (used in path sanitization):
```
^[a-zA-Z0-9]+(_[a-zA-Z0-9]+){0,3}$
```
Matches `word`, `word_word`, up to `word_word_word_word`. Expected format: `surprisingly_zebra`.

---

### `validation.py` — Input sanitization

**`sanitize_billing_account_id(billing_account_id)`**

Prevents path traversal attacks before using the billing account ID as a GCS folder name:
1. Strips `..`, `/`, `\` characters
2. Validates against `BILLING_ACCOUNT_PATTERN` regex
3. Returns `"unknown_billing_account_id"` if empty, `"invalid_billing_account_format"` if pattern doesn't match

**`sanitize_request_for_logging(request_data)`**

Scrubs sensitive field values before writing to structured logs. Any field whose name contains `authorization`, `token`, `password`, `secret`, `key`, or `auth` is replaced with `[REDACTED]`. For batch requests, `files` is truncated to 10 entries and long URLs are trimmed to `first50...last30` characters.

---

### `logging_config.py` — Structured logging

Configures a JSON-format structured logger compatible with Google Cloud Logging. Log entries include:
- `request_id` (UUID per HTTP request, for correlation)
- `severity` / Python log level
- Contextual `extra` fields (file name, billing account, file size, error type, etc.)

---

### `manual_processing/process_invoices.py`

Offline utility for reprocessing a batch of invoices outside of the Celigo integration. Reads a JSON manifest of invoice file references and calls the same `retrieve_pdf_from_url` + `save_file_to_gcs` logic. Used during incident recovery to re-archive PDFs that were missed due to a Celigo outage or quota error.

---

## API Reference

### Single File (Legacy Format)

```http
POST /
Authorization: Bearer <token>
Content-Type: application/json

{
  "fullUrl": "https://5260239.app.netsuite.com/core/media/media.nl?id=2856923&c=5260239&h=...",
  "billingAccountId": "surprisingly_zebra",
  "name": "INV23112430044.pdf",
  "invoiceNumber": "INV23112430044",
  "customerName": "Acme Corporation",
  "invoiceDate": "2023-11-24"
}
```

**Response `200`:**
```json
{
  "message": "File uploaded successfully.",
  "file_path": "surprisingly_zebra/INV23112430044.pdf",
  "file_name": "INV23112430044.pdf",
  "timestamp": "2024-01-15T10:30:00+00:00",
  "destination_bucket": "edc-celigo-netsuite-prod"
}
```

### Batch Format

```http
POST /
Authorization: Bearer <token>
Content-Type: application/json

{
  "success": true,
  "status": "COMPLETE",
  "files": [
    {
      "rownumber": 1,
      "id": 2856923,
      "name": "INV23112430044.pdf",
      "fullUrl": "https://5260239.app.netsuite.com/core/media/media.nl?id=2856923&c=5260239&h=...",
      "billingAccountId": "surprisingly_zebra",
      "invoiceNumber": "INV23112430044",
      "customerName": "Acme Corporation",
      "invoiceDate": "2023-11-24"
    }
  ]
}
```

**Requirements:**
- `success` must be `true` — if `false`, the entire batch is rejected with `400`
- Each file entry must have a `fullUrl`

**Response `207` (partial success) or `400` (all failed):**
```json
{
  "processed": 1,
  "total": 1,
  "results": [
    {
      "message": "File uploaded successfully.",
      "file_path": "surprisingly_zebra/INV23112430044.pdf",
      "file_name": "INV23112430044.pdf"
    }
  ],
  "timestamp": "2024-01-15T10:30:00+00:00",
  "destination_bucket": "edc-celigo-netsuite-prod",
  "errors": []
}
```

### HTTP Status Code Reference

| Code | Meaning |
|---|---|
| `200` | Single file uploaded successfully |
| `207` | Batch processed; at least one file succeeded (check `errors` for partial failures) |
| `400` | Bad request: malformed JSON, missing `files`/`fullUrl`, upstream `success: false`, non-PDF content, batch where all files failed |
| `401` | Missing or invalid bearer token |
| `403` | URL host not in SSRF allowlist |
| `500` | GCS write error |

---

## GCS Object Layout

Files are stored at:
```
{DESTINATION_BUCKET}/{billing_account_id}/{file_name}.pdf
```

Example:
```
edc-celigo-netsuite-prod/
  surprisingly_zebra/
    INV23112430044.pdf       ← metadata: invoiceNumber, customerName, invoiceDate, ...
    INV23112430089.pdf
  treaties_paid/
    INV23112430101.pdf
  unknown_billing_account_id/
    file_20240115103000.pdf  ← billing account ID was absent
  invalid_billing_account_format/
    INV23112430102.pdf       ← billing account ID failed regex
```

All fields from the request payload are stored as **GCS object metadata** (string values). This means invoice number, customer name, date, row number, and any other fields sent by Celigo are retrievable from the object without downloading the PDF.

---

## Security Model

| Layer | Mechanism |
|---|---|
| Request authentication | Bearer token, checked before any processing |
| Token storage | Google Secret Manager (`celigo-gcs-worker-tokens:latest`) |
| SSRF prevention | URL host whitelist: only `https://5260239.app.netsuite.com` by default |
| PDF validation | Three-factor OR: Content-Type + URL extension + `%PDF-` magic bytes |
| Path traversal | `sanitize_billing_account_id` strips `..`, `/`, `\`; regex validates result |
| Log scrubbing | `sanitize_request_for_logging` redacts token/key/secret fields |
| Cloud Function auth | Deployed `--allow-unauthenticated` (Celigo cannot present GCP IAM tokens) — security is entirely application-level bearer tokens |

---

## Local Development

```bash
# 1. Create .env file
cat > .env << 'EOF'
DESTINATION_BUCKET=edc-celigo-netsuite-test
AUTHORIZED_TOKENS=my-local-test-token
ALLOWED_NETSUITE_HOST=https://5260239-sb1.app.netsuite.com
LOG_LEVEL=DEBUG
LOG_RESPONSE_DETAILS=true
EOF

# 2. Authenticate with GCP
gcloud auth application-default login

# 3. Install dependencies
pip install -r requirements.txt -r requirements-dev.txt

# 4. Start the local server
functions-framework --target=main --port=8080
# or:  source scripts/scripts.sh && run_local

# 5. Test with example payloads
source scripts/scripts.sh
test_legacy_simple my-local-test-token
test_batch_local my-local-test-token
```

---

## Deployment

### Staging (`scripts/deploy_staging.sh`)

Deploys as a **Cloud Function** in the staging project. Provisions the destination bucket and Secret Manager secret if they don't exist.

```bash
./scripts/deploy_staging.sh
```

### Production (`scripts/deploy_prod.sh`)

Deploys as a **Cloud Run** service in the `fivetran-automation` project. Expects pre-existing resources:
- Deployment service account (passed as argument)
- Destination GCS bucket (passed as argument)
- Authorized tokens secret location in Secret Manager (passed as argument)

```bash
./scripts/deploy_prod.sh \
  <deployment-service-account> \
  <destination-bucket> \
  <secret-resource-path>
```

The service account needs:
- `roles/storage.objectAdmin` on the destination bucket
- `roles/secretmanager.secretAccessor` on the tokens secret

### Manual `gcloud` deploy (dev/test)

```bash
gcloud functions deploy celigo-gcs-worker \
  --runtime python310 \
  --trigger-http \
  --service-account celigo-netsuite-wildwest@fivetran-wild-west.iam.gserviceaccount.com \
  --allow-unauthenticated \
  --set-env-vars DESTINATION_BUCKET=edc-celigo-netsuite-test \
  --set-secrets AUTHORIZED_TOKENS=celigo-gcs-worker-tokens:latest \
  --project <your-project-id> \
  --stage-bucket gcf-v2-uploads-818218529370 \
  --entry-point main
```

---

## Token Management

```bash
# Rotate tokens for the default project (fivetran-automation)
./scripts/generate_tokens.sh

# Rotate tokens for a custom project and secret name
./scripts/generate_tokens.sh my-project my-secret-name
```

The script generates a cryptographically secure 32-character token, updates the Secret Manager secret, and prints the token value once for distribution to Celigo.

**Rotating tokens does not require a function redeployment** — the function reads `AUTHORIZED_TOKENS` from the secret at startup (or via secret binding, depending on deployment config).

---

## Dependencies

| Package | Version | Purpose |
|---|---|---|
| `functions-framework` | 3.8.2 | Cloud Function HTTP wrapper |
| `google-cloud-storage` | 3.0.0 | GCS client |
| `requests` | 2.32.3 | HTTP client for NetSuite PDF downloads |
| `flask` | (transitive) | `jsonify` / request object |
| `python-dotenv` | 1.0.1 | `.env` file support for local dev |

Full list: `requirements.txt`. Dev dependencies (pytest, etc.): `requirements-dev.txt`.
