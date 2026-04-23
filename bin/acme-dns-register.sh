#!/bin/bash

# acme-dns-register.sh
# Helper to pre-register a domain with your ACME-DNS server
# Generates credentials (account.json) that can be used by Kubernetes/cert-manager
# for automatic certificate renewal

set -euo pipefail

ACMEDNS_API="${ACMEDNS_API:-https://your-acme-dns-server.example.com}"
MODE="register"
if [ "${1:-}" = "--check" ]; then
    MODE="check"
    shift
fi

DOMAIN="${1:-}"
OUTPUT_FILE="${2:-.account.json}"
LNMS_DIR="${LNMS_DIR:-/data}"

# No IP restrictions needed - CNAME registration is done manually by DNS team
ALLOW_FROM='[]'

usage() {
    cat <<EOF
Usage: $0 <domain> [output_file]
    $0 --check

Pre-register a domain with your ACME-DNS server.
Generates credentials (account.json) for use in Kubernetes.

Arguments:
  domain          Domain name to register (e.g., nms.example.com)
  output_file     Where to save the account.json (default: .account.json)

Environment:
  ACMEDNS_API     ACME-DNS server URL (default: https://your-acme-dns-server.example.com)

Example:
  $0 nms.example.com ./my-nms-account.json
    $0 --check

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
    if [ "$MODE" = "register" ]; then
        usage
    fi
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "Error: curl is required but not installed"
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required but not installed"
    exit 1
fi

extract_acmedns_host_from_yaml() {
    local cfg_file="$1"
    awk '
        /^ingress:[[:space:]]*$/ { in_ingress=1; next }
        in_ingress && /^[^[:space:]]/ { in_ingress=0 }
        in_ingress && /^[[:space:]]{2}letsEncrypt:[[:space:]]*$/ { in_le=1; next }
        in_ingress && in_le && /^[[:space:]]{2}[A-Za-z0-9_]+:[[:space:]]*$/ { in_le=0 }
        in_le && /^[[:space:]]{4}acmeDns:[[:space:]]*$/ { in_ad=1; next }
        in_le && in_ad && /^[[:space:]]{4}[A-Za-z0-9_]+:[[:space:]]*$/ { in_ad=0 }
        in_ad && /^[[:space:]]{6}host:[[:space:]]*/ {
            val=substr($0, index($0, ":") + 1)
            sub(/[[:space:]]+#.*$/, "", val)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
            gsub(/^"|"$/, "", val)
            print val
            exit
        }
    ' "$cfg_file" 2>/dev/null
}

is_placeholder_acmedns_host() {
    local host="${1:-}"
    case "$host" in
        ""|auth.domain.com|your-acme-dns-server.example.com)
            return 0
            ;;
    esac

    if [[ "$host" =~ example\.(com|org|net)$ ]] || [[ "$host" =~ ^(test|dev|local)\. ]]; then
        return 0
    fi

    return 1
}

if [[ "$ACMEDNS_API" == "https://your-acme-dns-server.example.com" ]]; then
    ACMEDNS_HOST=""
    RESOLVED_FROM=""
    SCAN_REPORT=""
    SEARCH_FILES=(
        "$LNMS_DIR/lnms-config.yaml"
        "$LNMS_DIR/vault/LibreNMS-Installer/config/lnms-config.yaml"
        "$LNMS_DIR/vault/LibreNMS-Helm/values.yaml"
    )

    for CFG_FILE in "${SEARCH_FILES[@]}"; do
        if [ ! -f "$CFG_FILE" ]; then
            SCAN_REPORT+="\n - missing: $CFG_FILE"
            continue
        fi

        ACMEDNS_HOST=$(extract_acmedns_host_from_yaml "$CFG_FILE")
        if [ -z "$ACMEDNS_HOST" ]; then
            SCAN_REPORT+="\n - no acmeDns.host in: $CFG_FILE"
            continue
        fi

        if is_placeholder_acmedns_host "$ACMEDNS_HOST"; then
            SCAN_REPORT+="\n - placeholder acmeDns.host ('$ACMEDNS_HOST') in: $CFG_FILE"
            continue
        fi

        SCAN_REPORT+="\n - resolved acmeDns.host ('$ACMEDNS_HOST') from: $CFG_FILE"
        RESOLVED_FROM="$CFG_FILE"
        break
    done

    if [ -n "$ACMEDNS_HOST" ]; then
        case "$ACMEDNS_HOST" in
            http://*|https://*)
                ACMEDNS_API="$ACMEDNS_HOST"
                ;;
            *)
                ACMEDNS_API="https://$ACMEDNS_HOST"
                ;;
        esac
        echo "Using ACME-DNS host from $RESOLVED_FROM"
    fi
fi

if [[ "$ACMEDNS_API" == "https://your-acme-dns-server.example.com" ]]; then
    echo "Error: ACMEDNS_API is still set to the placeholder URL."
    if [ -n "${SCAN_REPORT:-}" ]; then
        echo "Resolution details:$SCAN_REPORT"
    fi
    echo "Set ACMEDNS_API or configure ingress.letsEncrypt.acmeDns.host in one of these files:"
    echo "  - $LNMS_DIR/lnms-config.yaml"
    echo "  - $LNMS_DIR/vault/LibreNMS-Installer/config/lnms-config.yaml"
    echo "  - $LNMS_DIR/vault/LibreNMS-Helm/values.yaml"
    exit 1
fi

if [ "$MODE" = "check" ]; then
    echo "ACME-DNS API resolved successfully: $ACMEDNS_API"
    if [ -n "${RESOLVED_FROM:-}" ]; then
        echo "Source: $RESOLVED_FROM"
    elif [ -n "${ACMEDNS_API:-}" ]; then
        echo "Source: ACMEDNS_API environment variable"
    fi
    if [ -n "${SCAN_REPORT:-}" ]; then
        echo "Resolution details:$SCAN_REPORT"
    fi
    exit 0
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
if ! RESPONSE=$(curl --silent --show-error --fail \
    --connect-timeout 10 --max-time 30 \
    -X POST "$ACMEDNS_API/register" \
    -H "Content-Type: application/json" \
    -d "{\"allowfrom\": $ALLOW_FROM}"); then
    echo "Error: failed to contact ACME-DNS register endpoint: $ACMEDNS_API/register"
    echo "Check DNS reachability, TLS trust, and ACMEDNS_API value."
    exit 1
fi

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
echo "  Email to: <dns-admin@your-org>"
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
