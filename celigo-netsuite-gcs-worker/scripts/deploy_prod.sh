#!/bin/bash

# Deploy Celigo NetSuite GCS Worker to Production
# This script deploys the function to Cloud Run in the fivetran-automation project
# It expects all resources to already exist (will not create them)

set -e

# Configuration
PROJECT_ID="fivetran-automation"
REGION="us-central1"
FUNCTION_NAME="celigo-netsuite-gcs-worker"
RUNTIME="python310"
ENTRY_POINT="main"
STAGE_BUCKET="syseng-gcf-staging"

# Default values (can be overridden by environment variables)
DESTINATION_BUCKET="${DESTINATION_BUCKET:-prod-netsuite-data}"
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-netsuite-worker-prod-sa@fivetran-automation.iam.gserviceaccount.com}"
AUTHORIZED_TOKENS_SECRET="${AUTHORIZED_TOKENS_SECRET:-celigo-gcs-worker-tokens:latest}"

echo "=== Deploying Celigo NetSuite GCS Worker to Production ==="
echo "Project: ${PROJECT_ID}"
echo "Region: ${REGION}"
echo "Function: ${FUNCTION_NAME}"
echo "Service Account: ${SERVICE_ACCOUNT}"
echo "Destination Bucket: ${DESTINATION_BUCKET}"
echo "Authorized Tokens Secret: ${AUTHORIZED_TOKENS_SECRET}"
echo ""

# Confirm deployment
read -p "Do you want to proceed with the deployment? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Deployment cancelled."
    exit 1
fi

# Deploy the function
echo "Deploying function..."
gcloud functions deploy "${FUNCTION_NAME}" \
  --runtime "${RUNTIME}" \
  --trigger-http \
  --service-account "${SERVICE_ACCOUNT}" \
  --allow-unauthenticated \
  --set-env-vars "DESTINATION_BUCKET=${DESTINATION_BUCKET},LOG_LEVEL=INFO,LOG_SUCCESSFUL_RESPONSES=true,LOG_RESPONSE_DETAILS=true" \
  --set-secrets "AUTHORIZED_TOKENS=${AUTHORIZED_TOKENS_SECRET}" \
  --project "${PROJECT_ID}" \
  --region "${REGION}" \
  --stage-bucket "${STAGE_BUCKET}" \
  --entry-point "${ENTRY_POINT}" \
  --timeout 540s \
  --max-instances 100

echo ""
echo "=== Deployment Complete ==="
echo "Function URL: https://${REGION}-${PROJECT_ID}.cloudfunctions.net/${FUNCTION_NAME}"
echo ""
echo "Note: Ensure the service account has:"
echo "  - Storage Object Admin on bucket: ${DESTINATION_BUCKET}"
echo "  - Secret Manager Secret Accessor on secret: ${AUTHORIZED_TOKENS_SECRET}"
