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
    
    # Ensure cert-manager namespace exists (it might be created by ArgoCD later, but we need it for the secret)
    kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -

    kubectl create secret generic duckdns-secret \
        --namespace cert-manager \
        --from-literal=token="$DUCKDNS_TOKEN" \
        --dry-run=client -o yaml | kubectl apply -f -
else
    echo "⚠️  Warning: DUCKDNS_TOKEN not set in .env, skipping..."
fi

# 4. Create ArgoCD Repository Secret
# Needed for ArgoCD to access your private Git repository via SSH
if [ -n "$ARGOCD_REPO_URL" ] && [ -n "$ARGOCD_SSH_KEY_PATH" ]; then
    echo "🐙 Creating 'argocd-repo-secret'..."
    
    # Ensure argocd namespace exists
    kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

    if [ -f "$ARGOCD_SSH_KEY_PATH" ]; then
        # Read the private key content
        SSH_KEY_CONTENT=$(cat "$ARGOCD_SSH_KEY_PATH")
        
        # Create the secret with specific labels for ArgoCD
        kubectl create secret generic argocd-repo-secret \
            --namespace argocd \
            --from-literal=type="git" \
            --from-literal=url="$ARGOCD_REPO_URL" \
            --from-literal=sshPrivateKey="$SSH_KEY_CONTENT" \
            --dry-run=client -o yaml | \
            kubectl label --local -f - -o yaml \
            "argocd.argoproj.io/secret-type=repository" | \
            kubectl apply -f -
    else
         echo "❌ Error: SSH Key file not found at $ARGOCD_SSH_KEY_PATH!"
    fi
else
    echo "⚠️  Warning: ARGOCD_REPO_URL or ARGOCD_SSH_KEY_PATH not set in .env, skipping ArgoCD secret..."
fi

echo "✅ Success! All secrets have been processed."