#!/bin/bash
# Celigo NetSuite GCS Worker - Staging Deployment Script
# This script automates the deployment of all resources needed for the staging environment.
# This can be modified for production deployment, but we probably have other considerations there.
#
# Usage: ./deploy_staging.sh [PROJECT_ID] [REGION]
#   PROJECT_ID - Optional. Will default to dulcet-yew-246109 if not provided.
#   REGION     - Optional. Will default to us-central1 if not provided.
#
# When providing a non-default project ID, you will be asked to confirm your intent.

# Exit on error
set -e

# Set variables
DEFAULT_PROJECT_ID="dulcet-yew-246109"  # Eng staging default
PROJECT_ID="${1:-$DEFAULT_PROJECT_ID}"  # Use default if not provided
REGION="${2:-us-central1}"  # Default to us-central1 if not specified

# Confirm intent if project ID is not the default
if [ "$PROJECT_ID" != "$DEFAULT_PROJECT_ID" ]; then
    echo "WARNING: You're deploying to a non-default project: $PROJECT_ID"
    read -p "Are you sure you want to continue? (y/N): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "Deployment cancelled."
        exit 0
    fi
fi
SERVICE_NAME="celigo-netsuite-gcs-worker"
SERVICE_ACCOUNT="${SERVICE_NAME}-sa@${PROJECT_ID}.iam.gserviceaccount.com"
BUCKET_NAME="${PROJECT_ID}-${SERVICE_NAME}"
SECRET_NAME="${SERVICE_NAME}-tokens"
FUNCTION_NAME="${SERVICE_NAME}"

# Generate secure random tokens
if ! command -v openssl &> /dev/null; then
    echo "Error: openssl is required but not installed. Please install openssl."
    exit 1
fi

echo "Generating secure API tokens..."
TOKEN1=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 32)
TOKEN2=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 32)

# Verify tokens were generated successfully
if [ -z "$TOKEN1" ] || [ -z "$TOKEN2" ]; then
    echo "Error: Failed to generate tokens"
    exit 1
fi

SECRET_VALUE="${TOKEN1},${TOKEN2}"

# Create a tokens file to share with users
TOKENS_FILE="celigo_tokens_$(date +%Y%m%d_%H%M%S).txt"

echo "=== Celigo NetSuite GCS Worker - Staging Deployment ==="
echo "Project: $PROJECT_ID $([ "$PROJECT_ID" != "$DEFAULT_PROJECT_ID" ] && echo "(Custom project)")"
echo "Region: $REGION"
echo "Service Account: $SERVICE_ACCOUNT"
echo "GCS Bucket: $BUCKET_NAME"
echo "Secret Name: $SECRET_NAME"
echo "Function Name: $FUNCTION_NAME"

# Ensure gcloud is set to the correct project
echo -e "\n=== Setting project to $PROJECT_ID ==="
gcloud config set project "$PROJECT_ID"

# Create service account
echo -e "\n=== Creating service account ==="
if gcloud iam service-accounts describe "$SERVICE_ACCOUNT" --project="$PROJECT_ID" > /dev/null 2>&1; then
    echo "Service account $SERVICE_ACCOUNT already exists"
else
    gcloud iam service-accounts create "${SERVICE_NAME}-sa" \
        --display-name="Celigo NetSuite GCS Worker Service Account" \
        --project="$PROJECT_ID"
    echo "Service account created successfully"
fi

# Create GCS bucket
echo -e "\n=== Creating GCS bucket ==="
if gsutil ls -p "$PROJECT_ID" "gs://${BUCKET_NAME}" > /dev/null 2>&1; then
    echo "Bucket gs://${BUCKET_NAME} already exists"
else
    # Create bucket with public access prevention enforced and no soft delete
    gcloud storage buckets create "gs://${BUCKET_NAME}" \
        --project="$PROJECT_ID" \
        --location="$REGION" \
        --public-access-prevention \
        --uniform-bucket-level-access \
        --soft-delete-duration=0
    echo "Bucket created successfully"
fi

# Grant service account permissions to write to the bucket
echo -e "\n=== Granting service account permissions to bucket ==="
gsutil iam ch "serviceAccount:${SERVICE_ACCOUNT}:roles/storage.objectAdmin" "gs://${BUCKET_NAME}"
echo "Permissions granted successfully"

# Create Secret for authentication tokens
echo -e "\n=== Creating secret for authentication tokens ==="
if gcloud secrets describe "$SECRET_NAME" --project="$PROJECT_ID" > /dev/null 2>&1; then
    echo "Secret $SECRET_NAME already exists"
else
    echo -n "$SECRET_VALUE" | gcloud secrets create "$SECRET_NAME" \
        --replication-policy="automatic" \
        --data-file=- \
        --project="$PROJECT_ID"
    echo "Secret created successfully"
fi

# Grant service account access to the secret
echo -e "\n=== Granting service account access to secret ==="
gcloud secrets add-iam-policy-binding "$SECRET_NAME" \
    --member="serviceAccount:${SERVICE_ACCOUNT}" \
    --role="roles/secretmanager.secretAccessor" \
    --project="$PROJECT_ID"
echo "Secret access granted successfully"

# Create a stage bucket for Cloud Functions deployment if needed
STAGE_BUCKET="${PROJECT_ID}-gcf-staging"
echo -e "\n=== Ensuring stage bucket exists ==="
if ! gsutil ls -p "$PROJECT_ID" "gs://${STAGE_BUCKET}" > /dev/null 2>&1; then
    # Create staging bucket with the same settings as the main bucket
    gcloud storage buckets create "gs://${STAGE_BUCKET}" \
        --project="$PROJECT_ID" \
        --location="$REGION" \
        --public-access-prevention \
        --uniform-bucket-level-access \
        --soft-delete-duration=0
    echo "Stage bucket created successfully"
else
    echo "Stage bucket already exists"
fi

# Deploy the Cloud Function with environment variables
# DESTINATION_BUCKET: GCS bucket for file storage
# LOG_LEVEL: Logging verbosity (DEBUG, INFO, WARNING, ERROR)
# LOG_SUCCESSFUL_RESPONSES: Whether to log successful file uploads
# LOG_RESPONSE_DETAILS: Whether to include full response details in logs
# ALLOWED_NETSUITE_HOST: Allowed NetSuite host for PDF downloads (SSRF protection)
# GCP_PROJECT: Google Cloud project ID
echo -e "\n=== Deploying Cloud Function ==="
gcloud functions deploy "$FUNCTION_NAME" \
  --runtime python310 \
  --region="$REGION" \
  --trigger-http \
  --service-account="$SERVICE_ACCOUNT" \
  --allow-unauthenticated \
  --set-env-vars="DESTINATION_BUCKET=${BUCKET_NAME},LOG_LEVEL=DEBUG,LOG_SUCCESSFUL_RESPONSES=true,LOG_RESPONSE_DETAILS=true,ALLOWED_NETSUITE_HOST=https://5260239-sb1.app.netsuite.com" \
  --set-secrets="AUTHORIZED_TOKENS=${SECRET_NAME}:latest" \
  --project="$PROJECT_ID" \
  --stage-bucket="$STAGE_BUCKET" \
  --entry-point=main

# Save tokens to file for distribution
echo -e "Celigo NetSuite GCS Worker - API Tokens\nGenerated on: $(date)\nEnvironment: Staging\nProject: ${PROJECT_ID}\n\nToken 1: ${TOKEN1}\nToken 2: ${TOKEN2}\n\nFunction URL: https://${REGION}-${PROJECT_ID}.cloudfunctions.net/${FUNCTION_NAME}\n\nExample usage:\ncurl https://${REGION}-${PROJECT_ID}.cloudfunctions.net/${FUNCTION_NAME} -X POST \\\n  -H \"Content-Type: application/json\" \\\n  -H \"Authorization: Bearer YOUR_TOKEN\" \\\n  -d '{\"fullUrl\":\"https://example.com/path/to/file.pdf\"}'" > "$TOKENS_FILE"

# Set secure permissions on tokens file
chmod 600 "$TOKENS_FILE"

echo -e "\n=== Deployment Complete ==="
echo "Function URL: https://${REGION}-${PROJECT_ID}.cloudfunctions.net/${FUNCTION_NAME}"
echo -e "\nSecure API tokens have been saved to: $TOKENS_FILE"
echo "IMPORTANT: Share this file securely with authorized users only"
echo -e "\nTo test the function:"
echo "curl https://${REGION}-${PROJECT_ID}.cloudfunctions.net/${FUNCTION_NAME} -X POST \\"
echo "  -H \"Content-Type: application/json\" \\"
echo "  -H \"Authorization: Bearer ${TOKEN1}\" \\"
echo "  -d '{\"fullUrl\":\"https://www.antennahouse.com/hubfs/xsl-fo-sample/pdf/basic-link-1.pdf\"}'"

