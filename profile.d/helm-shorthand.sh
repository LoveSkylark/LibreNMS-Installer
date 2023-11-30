#!/bin/bash
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