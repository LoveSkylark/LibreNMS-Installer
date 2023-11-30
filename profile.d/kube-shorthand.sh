#!/bin/bash
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