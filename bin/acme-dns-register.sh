#!/bin/bash

# acme-dns-register.sh
# Helper to pre-register a domain with corporate ACME-DNS server (auth.vist.is)
# Generates credentials (account.json) that can be used by Kubernetes/cert-manager
# for automatic certificate renewal

set -euo pipefail

ACMEDNS_API="${ACMEDNS_API:-https://auth.vist.is}"
DOMAIN="${1:-}"
OUTPUT_FILE="${2:-.account.json}"

# IP ranges allowed to update DNS records (Sensa AS internal)
ALLOW_FROM='["10.0.0.0/8","192.168.0.0/16","172.16.0.0/12","185.62.60.0/22","79.171.96.0/21","185.67.180.0/22","185.130.12.0/22"]'

usage() {
    cat <<EOF
Usage: $0 <domain> [output_file]

Pre-register a domain with the corporate ACME-DNS server (auth.vist.is).
Generates credentials (account.json) for use in Kubernetes.

Arguments:
  domain          Domain name to register (e.g., nms.example.vist.is)
  output_file     Where to save the account.json (default: .account.json)

Environment:
  ACMEDNS_API     ACME-DNS server URL (default: https://auth.vist.is)

Example:
  $0 nms.example.vist.is ./my-nms-account.json

Output:
  Creates account.json with:
    - username, password (credentials for DNS updates)
    - fulldomain (CNAME to register at corporate DNS)
    - subdomain (ACME-DNS subdomain)
    - server_url (API endpoint)

Next steps:
  1. Email the 'fulldomain' value to the corporate DNS team
  2. Wait for them to register the CNAME in their DNS
  3. Create Kubernetes secret:
     kubectl create secret generic acme-dns-credentials \\
       --from-file=acme-dns-account.json=$OUTPUT_FILE \\
       -n librenms
EOF
    exit 1
}

if [ -z "$DOMAIN" ]; then
    usage
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "Error: curl is required but not installed"
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required but not installed"
    exit 1
fi

echo "=========================================="
echo "ACME-DNS Pre-Registration Helper"
echo "=========================================="
echo ""
echo "Domain:    $DOMAIN"
echo "ACME-DNS:  $ACMEDNS_API"
echo "Output:    $OUTPUT_FILE"
echo ""

# Call ACME-DNS /register endpoint
echo "Contacting ACME-DNS server..."
RESPONSE=$(curl -s -X POST "$ACMEDNS_API/register" \
    -H "Content-Type: application/json" \
    -d "{\"allowfrom\": $ALLOW_FROM}")

# Check if request succeeded
if ! echo "$RESPONSE" | jq . >/dev/null 2>&1; then
    echo "Error: Failed to register domain. Response:"
    echo "$RESPONSE"
    exit 1
fi

# Extract credential fields
USERNAME=$(echo "$RESPONSE" | jq -r '.username')
PASSWORD=$(echo "$RESPONSE" | jq -r '.password')
SUBDOMAIN=$(echo "$RESPONSE" | jq -r '.subdomain')
FULLDOMAIN=$(echo "$RESPONSE" | jq -r '.fulldomain')

if [ "$USERNAME" = "null" ] || [ "$PASSWORD" = "null" ]; then
    echo "Error: Invalid response from ACME-DNS server"
    echo "$RESPONSE"
    exit 1
fi

# Create account.json structure
cat > "$OUTPUT_FILE" <<EOF
{
    "$DOMAIN": {
        "fulldomain": "$FULLDOMAIN",
        "subdomain": "$SUBDOMAIN",
        "username": "$USERNAME",
        "password": "$PASSWORD",
        "server_url": "$ACMEDNS_API"
    }
}
EOF

chmod 600 "$OUTPUT_FILE"

echo "✓ Credentials generated successfully!"
echo ""
echo "=========================================="
echo "ACTION REQUIRED: Register CNAME at Corporate DNS"
echo "=========================================="
echo ""
echo "Send the following CNAME to the corporate DNS team:"
echo "  Email to: <dns-admin@corp>"
echo "  Subject:  ACME-DNS CNAME Registration Request"
echo ""
echo "  --- BEGIN CNAME REQUEST ---"
echo "  Domain: $DOMAIN"
echo "  CNAME:  $FULLDOMAIN"
echo "  --- END CNAME REQUEST ---"
echo ""
echo "Wait for confirmation that the CNAME is registered before continuing."
echo ""
echo "=========================================="
echo "Next Steps: Create Kubernetes Secret"
echo "=========================================="
echo ""
echo "Once the CNAME is registered, create the secret in your K8s cluster:"
echo ""
echo "  kubectl create secret generic acme-dns-credentials \\"
echo "    --from-file=acme-dns-account.json=$OUTPUT_FILE \\"
echo "    -n librenms"
echo ""
echo "Then run: nms start"
echo ""
echo "Full account.json (for reference):"
cat "$OUTPUT_FILE" | jq .
echo ""
