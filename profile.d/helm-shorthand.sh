#!/bin/bash
alias h="helm"
alias hl="helm list"
alias hall="helm list --all-namespaces"

hin() {
    local ns="${NMS_NAMESPACE:-librenms}"

    if [ -z "$2" ]; then
            echo -e "Error, please provide a release name, chart and value file"
    elif [ -z "$3" ]; then
            helm install "$1" "$2" -n "$ns" --create-namespace
    else 
            helm install "$1" "$2" -n "$ns" --create-namespace -f "$3"
    fi
}

hup()  {
    local ns="${NMS_NAMESPACE:-librenms}"

    if [ -z "$2" ]; then
            echo -e "Error, please provide a release name, chart and value file"
    elif [ -z "$3" ]; then
            helm upgrade "$1" "$2" -n "$ns"
    else 
            helm upgrade "$1" "$2" -n "$ns" -f "$3"
    fi
}

hun() {
    local ns="${NMS_NAMESPACE:-librenms}"

    if [ -n "$1" ]; then
            helm uninstall "$1" -n "$ns"
    else
            echo -e "Error, please provide a release name"
    fi
}