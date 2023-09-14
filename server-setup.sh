# Define variables
K3S_INSTALL_SCRIPT="https://get.k3s.io"
K9S_INSTALL_SCRIPT="https://webi.sh/k9s"
BIN_DIR="${BIN_DIR:-/usr/local/bin}"
LNMS_DIR="${LNMS_DIR:-/data}"

# Function to install LibreNMS cluster
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

# Start of the script
echo "################## Updating Linux ##################"
sudo apt update && sudo apt upgrade -y


echo ""
echo "################## Installing essential tools ##################"
sudo apt install -y curl git vim


echo ""
echo "################## Downloading and installing K3S ##################"
echo "This step installs K3s, a lightweight Kubernetes distribution."
echo ""
# Set KUBECONFIG for all users by creating a script in /etc/profile.d/
grep -qxF 'KUBECONFIG="/etc/rancher/k3s/k3s.yaml"' /etc/environment || echo 'KUBECONFIG="/etc/rancher/k3s/k3s.yaml"' >> /etc/environment
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export INSTALL_K3S_BIN_DIR="$BIN_DIR"
curl -fsSL "$K3S_INSTALL_SCRIPT" | sudo sh -
echo ""


echo "################## Downloading and installing K9S ##################"
echo "This step installs K9s, a terminal-based Kubernetes dashboard."
echo ""
curl -fsSL "$K9S_INSTALL_SCRIPT" | sudo sh -

# Move k9s binary to the BIN_DIR if it exists
if [ -f "/root/.local/bin/k9s" ]; then
    sudo mv "/root/.local/bin/k9s" "$BIN_DIR/"
fi
if [ -f "/home/$USER/.local/bin/k9s" ]; then
    sudo mv "/home/$USER/.local/bin/k9s" "$BIN_DIR/"
fi
echo ""


echo "################## Downloading and installing Helm ##################"
echo "This step installs Helm, the Kubernetes package manager."
echo ""
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | sudo bash
echo ""

echo "################## Fetching LibreNMS Helm Repo ##################"
echo "This step fetches the LibreNMS Helm chart from the repository."
echo ""
sudo mkdir -p "$LNMS_DIR/chart"
sudo git clone https://github.com/LoveSkylark/LibreNMS-Helm.git "$LNMS_DIR/chart/LibreNMS-Helm"
sudo git clone https://github.com/LoveSkylark/LibreNMS-Installer.git "$LNMS_DIR/installer"
if [ ! -f "$LNMS_DIR/lnms-config.yaml" ]; then
    sudo cp "$LNMS_DIR/installer/config/lnms-config.yaml" "$LNMS_DIR/lnms-config.yaml"
fi
echo ""


echo "################## Adding aliases for KUBE & HELM ##################"
echo "This step sets up convenient aliases for managing Kubernetes and Helm."
echo ""
sudo cp "$LNMS_DIR/installer/profile.d/" /etc/profile.d/
echo ""


echo "################## Setting up SNMP for LibreNMS ##################"
echo "This step configures SNMP for LibreNMS monitoring."
echo ""
sudo cp "$LNMS_DIR/installer/snmpd.conf.d" /etc/snmp/snmpd.conf.d
sudo systemctl restart snmpd
echo ""

echo "################## Configuring"LibreNMS Cluster  ##################"
echo "Please configure your LibreNMS cluster by editing the config.yaml file."
echo "The config.yaml file is located at: $LNMS_DIR/lnms-config.yaml"
nano -f "$LNMS_DIR/lnms-config.yaml"
echo ""


echo "################## Starting LibreNMS Cluster Installation ##################"
echo "This step starts the installation of the LibreNMS cluster."
echo ""
LibreClusterInstall
echo ""


echo "################## Adding Host IP to SNMP Monitoring ##################"
echo "This step adds the host IP to SNMP monitoring."
echo ""
LibreSNMPadd
echo ""


echo "################## Installation Complete ##################"
echo "LibreNMS cluster is installed and configured successfully."
echo ""
echo "To manage the Kubernetes cluster, use the 'kubectl' command."
echo "To manage Helm, use the 'helm' command."
echo "To access the LibreNMS web interface, go to http://<your_ip>"
echo "To access the K9s dashboard, run 'sudo k9s' in the terminal."
echo "To edit the LibreNMS cluster configuration, run 'nms edit'"
echo "To add additional devices to LibreNMS, use the 'lnms device:add' command."
echo ""