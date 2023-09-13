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

    # Store the current directory
    case "$1" in
        "edit")
            if [ $? -eq 0 ]; then
                vim -f "$LNMS_DIR/lnms-config.yaml" || return 1
                helm upgrade librenms "$LNMS_DIR/chartLibreNMS-Helm/" -f "$LNMS_DIR/lnms-config.yaml" || return 1
            else
                echo "Editing configuration failed. SUDO may be needed"
            fi
            ;;
        "help")
            cat "$LNMS_DIR/installer/doc/ailiases.txt" || return 1
            ;;
        "update")
            helm upgrade librenms "$LNMS_DIR/chartLibreNMS-Helm/" -f "$LNMS_DIR/lnms-config.yaml" || return 1
            ;;
        "map")
            local pod_name=$(kubectl get pods -n librenms | grep lnms-app | awk '{print $1}')
            if [ -n "$pod_name" ]; then
                kubectl exec -it "$pod_name" --namespace=librenms -- php /opt/librenms/html/plugins/Weathermap/map-poller.php
            else
                echo "Error: LibreNMS pod not found."
            fi
            ;;
        *)
            echo "Usage: $0 {edit|update|map|help}"
            return 1
            ;;
    esac
}
