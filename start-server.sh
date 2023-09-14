
function LibreClusterInstall() {
    helm install librenms "$LNMS_DIR/chart/LibreNMS-Helm/" -f "$LNMS_DIR/lnms-config.yaml"
}

# Function to add LibreNMS IP to SNMP monitoring
function LibreSNMPadd() {
    ip_eth=$(/sbin/ip -o -4 addr list eth0 | awk '{print $4}' | cut -d/ -f1)
    ip_ens=$(/sbin/ip -o -4 addr list ens160 | awk '{print $4}' | cut -d/ -f1)

    if [ "$ip_ens" ]; then
        echo "Adding $ip_ens to SNMP monitoring..."
        kubectl exec --namespace=librenms --stdin --tty lnms-dispatcher-0 -- /usr/bin/lnms device:add -2 -c locallibremon -r 1161 -d LibreNMS "$ip_ens"
    elif [ "$ip_eth" ]; then
        echo "Adding $ip_eth to SNMP monitoring..."
        kubectl exec --namespace=librenms --stdin --tty lnms-dispatcher-0 -- /usr/bin/lnms device:add -2 -c locallibremon -r 1161 -d LibreNMS "$ip_eth"
    else
        echo "No IP address could be found for SNMP monitoring."
    fi
}

nano -f "$LNMS_DIR/lnms-config.yaml"

echo "################## Starting LibreNMS Cluster Installation ##################"
echo "To monitor the process you can run 'sudo k9s' in another terminal."
echo ""
LibreClusterInstall
LibreSNMPadd


echo "################## Cluster Starup Complete ##################"
