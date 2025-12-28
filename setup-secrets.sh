#!/bin/bash

# Define the path to the .env file
ENV_FILE=".env"

echo "🚀 Starting secret generation process..."

# 1. Check if .env file exists
if [ -f "$ENV_FILE" ]; then
    echo "📂 Loading environment variables from $ENV_FILE..."
    # Export variables ignoring comments
    export $(grep -v '^#' $ENV_FILE | xargs)
else
    echo "❌ Error: $ENV_FILE not found!"
    echo "   Please run: cp .env.example .env"
    echo "   And fill it with your real secrets."
    exit 1
fi

# 2. Create Postgres Secret
# Target Namespace: default (or change to where your DB lives)
if [ -n "$POSTGRES_PASSWORD" ]; then
    echo "🐘 Creating 'postgres-secret'..."
    kubectl create secret generic postgres-secret \
        --namespace default \
        --from-literal=password="$POSTGRES_PASSWORD" \
        --dry-run=client -o yaml | kubectl apply -f -
else
    echo "⚠️  Warning: POSTGRES_PASSWORD not set in .env, skipping..."
fi

# 3. Create DuckDNS Token Secret
# Usually needed for DDNS updaters or Cert-Manager
if [ -n "$DUCKDNS_TOKEN" ]; then
    echo "🦆 Creating 'duckdns-secret'..."
    kubectl create secret generic duckdns-secret \
        --namespace default \
        --from-literal=token="$DUCKDNS_TOKEN" \
        --dry-run=client -o yaml | kubectl apply -f -
else
    echo "⚠️  Warning: DUCKDNS_TOKEN not set in .env, skipping..."
fi

echo "✅ Success! All secrets have been processed."