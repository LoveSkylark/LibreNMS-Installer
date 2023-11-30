#!/bin/bash

# extending lnms into pod
alias lnms="kubectl exec --namespace=librenms --stdin --tty lnms-dispatcher-0 -- /usr/bin/lnms"

nms() {
    local action="$1"
    local LNMS_DIR="${LNMS_DIR:-/data}"
    local KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    case "$action" in
        "start")

            if kubectl get deployment librenms 2>/dev/null; then
                echo "LibreNMS already installed, skipping." 
                return 
            fi

            echo "Installing LibreNMS..."
            if [ "$?" -eq 0 ]; then
                vim -f "$LNMS_DIR/lnms-config.yaml" || return 1
                echo "Installing LibreNMS  in namespace [librenms] using chart:[$LNMS_DIR/vault/LibreNMS-Helm/] and config:[$LNMS_DIR/lnms-config.yaml]"
                helm install librenms "$LNMS_DIR/vault/LibreNMS-Helm/" -f "$LNMS_DIR/lnms-config.yaml" || return 1
                
                local ip_eth=$(/sbin/ip -o -4 addr list eth0 | awk '{print $4}' | cut -d/ -f1)
                local ip_ens=$(/sbin/ip -o -4 addr list ens160 | awk '{print $4}' | cut -d/ -f1)

                echo "Adding LibreNMS to monitoring..."
                if [ "$ip_ens" ]; then
                    echo "   Adding $ip_ens to SNMP..."
                    kubectl exec --namespace=librenms --stdin --tty lnms-dispatcher-0 -- /usr/bin/lnms device:add -2 -c locallibremon -r 1161 -d LibreNMS "$ip_ens" || return 1
                elif [ "$ip_eth" ]; then
                    echo "   Adding $ip_eth to SNMP..."
                    kubectl exec --namespace=librenms --stdin --tty lnms-dispatcher-0 -- /usr/bin/lnms device:add -2 -c locallibremon -r 1161 -d LibreNMS "$ip_eth" || return 1
                else
                    echo "No IP address could be found for SNMP monitoring."
                fi
            else
                echo "Installation failed, check configuration."
            fi
            ;;
        
        "stop")

            echo "Stopping LibreNMS..."
            helm uninstall librenms || return 1
            ;;

        "edit")  

            echo "Editing LibreNMS configuration..."
            if [ "$?" -eq 0 ]; then
                vim -f "$LNMS_DIR/lnms-config.yaml" || return 1
                helm upgrade librenms "$LNMS_DIR/vault/LibreNMS-Helm/" -f "$LNMS_DIR/lnms-config.yaml" || return 1
            else
                echo "Edit failed. Check permissions."
            fi
            ;;

        "update")

            echo "Upgrading LibreNMS installation..."  
            helm upgrade librenms "$LNMS_DIR/vault/LibreNMS-Helm/" -f "$LNMS_DIR/lnms-config.yaml" || return 1
            ;;

        "status")

            echo "Checking LibreNMS status..."
            local pod_name=$(kubectl get pods -n librenms | grep lnms-app | awk '{print $1}')

            if [ -n "$pod_name" ]; then
                kubectl describe pod "$pod_name" -n librenms
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
            local pod_name=$(kubectl get pods -n librenms | grep lnms-app | awk '{print $1}')
            
            if [ -n "$pod_name" ]; then
                kubectl exec -it "$pod_name" --namespace=librenms -- php /opt/librenms/html/plugins/Weathermap/map-poller.php
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

            kubectl apply --force -f <(kubectl create secret tls https --cert="$2" --key="$3" --namespace librenms -o yaml)
            ;;

        "help")

            echo "Displaying help..."
            cat "$LNMS_DIR/installer/doc/nmsinfo.txt" || return 1  
            ;;

        *)

            echo "Usage: $0 {start|stop|edit|update|status|monitor|map|help}"
            return 1
            ;;
    esac
}
