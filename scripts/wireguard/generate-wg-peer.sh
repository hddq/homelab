#!/usr/bin/env bash
set -e

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <peer_name> <peer_ip>"
    echo "Example: $0 phone 192.168.70.3"
    exit 1
fi

PEER_NAME=$1
PEER_IP=$2

# ==========================================
# CONFIGURATION
# ==========================================
SERVER_PUBKEY="bRTrqKoceGLGo6i+W0ua9ubPVk6fcwaeAT3Lx/TVBiY="
SERVER_ENDPOINT="130.61.233.3:51820"
ALLOWED_IPS="192.168.40.0/24, 192.168.41.0/24, 192.168.70.2/32"
DNS_SERVERS="192.168.70.2, 192.168.41.13"
# ==========================================

# Ensure required tools exist
if ! command -v wg &> /dev/null; then
    echo "Error: 'wg' command not found."
    exit 1
fi
if ! command -v qrencode &> /dev/null; then
    echo "Error: 'qrencode' command not found."
    exit 1
fi

mkdir -p "wg-clients/$PEER_NAME"
cd "wg-clients/$PEER_NAME"

echo "Generating keys for $PEER_NAME..."
PRIVKEY=$(wg genkey)
PUBKEY=$(echo "$PRIVKEY" | wg pubkey)

CONF_FILE="${PEER_NAME}.conf"

cat > "$CONF_FILE" <<EOF
[Interface]
PrivateKey = $PRIVKEY
Address = $PEER_IP/32
DNS = $DNS_SERVERS

[Peer]
PublicKey = $SERVER_PUBKEY
Endpoint = $SERVER_ENDPOINT
AllowedIPs = $ALLOWED_IPS
EOF

echo ""
echo "======================================================"
echo "✅ Config generated at wg-clients/$PEER_NAME/$CONF_FILE"
echo "======================================================"
echo ""
echo "📱 Here is the QR code for your device:"
echo ""
qrencode -t ansiutf8 < "$CONF_FILE"
echo ""
echo "======================================================"
echo "💻 Add this block to your configuration.nix (under wg0 peers):"
echo "======================================================"
cat <<EOF
          {
            # $PEER_NAME
            publicKey = "$PUBKEY";
            allowedIPs = [ "$PEER_IP/32" ];
          }
EOF
echo "======================================================"
