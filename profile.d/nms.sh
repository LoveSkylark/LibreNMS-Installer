#!/bin/bash

lnms() {
    local namespace="librenms"
    local dispatcher_pod

    dispatcher_pod=$(kubectl get pod -n "$namespace" -l app.kubernetes.io/component=dispatcher -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -z "$dispatcher_pod" ]; then
        dispatcher_pod=$(kubectl get pods -n "$namespace" --no-headers 2>/dev/null | awk '/lnms-dispatcher/ {print $1; exit}')
    fi

    if [ -z "$dispatcher_pod" ]; then
        echo "Error: dispatcher pod not found in namespace $namespace."
        return 1
    fi

    kubectl exec --namespace="$namespace" --stdin --tty "$dispatcher_pod" -- /usr/bin/lnms "$@"
}

nms() {
    local action="$1"
    shift || true
    local LNMS_DIR="${LNMS_DIR:-/data}"
    local KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    local NAMESPACE="librenms"
    local NO_EDITOR="${NMS_NO_EDITOR:-0}"
    local AUTO_ADD_HOST="${NMS_AUTO_ADD_HOST:-1}"

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
            *)
                echo "Warning: unknown option '$1' ignored."
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

    run_preflight() {
        local ok=1
        local fqdn

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

        if [ "$ok" -eq 1 ]; then
            echo "Preflight passed."
            return 0
        fi

        echo "Preflight failed. Fix the failing checks and rerun: nms preflight"
        return 1
    }

    get_librenms_pod() {
        local pod_name
        pod_name=$(kubectl get pod -n "$NAMESPACE" -l app.kubernetes.io/name=librenms,app.kubernetes.io/component=app -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
        if [ -n "$pod_name" ]; then
            echo "$pod_name"
            return 0
        fi

        kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | awk '/lnms-app/ {print $1; exit}'
    }

    case "$action" in
        "start")

            run_preflight || return 1

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
            echo "Installing LibreNMS in namespace [$NAMESPACE] using chart:[$LNMS_DIR/vault/LibreNMS-Helm/] and config:[$LNMS_DIR/lnms-config.yaml]"
            helm install librenms "$LNMS_DIR/vault/LibreNMS-Helm/" -n "$NAMESPACE" --create-namespace -f "$LNMS_DIR/lnms-config.yaml" || return 1

            if [ "$AUTO_ADD_HOST" -eq 1 ]; then
                kubectl wait -n "$NAMESPACE" --for=condition=Ready pod -l app.kubernetes.io/component=dispatcher --timeout=240s >/dev/null 2>&1 || true

                local host_ip
                host_ip=$(get_host_ip)

                echo "Adding LibreNMS host to monitoring..."
                if [ -n "$host_ip" ]; then
                    echo "   Adding $host_ip to SNMP..."
                    lnms device:add -2 -c locallibremon -r 1161 -d LibreNMS "$host_ip" || return 1
                else
                    echo "No suitable host IPv4 address could be found for SNMP monitoring."
                fi
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
            helm upgrade librenms "$LNMS_DIR/vault/LibreNMS-Helm/" -n "$NAMESPACE" -f "$LNMS_DIR/lnms-config.yaml" || return 1
            ;;

        "update")

            echo "Upgrading LibreNMS installation..."  
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
            pod_name=$(get_librenms_pod)
            
            if [ -n "$pod_name" ]; then
                kubectl exec -it "$pod_name" --namespace="$NAMESPACE" -- php /opt/librenms/html/plugins/Weathermap/map-poller.php
            else
                echo "Error: LibreNMS pod not found."
            fi
            ;;

        "cert")

            echo "Inserting TLS secret manually..."
            echo " "
            if [ -z "$2" ] || [ -z "$3" ]; then
                echo "Cert and key files required: "
                echo "    nms cert /path/to/cert.pem /path/to/cert.key"  
                return 1  
            fi

            kubectl -n "$NAMESPACE" create secret tls https-cert --cert="$2" --key="$3" --dry-run=client -o yaml | kubectl apply -n "$NAMESPACE" -f -
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
