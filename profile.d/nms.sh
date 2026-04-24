#!/bin/bash

resolve_lnms_exec_target() {
    local namespace="${1:-librenms}"
    local target_pod
    local target_container
    local containers

    # Try common labels first, then fall back to a running pod name match.
    target_pod=$(kubectl get pod -n "$namespace" -l app.kubernetes.io/component=dispatcher -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -z "$target_pod" ]; then
        target_pod=$(kubectl get pod -n "$namespace" -l app.kubernetes.io/name=librenms,app.kubernetes.io/component=app -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    fi
    if [ -z "$target_pod" ]; then
        target_pod=$(kubectl get pods -n "$namespace" --field-selector=status.phase=Running --no-headers 2>/dev/null | awk '/(dispatcher|lnms-app|librenms)/ {print $1; exit}')
    fi

    if [ -z "$target_pod" ]; then
        return 1
    fi

    containers=$(kubectl get pod -n "$namespace" "$target_pod" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null || true)
    for target_container in $containers; do
        if kubectl exec -n "$namespace" "$target_pod" -c "$target_container" -- sh -c 'command -v lnms >/dev/null 2>&1 || [ -x /usr/bin/lnms ]' >/dev/null 2>&1; then
            echo "$target_pod $target_container"
            return 0
        fi
    done

    return 1
}

lnms() {
    local namespace="librenms"
    local target_pod
    local target_container

    if ! read -r target_pod target_container < <(resolve_lnms_exec_target "$namespace"); then
        echo "Error: LibreNMS pod not found in namespace $namespace."
        return 1
    fi

    kubectl exec --namespace="$namespace" --stdin --tty "$target_pod" -c "$target_container" -- lnms "$@"
}

ensure_cert_manager_from_values() {
    local lnms_dir="${1:-/data}"
    local namespace="${2:-librenms}"
    local cfg="$lnms_dir/lnms-config.yaml"
    local ingress_https=""
    local tls_existing_secret_name=""
    local le_enabled=""

    normalize_bool() {
        local raw="${1:-}"
        raw=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')
        case "$raw" in
            true|yes|on|1)
                echo "true"
                ;;
            *)
                echo "false"
                ;;
        esac
    }

    if [ ! -f "$cfg" ]; then
        echo "Skipping cert-manager setup: values file not found at $cfg"
        return 0
    fi

    ingress_https=$(awk '
        /^ingress:[[:space:]]*$/ { in_ingress=1; next }
        in_ingress && /^[^[:space:]]/ { in_ingress=0 }
        in_ingress && /^[[:space:]]{2}https:[[:space:]]*/ {
            val=$2
            gsub(/"/, "", val)
            print val
            exit
        }
    ' "$cfg" 2>/dev/null)

    tls_existing_secret_name=$(awk '
        /^ingress:[[:space:]]*$/ { in_ingress=1; next }
        in_ingress && /^[^[:space:]]/ { in_ingress=0 }
        in_ingress && /^[[:space:]]{2}tls:[[:space:]]*$/ { in_tls=1; next }
        in_ingress && in_tls && /^[[:space:]]{2}[A-Za-z0-9_]+:[[:space:]]*$/ { in_tls=0 }
        in_tls && /^[[:space:]]{4}existingSecretName:[[:space:]]*/ {
            val=substr($0, index($0, ":") + 1)
            sub(/[[:space:]]+#.*$/, "", val)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
            gsub(/^"|"$/, "", val)
            print val
            exit
        }
    ' "$cfg" 2>/dev/null)

    le_enabled=$(awk '
        /^ingress:[[:space:]]*$/ { in_ingress=1; next }
        in_ingress && /^[^[:space:]]/ { in_ingress=0 }
        in_ingress && /^[[:space:]]{2}letsEncrypt:[[:space:]]*$/ { in_le=1; next }
        in_ingress && in_le && /^[[:space:]]{2}[A-Za-z0-9_]+:[[:space:]]*$/ { in_le=0 }
        in_le && /^[[:space:]]{4}enabled:[[:space:]]*/ {
            val=$2
            gsub(/"/, "", val)
            print val
            exit
        }
    ' "$cfg" 2>/dev/null)

    if [ "$(normalize_bool "$ingress_https")" != "true" ]; then
        echo "Skipping cert-manager setup: ingress.https is not enabled."
        return 0
    fi

    if [ -n "$tls_existing_secret_name" ]; then
        echo "Skipping cert-manager setup: ingress.tls.existingSecretName is set ($tls_existing_secret_name)."
        return 0
    fi

    if [ "$(normalize_bool "$le_enabled")" != "true" ]; then
        echo "Skipping cert-manager setup: ingress.letsEncrypt.enabled is not enabled."
        return 0
    fi

    echo "Preparing cert-manager controller from values file..."

    if ! kubectl get namespace cert-manager >/dev/null 2>&1; then
        kubectl create namespace cert-manager >/dev/null || return 1
    fi

    helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
    helm repo update >/dev/null || return 1

    if helm status cert-manager -n cert-manager >/dev/null 2>&1; then
        helm upgrade cert-manager jetstack/cert-manager -n cert-manager --set crds.enabled=true --wait --timeout 5m || return 1
    else
        helm install cert-manager jetstack/cert-manager -n cert-manager --set crds.enabled=true --wait --timeout 5m || return 1
    fi

    kubectl rollout status deployment/cert-manager -n cert-manager --timeout=180s || return 1
    kubectl rollout status deployment/cert-manager-cainjector -n cert-manager --timeout=180s || return 1
    kubectl rollout status deployment/cert-manager-webhook -n cert-manager --timeout=180s || return 1

    echo "cert-manager ready for namespace $namespace."
}

nms() {
    local action="$1"
    shift || true
    local LNMS_DIR="${LNMS_DIR:-/data}"
    local KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
    local NAMESPACE="${NMS_NAMESPACE:-librenms}"
    local NO_EDITOR="${NMS_NO_EDITOR:-0}"
    local AUTO_ADD_HOST="${NMS_AUTO_ADD_HOST:-1}"
    local AUTO_ADD_HOST_READY=1
    local SNMP_COMMUNITY="${NMS_SNMP_COMMUNITY:-locallibremon}"
    local SNMP_PORT="${NMS_SNMP_PORT:-1161}"

    export KUBECONFIG

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --non-interactive|-n)
                NO_EDITOR=1
                ;;
            --interactive)
                NO_EDITOR=0
                ;;
            --no-auto-add-host)
                AUTO_ADD_HOST=0
                ;;
            --auto-add-host)
                AUTO_ADD_HOST=1
                ;;
            --)
                shift
                break
                ;;
            -*)
                echo "Error: unknown option '$1'."
                echo "Usage: nms {start|stop|edit|update|status|monitor|cert|map|preflight|help} [--non-interactive] [--no-auto-add-host]"
                return 1
                ;;
            *)
                break
                ;;
        esac
        shift
    done

    get_host_ip() {
        local selected_ip

        if [ -n "${NMS_HOST_IP:-}" ]; then
            echo "$NMS_HOST_IP"
            return 0
        fi

        # Prefer kernel routing decision for outbound traffic when available.
        selected_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}')
        if [ -n "$selected_ip" ]; then
            echo "$selected_ip"
            return 0
        fi

        # Fallback to first non-virtual global IPv4 address.
        selected_ip=$(ip -o -4 addr show up scope global 2>/dev/null | awk '$2 !~ /^(lo|docker|cni|flannel|veth|virbr|br-|kube-ipvs0)/ {split($4, a, "/"); print a[1]; exit}')
        if [ -n "$selected_ip" ]; then
            echo "$selected_ip"
            return 0
        fi

        # Last resort: first host IPv4 from hostname.
        hostname -I 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i !~ /^127\./) {print $i; exit}}'
    }

    extract_first_ipv4() {
        awk '/Your IP:/ {print $3; exit}'
    }

    get_external_ip_hint() {
        local probe_output
        local external_ip

        if ! command -v wget >/dev/null 2>&1; then
            return 1
        fi

        probe_output=$(wget -qO- portquiz.net:80 2>/dev/null || true)
        external_ip=$(printf '%s\n' "$probe_output" | extract_first_ipv4)
        if [ -z "$external_ip" ]; then
            external_ip=$(printf '%s\n' "$probe_output" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1)
        fi
        if [ -n "$external_ip" ]; then
            echo "$external_ip"
            return 0
        fi

        probe_output=$(wget -qO- portquiz.net:443 2>/dev/null || true)
        external_ip=$(printf '%s\n' "$probe_output" | extract_first_ipv4)
        if [ -z "$external_ip" ]; then
            external_ip=$(printf '%s\n' "$probe_output" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1)
        fi
        if [ -n "$external_ip" ]; then
            echo "$external_ip"
            return 0
        fi

        return 1
    }

    get_fqdn_from_values() {
        awk '
            /^[[:space:]]*application:[[:space:]]*$/ { in_app=1; next }
            in_app && /^[[:space:]]*host:[[:space:]]*$/ { in_host=1; next }
            in_host && /^[[:space:]]*FQDN:[[:space:]]*/ {
                gsub(/"/, "", $2)
                print $2
                exit
            }
            in_app && /^[[:space:]]*[a-zA-Z0-9_]+:[[:space:]]*$/ && $1 !~ /^host:$/ { in_host=0 }
        ' "$LNMS_DIR/lnms-config.yaml" 2>/dev/null
    }

    check_snmp_ready() {
        local host_ip="$1"
        local listener_ok=0
        local community_ok=0

        if command -v ss >/dev/null 2>&1; then
            if ss -lunH 2>/dev/null | awk '{print $5}' | grep -Eq "(^|[.:])$SNMP_PORT$"; then
                listener_ok=1
            fi
        elif command -v netstat >/dev/null 2>&1; then
            if netstat -lun 2>/dev/null | awk '{print $4}' | grep -Eq "(^|[.:])$SNMP_PORT$"; then
                listener_ok=1
            fi
        fi

        if grep -RhsE "^[[:space:]]*(rocommunity|rocommunity6)[[:space:]]+$SNMP_COMMUNITY([[:space:]]|$)" /etc/snmp/snmpd.conf /etc/snmp/snmpd.conf.d/*.conf 2>/dev/null | head -n 1 >/dev/null; then
            community_ok=1
        fi

        if [ "$listener_ok" -eq 1 ]; then
            echo "[OK] SNMP UDP port appears open: $SNMP_PORT"
        else
            echo "[WARN] SNMP UDP port not detected as listening: $SNMP_PORT"
        fi

        if [ "$community_ok" -eq 1 ]; then
            echo "[OK] SNMP community found in config: $SNMP_COMMUNITY"
        else
            echo "[WARN] SNMP community not found in /etc/snmp/snmpd.conf*: $SNMP_COMMUNITY"
        fi

        if command -v snmpget >/dev/null 2>&1; then
            if timeout 3 snmpget -v2c -c "$SNMP_COMMUNITY" -Onqv -r 0 -t 1 "$host_ip:$SNMP_PORT" 1.3.6.1.2.1.1.3.0 >/dev/null 2>&1; then
                echo "[OK] SNMP probe succeeded against $host_ip:$SNMP_PORT"
                return 0
            fi
            echo "[WARN] SNMP probe failed against $host_ip:$SNMP_PORT"
            return 1
        fi

        [ "$listener_ok" -eq 1 ] && [ "$community_ok" -eq 1 ]
    }

    wait_for_librenms_ready() {
        local timeout_sec="${1:-240}"
        local pod_name
        local start_ts
        local now_ts

        start_ts=$(date +%s)
        while true; do
            if read -r pod_name _ < <(resolve_lnms_exec_target "$NAMESPACE"); then
                kubectl wait -n "$NAMESPACE" --for=condition=Ready "pod/$pod_name" --timeout="${timeout_sec}s" >/dev/null 2>&1
                return $?
            fi

            now_ts=$(date +%s)
            if [ $((now_ts - start_ts)) -ge "$timeout_sec" ]; then
                return 1
            fi
            sleep 2
        done
    }

    device_already_added() {
        local host_ip="$1"
        local devices_output
        
        # Try to get the device list using report:devices
        devices_output=$(lnms report:devices 2>&1) || return 1
        
        # Check if the IP appears anywhere in the output
        if echo "$devices_output" | grep -q "$host_ip"; then
            return 0
        fi
        
        return 1
    }

    run_preflight() {
        local ok=1
        local fqdn
        local host_ip

        echo "Running preflight checks..."

        if ! command -v kubectl >/dev/null 2>&1; then
            echo "[FAIL] kubectl is not installed or not in PATH."
            ok=0
        else
            echo "[OK] kubectl found."
        fi

        if ! command -v helm >/dev/null 2>&1; then
            echo "[FAIL] helm is not installed or not in PATH."
            ok=0
        else
            echo "[OK] helm found."
        fi

        if [ ! -f "$LNMS_DIR/lnms-config.yaml" ]; then
            echo "[FAIL] values file missing: $LNMS_DIR/lnms-config.yaml"
            ok=0
        else
            echo "[OK] values file exists: $LNMS_DIR/lnms-config.yaml"
        fi

        if [ ! -d "$LNMS_DIR/vault/LibreNMS-Helm" ]; then
            echo "[FAIL] chart path missing: $LNMS_DIR/vault/LibreNMS-Helm"
            ok=0
        else
            echo "[OK] chart path exists: $LNMS_DIR/vault/LibreNMS-Helm"
        fi

        if kubectl cluster-info >/dev/null 2>&1; then
            echo "[OK] Kubernetes API is reachable."
        else
            echo "[FAIL] Kubernetes API is not reachable (check KUBECONFIG and cluster state)."
            ok=0
        fi

        fqdn=$(get_fqdn_from_values)
        if [ -n "$fqdn" ]; then
            if getent hosts "$fqdn" >/dev/null 2>&1; then
                echo "[OK] FQDN resolves: $fqdn"
            else
                echo "[WARN] FQDN does not resolve yet: $fqdn"
            fi
        else
            echo "[WARN] Could not parse application.host.FQDN from values file."
        fi

        if [ "$AUTO_ADD_HOST" -eq 1 ]; then
            host_ip=$(get_host_ip)
            if [ -z "$host_ip" ]; then
                echo "[WARN] Could not determine host IP for SNMP auto-add."
                AUTO_ADD_HOST_READY=0
            elif check_snmp_ready "$host_ip"; then
                echo "[OK] SNMP precheck passed for auto-add target: $host_ip:$SNMP_PORT"
            else
                echo "[WARN] SNMP precheck failed; install will continue but automatic host add will be skipped."
                AUTO_ADD_HOST_READY=0
            fi
        fi

        if [ "$ok" -eq 1 ]; then
            echo "Preflight passed."
            return 0
        fi

        echo "Preflight failed. Fix the failing checks and rerun: nms preflight"
        return 1
    }

    get_librenms_pod() {
        local pod_name
        if read -r pod_name _ < <(resolve_lnms_exec_target "$NAMESPACE"); then
            echo "$pod_name"
            return 0
        fi

        pod_name=$(kubectl get pod -n "$NAMESPACE" -l app.kubernetes.io/name=librenms,app.kubernetes.io/component=app -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
        if [ -n "$pod_name" ]; then
            echo "$pod_name"
            return 0
        fi

        kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | awk '/lnms-app/ {print $1; exit}'
    }

    existing_release_namespace() {
        helm list --all-namespaces --filter '^librenms$' -o json 2>/dev/null | awk -F '"' '/"namespace"/ {print $4; exit}'
    }

    ensure_namespace_exists() {
        if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
            echo "Creating namespace: $NAMESPACE"
            kubectl create namespace "$NAMESPACE" >/dev/null || return 1
        fi
    }

    ensure_namespace_helm_metadata() {
        # Some clusters already have the namespace created manually.
        # Pre-label/annotate it so Helm can adopt a Namespace manifest if present.
        kubectl label namespace "$NAMESPACE" app.kubernetes.io/managed-by=Helm --overwrite >/dev/null || return 1
        kubectl annotate namespace "$NAMESPACE" meta.helm.sh/release-name=librenms --overwrite >/dev/null || return 1
        kubectl annotate namespace "$NAMESPACE" meta.helm.sh/release-namespace="$NAMESPACE" --overwrite >/dev/null || return 1
    }

    merge_acme_dns_credentials() {
        local certs_dir="$LNMS_DIR/certs"
        local merged_file="$certs_dir/acme-dns-account.json"
        local domain_files
        local combined_json="{}"
        local first=1

        if [ ! -d "$certs_dir" ]; then
            return 0
        fi

        # Find all domain-specific acme files
        domain_files=$(find "$certs_dir" -maxdepth 1 -name 'acme-dns-account.*.json' -type f 2>/dev/null | sort)

        if [ -z "$domain_files" ]; then
            return 0
        fi

        # Merge all domain files
        if command -v jq >/dev/null 2>&1; then
            for domain_file in $domain_files; do
                if [ -f "$domain_file" ]; then
                    combined_json=$(jq -s '.[0] * .[1]' <(echo "$combined_json") "$domain_file" 2>/dev/null || echo "$combined_json")
                fi
            done
            echo "$combined_json" > "$merged_file"
            chmod 600 "$merged_file"
            return 0
        fi

        # Fallback for systems without jq: simple text concatenation (less ideal)
        echo "{" > "$merged_file"
        for domain_file in $domain_files; do
            if [ -f "$domain_file" ]; then
                # Extract the inner content between first { and last }
                sed '1d;$d' "$domain_file" | sed '$d' >> "$merged_file"
                echo "," >> "$merged_file"
            fi
        done
        # Remove trailing comma and close
        sed -i '$ s/,$//' "$merged_file"
        echo "}" >> "$merged_file"
        chmod 600 "$merged_file"
        return 0
    }

    import_acme_dns_credentials() {
        local creds_file="$LNMS_DIR/certs/acme-dns-account.json"
        local secret_name="acme-dns-credentials"
        local issuer_kind="ClusterIssuer"
        local cfg="$LNMS_DIR/lnms-config.yaml"

        # Merge domain-specific files into main file
        merge_acme_dns_credentials || true

        ensure_secret_in_namespace() {
            local target_ns="$1"

            if ! kubectl get namespace "$target_ns" >/dev/null 2>&1; then
                return 0
            fi

            if kubectl get secret "$secret_name" -n "$target_ns" >/dev/null 2>&1; then
                return 0
            fi

            if kubectl create secret generic "$secret_name" \
                --from-file="acme-dns-account.json=$creds_file" \
                -n "$target_ns" >/dev/null 2>&1; then
                echo "ACME-DNS credentials imported into namespace $target_ns."
                return 0
            fi

            echo "Warning: failed to import ACME-DNS credentials into namespace $target_ns."
            return 0
        }

        if [ ! -f "$creds_file" ]; then
            return 0
        fi

        if [ -f "$cfg" ]; then
            secret_name=$(awk '
                /^ingress:[[:space:]]*$/ { in_ingress=1; next }
                in_ingress && /^[^[:space:]]/ { in_ingress=0 }
                in_ingress && /^[[:space:]]{2}letsEncrypt:[[:space:]]*$/ { in_le=1; next }
                in_ingress && in_le && /^[[:space:]]{2}[A-Za-z0-9_]+:[[:space:]]*$/ { in_le=0 }
                in_le && /^[[:space:]]{4}acmeDns:[[:space:]]*$/ { in_ad=1; next }
                in_le && in_ad && /^[[:space:]]{4}[A-Za-z0-9_]+:[[:space:]]*$/ { in_ad=0 }
                in_ad && /^[[:space:]]{6}accountSecretName:[[:space:]]*/ {
                    val=substr($0, index($0, ":") + 1)
                    sub(/[[:space:]]+#.*$/, "", val)
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
                    gsub(/^"|"$/, "", val)
                    print val
                    exit
                }
            ' "$cfg" 2>/dev/null)

            issuer_kind=$(awk '
                /^ingress:[[:space:]]*$/ { in_ingress=1; next }
                in_ingress && /^[^[:space:]]/ { in_ingress=0 }
                in_ingress && /^[[:space:]]{2}letsEncrypt:[[:space:]]*$/ { in_le=1; next }
                in_ingress && in_le && /^[[:space:]]{2}[A-Za-z0-9_]+:[[:space:]]*$/ { in_le=0 }
                in_le && /^[[:space:]]{4}issuerKind:[[:space:]]*/ {
                    val=substr($0, index($0, ":") + 1)
                    sub(/[[:space:]]+#.*$/, "", val)
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
                    gsub(/^"|"$/, "", val)
                    print val
                    exit
                }
            ' "$cfg" 2>/dev/null)
        fi

        if [ -z "$secret_name" ]; then
            secret_name="acme-dns-credentials"
        fi

        echo "Importing ACME-DNS credentials from $creds_file..."
        ensure_secret_in_namespace "$NAMESPACE"

        case "${issuer_kind:-ClusterIssuer}" in
            ClusterIssuer|clusterissuer)
                ensure_secret_in_namespace "cert-manager"
                ;;
        esac

        return 0
    }

    case "$action" in
        "start")

            run_preflight || return 1

            local release_namespace
            release_namespace=$(existing_release_namespace || true)
            if [ -n "$release_namespace" ] && [ "$release_namespace" != "$NAMESPACE" ]; then
                echo "Error: Helm release 'librenms' already exists in namespace '$release_namespace'."
                echo "Use NMS_NAMESPACE=$release_namespace for this environment, or uninstall/migrate the existing release first."
                return 1
            fi

            ensure_namespace_exists || return 1
            ensure_namespace_helm_metadata || return 1
            import_acme_dns_credentials

            if kubectl get deployment librenms -n "$NAMESPACE" >/dev/null 2>&1; then
                echo "LibreNMS already installed, skipping." 
                return 
            fi

            echo "Installing LibreNMS..."
            if [ "$NO_EDITOR" -eq 1 ]; then
                echo "Skipping editor (non-interactive mode)."
            else
                vim -f "$LNMS_DIR/lnms-config.yaml" || return 1
            fi
            ensure_cert_manager_from_values "$LNMS_DIR" "$NAMESPACE" || return 1
            import_acme_dns_credentials
            echo "Installing LibreNMS in namespace [$NAMESPACE] using chart:[$LNMS_DIR/vault/LibreNMS-Helm/] and config:[$LNMS_DIR/lnms-config.yaml]"
            helm install librenms "$LNMS_DIR/vault/LibreNMS-Helm/" -n "$NAMESPACE" -f "$LNMS_DIR/lnms-config.yaml" || return 1

            if [ "$AUTO_ADD_HOST" -eq 1 ] && [ "$AUTO_ADD_HOST_READY" -eq 1 ]; then
                wait_for_librenms_ready 240 || true

                local host_ip
                host_ip=$(get_host_ip)

                echo "Adding LibreNMS host to monitoring..."
                if [ -n "$host_ip" ]; then
                    if device_already_added "$host_ip"; then
                        echo "   Host $host_ip already exists in LibreNMS, skipping add."
                    else
                        echo "   Adding $host_ip to SNMP..."
                        lnms report:devices | head -3
                        if lnms device:add -2 -c "$SNMP_COMMUNITY" -r "$SNMP_PORT" -d LibreNMS "$host_ip" || true; then
                            echo "   Device add completed."
                        fi
                    fi
                else
                    echo "No suitable host IPv4 address could be found for SNMP monitoring."
                fi
            elif [ "$AUTO_ADD_HOST" -eq 1 ]; then
                echo "Skipping automatic host add because SNMP precheck failed."
            else
                echo "Skipping automatic host add (--no-auto-add-host)."
            fi
            ;;
        
        "stop")

            echo "Stopping LibreNMS..."
            helm uninstall librenms -n "$NAMESPACE" || return 1
            ;;

        "edit")  

            echo "Editing LibreNMS configuration..."
            if [ "$NO_EDITOR" -eq 1 ]; then
                echo "Skipping editor (non-interactive mode)."
            else
                vim -f "$LNMS_DIR/lnms-config.yaml" || return 1
            fi
            ensure_cert_manager_from_values "$LNMS_DIR" "$NAMESPACE" || return 1
            import_acme_dns_credentials
            helm upgrade librenms "$LNMS_DIR/vault/LibreNMS-Helm/" -n "$NAMESPACE" -f "$LNMS_DIR/lnms-config.yaml" || return 1
            ;;

        "update")

            echo "Upgrading LibreNMS installation..."
            ensure_cert_manager_from_values "$LNMS_DIR" "$NAMESPACE" || return 1
            import_acme_dns_credentials
            helm upgrade librenms "$LNMS_DIR/vault/LibreNMS-Helm/" -n "$NAMESPACE" -f "$LNMS_DIR/lnms-config.yaml" || return 1
            ;;

        "status")

            echo "Checking LibreNMS status..."
            local pod_name
            pod_name=$(get_librenms_pod)

            if [ -n "$pod_name" ]; then
                kubectl describe pod "$pod_name" -n "$NAMESPACE"
            else
                echo "Error: LibreNMS pod not found."
            fi
            ;;


        "monitor")

            echo "Starting k9s dashboard..."
            k9s
            ;;



        "map")

            echo "Generating weather map..."
            local pod_name
            local pod_container
            pod_name=$(get_librenms_pod)
            
            if [ -n "$pod_name" ]; then
                if read -r pod_name pod_container < <(resolve_lnms_exec_target "$NAMESPACE"); then
                    kubectl exec -it "$pod_name" -c "$pod_container" --namespace="$NAMESPACE" -- php /opt/librenms/html/plugins/Weathermap/map-poller.php
                else
                    echo "Error: LibreNMS executable container not found."
                    return 1
                fi
            else
                echo "Error: LibreNMS pod not found."
            fi
            ;;

        "cert")

            if [ "${1:-}" = "check" ]; then
                local register_script
                local register_script_repo

                register_script="$LNMS_DIR/vault/LibreNMS-Installer/bin/acme-dns-register.sh"
                register_script_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)/bin/acme-dns-register.sh"

                if [ ! -f "$register_script" ] && [ -f "$register_script_repo" ]; then
                    register_script="$register_script_repo"
                fi

                if [ ! -f "$register_script" ]; then
                    echo "Error: ACME-DNS register helper not found."
                    echo "Expected at: $LNMS_DIR/vault/LibreNMS-Installer/bin/acme-dns-register.sh"
                    return 1
                fi

                echo "Checking ACME-DNS configuration..."
                bash "$register_script" --check
                return $?
            fi

            if [ "${1:-}" = "register" ]; then
                local register_domain="${2:-}"
                local register_output
                local register_script
                local register_script_repo
                local acmedns_host=""
                local register_log
                local host_ip
                local external_ip
                local acme_fulldomain

                register_script="$LNMS_DIR/vault/LibreNMS-Installer/bin/acme-dns-register.sh"
                register_script_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)/bin/acme-dns-register.sh"

                if [ ! -f "$register_script" ] && [ -f "$register_script_repo" ]; then
                    register_script="$register_script_repo"
                fi

                if [ ! -f "$register_script" ]; then
                    echo "Error: ACME-DNS register helper not found."
                    echo "Expected at: $LNMS_DIR/vault/LibreNMS-Installer/bin/acme-dns-register.sh"
                    return 1
                fi

                if [ -z "$register_domain" ]; then
                    echo "Usage:"
                    echo "    nms cert register <domain> [output_file]"
                    echo ""
                    echo "Example:"
                    echo "    nms cert register nms.example.com"
                    echo "    nms cert register nms.example.com /custom/path/account.json"
                    echo ""
                    echo "Default: saves to $LNMS_DIR/certs/acme-dns-account.<domain>.json"
                    echo "         and merges all domain files into $LNMS_DIR/certs/acme-dns-account.json"
                    return 1
                fi

                # Use domain-specific filename by default
                if [ -z "${3:-}" ]; then
                    register_output="$LNMS_DIR/certs/acme-dns-account.${register_domain}.json"
                else
                    register_output="${3}"
                fi

                mkdir -p "$(dirname "$register_output")" || {
                    echo "Error: could not create output directory for $register_output"
                    return 1
                }

                if [ -z "${ACMEDNS_API:-}" ] && [ -f "$LNMS_DIR/lnms-config.yaml" ]; then
                    acmedns_host=$(awk '
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
                    ' "$LNMS_DIR/lnms-config.yaml" 2>/dev/null)

                    if [ -n "$acmedns_host" ]; then
                        case "$acmedns_host" in
                            http://*|https://*)
                                export ACMEDNS_API="$acmedns_host"
                                ;;
                            *)
                                export ACMEDNS_API="https://$acmedns_host"
                                ;;
                        esac
                    fi
                fi

                echo "Starting ACME-DNS pre-registration..."
                if ! register_log=$(bash "$register_script" "$register_domain" "$register_output" 2>&1); then
                    echo "$register_log"
                    return 1
                fi

                host_ip=$(get_host_ip || true)
                external_ip=$(get_external_ip_hint || true)

                if command -v jq >/dev/null 2>&1; then
                    acme_fulldomain=$(jq -r --arg domain "$register_domain" '.[$domain].fulldomain // empty' "$register_output" 2>/dev/null || true)
                    if [ -z "$acme_fulldomain" ]; then
                        acme_fulldomain=$(jq -r 'to_entries[0].value.fulldomain // empty' "$register_output" 2>/dev/null || true)
                    fi
                fi

                if [ -z "$acme_fulldomain" ]; then
                    acme_fulldomain=$(awk -F '"' '/"fulldomain"[[:space:]]*:/ { print $4; exit }' "$register_output" 2>/dev/null)
                fi

                # Merge all domain files into main acme-dns-account.json
                merge_acme_dns_credentials || true

                echo "ACME-DNS registration completed."
                echo ""
                echo "These settings need to be added to your DNS:"

                if [ -n "$host_ip" ] && [ -n "$external_ip" ]; then
                    echo "DNS: $register_domain $host_ip (or $external_ip if you are exposing the server to the internet)"
                elif [ -n "$host_ip" ]; then
                    echo "DNS: $register_domain $host_ip"
                else
                    echo "DNS: $register_domain <host-ip>"
                fi

                if [ -n "$acme_fulldomain" ]; then
                    echo "CNAME: _acme-challenge.$register_domain $acme_fulldomain"
                else
                    echo "CNAME: _acme-challenge.$register_domain <acme-dns-fulldomain>"
                    echo "Warning: unable to parse fulldomain from $register_output"
                fi

                echo ""
                echo "Domain credentials saved to: $register_output"
                echo "Merged credentials saved to: $LNMS_DIR/certs/acme-dns-account.json"
                return 0
            fi

            if [ "${1:-}" = "static" ]; then
                shift
            elif [ -n "${1:-}" ] && [ -z "${2:-}" ]; then
                echo "Usage:"
                echo "    nms cert static <cert> <key>"
                echo "    nms cert check"
                echo "    nms cert register <domain> [output_file]"
                return 1
            elif [ -n "${1:-}" ] && [ -n "${2:-}" ]; then
                echo "Error: static cert mode now requires the explicit subcommand."
                echo "Use: nms cert static <cert> <key>"
                return 1
            fi

            echo "Inserting TLS secret manually..."
            echo " "
            if [ -z "${1:-}" ] || [ -z "${2:-}" ]; then
                echo "Cert and key files required: "
                echo "    nms cert static /path/to/cert.pem /path/to/cert.key"
                echo ""
                echo "ACME-DNS pre-registration option:"
                echo "    nms cert check"
                echo "    nms cert register <domain> [output_file]"
                echo "    Default output_file: $LNMS_DIR/certs/acme-dns-account.json"
                return 1
            fi

            if kubectl -n "$NAMESPACE" create secret tls https-cert --cert="$1" --key="$2" --dry-run=client -o yaml | kubectl apply -n "$NAMESPACE" -f -; then
                echo "TLS secret https-cert created/updated in namespace $NAMESPACE"
                return 0
            fi

            echo "Warning: apply failed, attempting replace by delete/recreate (useful for immutable secrets)."
            kubectl -n "$NAMESPACE" delete secret https-cert >/dev/null 2>&1 || true
            kubectl -n "$NAMESPACE" create secret tls https-cert --cert="$1" --key="$2" || return 1
            echo "TLS secret https-cert created/updated in namespace $NAMESPACE"
            ;;

        "help")

            echo "Displaying help..."
            cat "$LNMS_DIR/vault/LibreNMS-Installer/doc/nmsinfo.txt" || return 1  
            ;;

        "preflight")

            run_preflight
            ;;

        *)

            echo "Usage: nms {start|stop|edit|update|status|monitor|cert|map|preflight|help} [--non-interactive] [--no-auto-add-host]"
            return 1
            ;;
    esac
}
