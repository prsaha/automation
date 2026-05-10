#!/bin/bash
# Test script for logging implementation
# Run the local server with: functions-framework --target=main

echo "=== Testing Authentication Failure (no token) ==="
curl -X POST http://localhost:8080 \
  -H "Content-Type: application/json" \
  -d '{"fullUrl": "https://example.com/test.pdf"}'

echo -e "\n\n=== Testing Authentication Failure (invalid token) ==="
curl -X POST http://localhost:8080 \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer invalid_token_123" \
  -d '{"fullUrl": "https://example.com/test.pdf"}'

echo -e "\n\n=== Testing Invalid JSON ==="
curl -X POST http://localhost:8080 \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TEST_TOKEN" \
  -d 'invalid json'

echo -e "\n\n=== Testing Empty Payload ==="
curl -X POST http://localhost:8080 \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TEST_TOKEN" \
  -d '{}'

echo -e "\n\n=== Testing Invalid Payload Structure ==="
curl -X POST http://localhost:8080 \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TEST_TOKEN" \
  -d '{"someField": "value"}'

echo -e "\n\n=== Testing Single File Request (will fail due to invalid URL) ==="
curl -X POST http://localhost:8080 \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TEST_TOKEN" \
  -d '{
    "fullUrl": "https://invalid-domain.com/test.pdf",
    "name": "test_document",
    "billingAccountId": "test_account"
  }'

echo -e "\n\n=== Testing Single File Request (will succeed) ==="
curl -X POST http://localhost:8080 \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TEST_TOKEN" \
  -d '{
    "fullUrl": "https://5260239-sb1.app.netsuite.com/core/media/media.nl?id=3002981&c=5260239_SB1&h=uSJXF-5cYxvB4HYTHknDQu1EvoXYZgw44rXblFIYF_WLze8y&_xt=.pdf",
    "name": "test_document",
    "billingAccountId": "test_account_success"
  }'

echo -e "\n\n=== Testing Batch Request with Mixed Results ==="
curl -X POST http://localhost:8080 \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TEST_TOKEN" \
  -d '{
    "success": true,
    "status": "COMPLETE",
    "files": [
      {
        "id": 12345,
        "name": "invoice1.pdf",
        "fullUrl": "https://5260239-sb1.app.netsuite.com/core/media/media.nl?id=3002981&c=5260239_SB1&h=uSJXF-5cYxvB4HYTHknDQu1EvoXYZgw44rXblFIYF_WLze8y&_xt=.pdf",
        "billingAccountId": "test_account"
      },
      {
        "id": 12346,
        "name": "missing_url_file.pdf",
        "billingAccountId": "test_account"
      },
      {
        "id": 12347,
        "name": "invoice2.pdf",
        "fullUrl": "https://invalid-domain.com/file2.pdf",
        "billingAccountId": "test_account"
      }
    ]
  }'

echo -e "\n\nDone! Check the logs to see structured logging output."
echo "To see different log levels, set LOG_LEVEL environment variable:"
echo "  LOG_LEVEL=DEBUG functions-framework --target=main"
echo ""
echo "To disable success logging:"
echo "  LOG_SUCCESSFUL_RESPONSES=false functions-framework --target=main"
