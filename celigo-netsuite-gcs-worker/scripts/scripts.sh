#!/bin/bash
# Celigo NetSuite GCS Worker - Testing and Deployment Scripts
# This file contains scripts for local development, testing, and deployment

# ====================== LOCAL DEVELOPMENT ======================

# Run local server with debug mode
run_local() {
  echo "Starting local server with debug mode..."
  functions-framework --target=main --debug
}

# Start the server (standard mode)
# Usage: source scripts.sh && functions-framework --target=main
# functions-framework --target=main  # Uncomment to run directly

# ====================== TESTING ENDPOINTS ======================

# Test legacy format (single file)
# This uses a sample PDF URL for testing
test_legacy_simple() {
  if [ -z "$1" ]; then
    echo "Error: Bearer token required. Usage: test_legacy_simple <token>"
    return 1
  fi
  
  echo "Testing legacy format with simple payload..."
  curl localhost:8080 -X POST \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $1" \
  -d '{"fullUrl":"https://www.antennahouse.com/hubfs/xsl-fo-sample/pdf/basic-link-1.pdf"}'
}

# Test legacy format with metadata and _PARENT info
# This uses a more complex payload similar to what NetSuite would send
test_legacy_full() {
  if [ -z "$1" ]; then
    echo "Error: Bearer token required. Usage: test_legacy_full <token>"
    return 1
  fi
  
  echo "Testing legacy format with full metadata..."
  curl localhost:8080 -X POST \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer edistesting" \
  -d '{
    "rownumber": 5,
    "id": 2856927,
    "name": "INV23112432028.pdf",
    "url": "/core/media/media.nl?id=2856927&c=5260239_SB1&h=MuhWj_eE7JYhO_q5Aw5QdH8shBpH6PNcVyDg_APyaVECxgur&_xt=.pdf",
    "fullUrl": "https://www.gov.wales/sites/default/files/inline-documents/2020-01/test-pdf.pdf",
    "billingAccountId": "ed_test",
    "_PARENT": {
      "variable_taskid": "MAPREDUCETASK_02686f157c6b17050417060f6c1d0057380b04061c1168011645074c5a_8f1270feed410595db2f78346ed0507f275e3b4e",
      "variable_message": "Invoice PDF Generation script triggered successfully.",
      "variable_status": true,
      "variable_timestamp": "2025-03-07T21:25:25.296"
    }
  }'
}

# Test new batch format (multiple files)
# This sends a batch of file references to process
test_batch_local() {
  if [ -z "$1" ]; then
    echo "Error: Bearer token required. Usage: test_batch_local <token>"
    return 1
  fi
  
  echo "Testing batch format on local server..."
  curl localhost:8080 -X POST \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $1" \
  -d '{
    "success": true,
    "status": "COMPLETE",
    "files": [
      {
        "rownumber": 1,
        "id": 2856923,
        "name": "INV23112430044.pdf",
        "url": "/core/media/media.nl?id=2856923&c=5260239_SB1&h=oVIpc6IP7VEwN10Z3k_q0HTeTLNv2P2lcyoMZa2ic8qK5lA0&_xt=.pdf",
        "fullUrl": "https://www.antennahouse.com/hubfs/xsl-fo-sample/pdf/basic-link-1.pdf",
        "invoiceNumber": "INV23112430044",
        "customerName": "Acme Corporation",
        "invoiceDate": "2023-11-24"
      },
      {
        "rownumber": 2,
        "id": 2856924,
        "name": "INV23112430950.pdf",
        "url": "/core/media/media.nl?id=2856924&c=5260239_SB1&h=1qDETqu_MDPT3XpHzb7ZZWKuFWpitkCnu840cEJ4nQwAEdZB&_xt=.pdf",
        "fullUrl": "https://cdn.mozilla.net/pdfjs/tracemonkey.pdf",
        "invoiceNumber": "INV23112430950",
        "customerName": "Globex Industries",
        "invoiceDate": "2023-11-24"
      }
    ]
  }'
}

# ====================== PRODUCTION TESTING ======================

# Note: For local testing, you can use these sample PDF URLs:
# - "https://www.antennahouse.com/hubfs/xsl-fo-sample/pdf/basic-link-1.pdf"
# - "https://cdn.mozilla.net/pdfjs/tracemonkey.pdf"

# Test production endpoint with batch format
test_prod_batch() {
  if [ -z "$1" ]; then
    echo "Error: Bearer token required. Usage: test_prod_batch <token>"
    return 1
  fi
  
  echo "Testing batch format on production endpoint..."
  curl https://us-central1-fivetran-wild-west.cloudfunctions.net/celigo-gcs-worker -X POST \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $1" \
  -d '{
    "success": true,
    "status": "COMPLETE",
    "files": [
      {
        "rownumber": 1,
        "id": 2856923,
        "name": "INV23112430044.pdf",
        "url": "/core/media/media.nl?id=2856923&c=5260239_SB1&h=oVIpc6IP7VEwN10Z3k_q0HTeTLNv2P2lcyoMZa2ic8qK5lA0&_xt=.pdf",
        "fullUrl": "https://5260239-sb1.app.netsuite.com/core/media/media.nl?id=2856923&c=5260239_SB1&h=oVIpc6IP7VEwN10Z3k_q0HTeTLNv2P2lcyoMZa2ic8qK5lA0&_xt=.pdf",
        "invoiceNumber": "INV23112430044",
        "customerName": "Acme Corporation",
        "invoiceDate": "2023-11-24"
      },
      {
        "rownumber": 2,
        "id": 2856924,
        "name": "INV23112430950.pdf",
        "url": "/core/media/media.nl?id=2856924&c=5260239_SB1&h=1qDETqu_MDPT3XpHzb7ZZWKuFWpitkCnu840cEJ4nQwAEdZB&_xt=.pdf",
        "fullUrl": "https://5260239-sb1.app.netsuite.com/core/media/media.nl?id=2856924&c=5260239_SB1&h=1qDETqu_MDPT3XpHzb7ZZWKuFWpitkCnu840cEJ4nQwAEdZB&_xt=.pdf",
        "invoiceNumber": "INV23112430950",
        "customerName": "Globex Industries",
        "invoiceDate": "2023-11-24"
      }
    ]
  }'
}

# Test production endpoint with single file format
test_prod_single() {
  if [ -z "$1" ]; then
    echo "Error: Bearer token required. Usage: test_prod_single <token>"
    return 1
  fi
  
  echo "Testing single file format on production endpoint..."
  curl https://us-central1-fivetran-wild-west.cloudfunctions.net/celigo-gcs-worker -X POST \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $1" \
  -d '{"fullUrl":"https://www.antennahouse.com/hubfs/xsl-fo-sample/pdf/basic-link-1.pdf", "billingAccountId": "ed_test", "metadata":{"file_name":"test.pdf"}}'
}

# ====================== DEPLOYMENT ======================

# Deploy to test environment
# This deploys the function with test bucket and settings
deploy_test() {
  echo "Deploying to test environment..."
  gcloud functions deploy celigo-gcs-worker \
  --runtime python310 \
  --trigger-http \
  --service-account celigo-netsuite-wildwest@fivetran-wild-west.iam.gserviceaccount.com \
  --allow-unauthenticated \
  --set-env-vars DESTINATION_BUCKET=edc-celigo-netsuite-test \
  --set-secrets AUTHORIZED_TOKENS=celigo-gcs-worker-tokens:latest \
  --project fivetran-wild-west \
  --stage-bucket gcf-v2-uploads-818218529370 \
  --entry-point main
}

# Usage instructions
echo "==== Celigo NetSuite GCS Worker Scripts ===="
echo "Source this file to make the functions available:"
echo "  source scripts.sh"
echo ""
echo "Available commands:"
echo "  run_local           - Start local server with debug mode"
echo "  test_legacy_simple  - Test legacy format with simple payload"
echo "  test_legacy_full    - Test legacy format with full metadata"
echo "  test_batch_local    - Test batch format locally"
echo "  test_prod_batch     - Test batch format on production endpoint"
echo "  test_prod_single    - Test single file format on production endpoint"
echo "  deploy_test         - Deploy to test environment"
