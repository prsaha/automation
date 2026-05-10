#!/bin/bash

# Generate secure authorized tokens for the Celigo GCS Worker
# This script creates new random tokens and updates the secret in Google Secret Manager

set -e

# Default values (can be overridden by command line arguments)
PROJECT_ID="${1:-fivetran-automation}"
SECRET_NAME="${2:-celigo-gcs-worker-tokens}"
TOKEN_LENGTH=32  # 32 bytes = 256 bits of entropy
NUM_TOKENS=2     # Generate 2 tokens by default

echo "=== Generate Authorized Tokens for Celigo GCS Worker ==="
echo "Project: ${PROJECT_ID}"
echo "Secret Name: ${SECRET_NAME}"
echo ""

# Function to generate a secure random token
generate_token() {
    # Use /dev/urandom to generate cryptographically secure random bytes
    # Convert to base64 and remove special characters to make it URL-safe
    openssl rand -base64 ${TOKEN_LENGTH} | tr -d "=+/" | cut -c1-${TOKEN_LENGTH}
}

# Check if the secret exists
echo "Checking if secret exists..."
if gcloud secrets describe ${SECRET_NAME} --project=${PROJECT_ID} &>/dev/null; then
    echo "Secret '${SECRET_NAME}' exists in project '${PROJECT_ID}'."
    
    # Get current version info
    CURRENT_VERSION=$(gcloud secrets versions list ${SECRET_NAME} --project=${PROJECT_ID} --limit=1 --format="value(name)")
    echo "Current version: ${CURRENT_VERSION}"
else
    echo "Secret '${SECRET_NAME}' does not exist in project '${PROJECT_ID}'."
    echo "You'll need to create it first with:"
    echo "  gcloud secrets create ${SECRET_NAME} --project=${PROJECT_ID}"
    exit 1
fi

echo ""
echo "WARNING: This will create a new version of the secret with new tokens."
echo "Any applications using the current tokens will need to be updated."
echo ""

# Confirm action
read -p "Do you want to generate new tokens and update the secret? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Token generation cancelled."
    exit 1
fi

# Generate tokens
echo ""
echo "Generating ${NUM_TOKENS} secure tokens..."
TOKENS=()
for i in $(seq 1 ${NUM_TOKENS}); do
    TOKEN=$(generate_token)
    TOKENS+=("${TOKEN}")
    echo "Token ${i}: ${TOKEN}"
done

# Join tokens with commas
TOKENS_STRING=$(IFS=,; echo "${TOKENS[*]}")

# Create a temporary file for the secret data
TEMP_FILE=$(mktemp)
echo -n "${TOKENS_STRING}" > "${TEMP_FILE}"

# Update the secret
echo ""
echo "Updating secret in Google Secret Manager..."
gcloud secrets versions add ${SECRET_NAME} \
    --project=${PROJECT_ID} \
    --data-file="${TEMP_FILE}"

# Clean up
rm -f "${TEMP_FILE}"

echo ""
echo "=== Token Generation Complete ==="
echo "New tokens have been stored in secret: ${SECRET_NAME}"
echo "Project: ${PROJECT_ID}"
echo ""
echo "To use these tokens:"
echo "1. Share individual tokens with applications that need to call the function"
echo "2. Include the token in requests as: Authorization: Bearer <token>"
echo ""
echo "To view the current tokens (be careful with this!):"
echo "  gcloud secrets versions access latest --secret=${SECRET_NAME} --project=${PROJECT_ID}"