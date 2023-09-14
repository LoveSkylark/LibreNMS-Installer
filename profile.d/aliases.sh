# Kubectl commands

alias k="kubectl"

kn() {
    if [ "$1" != "" ]; then
            kubectl config set-context --current --namespace=$1
    else
            echo -e "Error, please provide a valid Namespace"
    fi
}

knd() {
    kubectl config set-context --current --namespace=default
}

ku() {
    kubectl config unset current-context
}

kall() {
    kubectl get all --all-namespaces
}

kbash() {
    if [ "$1" != "" ]; then
            kubectl exec --stdin --tty $1 -- /bin/bash
    else
            echo -e "Error, please provide a pod name"
    fi
}

# Helm commands
alias h="helm"
alias hl="helm list"
alias hall="helm list --all-namespaces"

hin() {
    if [ "$2" = "" ]; then
            echo -e "Error, please provide a release name, chart and value file"
    elif [ "$3" = "" ]; then
            helm install $1 $2 
    else 
            helm install $1 $2 -f $3 
    fi
}

hup()  {
    if [ "$2" = "" ]; then
            echo -e "Error, please provide a release name, chart and value file"
    elif [ "$3" = "" ]; then
            helm upgrade $1 $2 
    else 
            helm upgrade $1 $2 -f $3 
    fi
}

hun() {
    if [ "$1" != "" ]; then
            helm uninstall $1
    else
            echo -e "Error, please provide a release name"
    fi
}

# LibreNMS commands

alias lnms="kubectl exec --namespace=librenms --stdin --tty lnms-dispatcher-0 -- /usr/bin/lnms"

nms() {
    local LNMS_DIR="${LNMS_DIR:-/data}"
    local action="$1"

    case "$action" in
        "edit")  

            echo "Editing LibreNMS configuration..."
            if [ "$?" -eq 0 ]; then
                vim -f "$LNMS_DIR/lnms-config.yaml" || return 1
                helm upgrade librenms "$LNMS_DIR/chart/LibreNMS-Helm/" -f "$LNMS_DIR/lnms-config.yaml" || return 1
            else
                echo "Edit failed. Check permissions."
            fi
            ;;

        "start")

            LibreClusterInstall() {
                helm install librenms "$LNMS_DIR/chart/LibreNMS-Helm/" -f "$LNMS_DIR/lnms-config.yaml"
            }

            if kubectl get deployment librenms 2>/dev/null; then
                echo "LibreNMS already installed, skipping." 
                return 
            fi

            echo "Installing LibreNMS..."
            if [ "$?" -eq 0 ]; then
                vim -f "$LNMS_DIR/lnms-config.yaml" || return 1
                echo "Installing LibreNMS  in namespace [librenms] using chart:[$LNMS_DIR/chart/LibreNMS-Helm/] and config:[$LNMS_DIR/lnms-config.yaml]"
                LibreClusterInstall || return 1
                
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

        "update")

            echo "Upgrading LibreNMS installation..."  
            helm upgrade librenms "$LNMS_DIR/chart/LibreNMS-Helm/" -f "$LNMS_DIR/lnms-config.yaml" || return 1
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

        "help")

            echo "Displaying help..."
            cat "$LNMS_DIR/installer/doc/ailiases.txt" || return 1  
            ;;

        *)

            echo "Usage: $0 {edit|update|start|map|help}"
            return 1
            ;;
    esac
}
