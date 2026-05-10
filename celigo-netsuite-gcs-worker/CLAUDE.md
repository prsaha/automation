# CLAUDE.md - Celigo NetSuite GCS Worker

## Commands

- Run local server: `functions-framework --target=main`
- Test legacy API: `curl localhost:8080 -X POST -H "Content-Type: application/json" -d '{"url":"PDF_URL"}'`
- Test batch API: See scripts.sh for the full JSON schema example
- Deploy to GCP (dev/experimental): `gcloud functions deploy celigo-gcs-worker --runtime python310 --trigger-http --service-account celigo-netsuite-wildwest@fivetran-wild-west.iam.gserviceaccount.com --allow-unauthenticated --set-env-vars DESTINATION_BUCKET=edc-celigo-netsuite-test --project fivetran-wild-west --stage-bucket gcf-v2-uploads-818218529370 --entry-point main`
- Install dependencies: `pip install -r requirements.txt`

## Local Development

- Set GOOGLE_APPLICATION_CREDENTIALS environment variable to point to your service account key file
- Set DESTINATION_BUCKET environment variable to point to a valid bucket
- Optionally set ALLOWED_NETSUITE_HOST to override the default allowed NetSuite host (default: https://5260239.app.netsuite.com)

## Logging Configuration

The service uses structured JSON logging optimized for Google Cloud Run. Configure logging with these environment variables:

- `LOG_LEVEL`: Set logging verbosity (default: INFO). Options: DEBUG, INFO, WARNING, ERROR
- `LOG_SUCCESSFUL_RESPONSES`: Enable/disable logging of successful file uploads (default: true)
- `LOG_RESPONSE_DETAILS`: Include full response details in logs (default: false)

All logs include:
- Request ID for correlation
- Timestamp
- Operation context
- File names and paths (non-sensitive data)
- Error details when applicable

Sensitive data like auth tokens are automatically redacted from logs.

## Code Style Guidelines

- **Imports**: Standard library first, then third-party, then local modules
- **Formatting**: Follow PEP 8 guidelines. Lint and format with Ruff.
- **Types**: Use type hints for function parameters and return values
- **Naming**: Snake case for variables/functions, PascalCase for classes
- **Error Handling**: Use try/except with specific exception types
- **Line Length**: Max 88 characters
- **Environment Variables**: Required env vars should be checked at startup
- **Documentation**: Use docstrings for functions and modules
- **Testing**: HTTP API endpoints should have curl examples in scripts.sh
- **General**: Stick to pythonic patterns
- **Linting and Formatting**: Use Ruff to lint and format code
- **Python Guidelines**: PEP8 and PEP20 are important

## API Schema

This service supports two API formats:

1. Legacy format (single file):

```json
{
  "url": "https://example.com/path/to/file.pdf",
  "metadata": {
    "file_name": "custom_name.pdf" // optional
  }
}
```

2. Batch format (multiple files):

```json
{
  "success": true,
  "status": "COMPLETE",
  "files": [
    {
      "id": 12345,
      "name": "invoice.pdf",
      "url": "/relative/path",
      "fullUrl": "https://absolute/path/to/file.pdf"
      // Additional metadata fields will be stored with the file
    }
  ]
}
```

## Session Best Practices

- When starting a new session and after completing a feature or commit, re-familiarize yourself with the project documentation, structure, and CLAUDE.md. In particular, make sure to understand what main.py does.