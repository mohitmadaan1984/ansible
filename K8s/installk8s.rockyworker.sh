#!/bin/bash

# ============================================================
# Kubernetes Worker Node Setup Script for Rocky Linux 9
# Author: Shaj
# Version: 1.0
# ============================================================

set -e # Exit immediately if a command exits with a non-zero status

KUBERNETES_VERSION="1.32"
MASTER_NODE_IP="192.168.1.100"  # Change this to your master node IP
JOIN_COMMAND=""  # Will be set automatically or manually

echo "=============================================="
echo " Starting Kubernetes Worker Node Setup"
echo "=============================================="

# ============================================================
# Step 1: Disable Firewall and Swap
# ============================================================
echo "[1/9] Disabling firewalld and swap..."
systemctl disable --now firewalld || true
swapoff -a
sed -i '/swap/s/^/#/' /etc/fstab
echo "✅ Firewall disabled and swap turned off"

# ============================================================
# Step 2: Enable required kernel modules and sysctl parameters
# ============================================================
echo "[2/9] Enabling kernel modules and sysctl parameters for networking..."

# Load kernel modules
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

# Configure sysctl parameters
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF

sysctl --system
echo "✅ Kernel modules and sysctl parameters configured successfully"

# ============================================================
# Step 3: Install required dependencies
# ============================================================
echo "[3/9] Installing dependencies..."
dnf install -y dnf-plugins-core container-selinux curl
echo "✅ Dependencies installed successfully"

# ============================================================
# Step 4: Configure Kubernetes repository
# ============================================================
echo "[4/9] Configuring Kubernetes repo for $KUBERNETES_VERSION..."
cat <<EOF | tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v$KUBERNETES_VERSION/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v$KUBERNETES_VERSION/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF
echo "✅ Kubernetes repo configured successfully"

# ============================================================
# Step 5: Install and configure Containerd from Docker repo
# ============================================================
echo "[5/9] Installing and configuring Containerd..."

# Add Docker repository
dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo

# Install containerd
dnf install -y containerd.io

# Generate default containerd config and enable systemd cgroups
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# Start and enable containerd
systemctl daemon-reload
systemctl enable containerd --now

# Verify containerd is working
if systemctl is-active --quiet containerd; then
    echo "✅ Containerd installed and running successfully"
else
    echo "❌ Containerd failed to start"
    systemctl status containerd
    exit 1
fi

# ============================================================
# Step 6: Install Kubernetes components
# ============================================================
echo "[6/9] Installing kubelet, kubeadm, and kubectl..."
dnf install -y kubelet kubeadm kubectl --disableexcludes=kubernetes
echo "✅ Kubernetes components installed successfully"

# ============================================================
# Step 7: Enable kubelet service
# ============================================================
echo "[7/9] Enabling kubelet service..."
systemctl enable kubelet.service
echo "✅ kubelet service enabled"

# ============================================================
# Step 8: Configure hostname and hosts file
# ============================================================
echo "[8/9] Configuring hostname..."

# Get current hostname
CURRENT_HOSTNAME=$(hostname -s)

# Prompt for new hostname if not already set
if [[ $CURRENT_HOSTNAME == "localhost" ]] || [[ $CURRENT_HOSTNAME == "rocky"* ]]; then
    echo "Current hostname: $CURRENT_HOSTNAME"
    read -p "Enter new hostname for this worker node: " NEW_HOSTNAME
    if [[ -n "$NEW_HOSTNAME" ]]; then
        hostnamectl set-hostname "$NEW_HOSTNAME"
        echo "✅ Hostname set to: $NEW_HOSTNAME"
    fi
fi

# Update /etc/hosts with master node IP (optional)
if [[ -n "$MASTER_NODE_IP" ]]; then
    echo "Updating /etc/hosts with master node..."
    if ! grep -q "master-node" /etc/hosts; then
        echo "$MASTER_NODE_IP master-node" >> /etc/hosts
    fi
fi

# ============================================================
# Step 9: Join the Kubernetes cluster
# ============================================================
echo "[9/9] Joining Kubernetes cluster..."

# Method 1: Auto-retrieve join command from master (if SSH access available)
if [[ -n "$MASTER_NODE_IP" ]]; then
    echo "Attempting to retrieve join command from master node..."
    
    # Check if we can SSH to master (you'll need to set up SSH keys first)
    if command -v ssh &> /dev/null; then
        JOIN_COMMAND=$(ssh -o StrictHostKeyChecking=no root@$MASTER_NODE_IP "kubeadm token create --print-join-command 2>/dev/null" || true)
    fi
fi

# Method 2: Prompt for join command if auto-retrieve failed
if [[ -z "$JOIN_COMMAND" ]]; then
    echo ""
    echo "=============================================="
    echo " Manual Join Command Required"
    echo "=============================================="
    echo "To get the join command, run on the MASTER node:"
    echo "  kubeadm token create --print-join-command"
    echo ""
    echo "Then paste the join command below:"
    read -p "Join command: " JOIN_COMMAND
fi

# Validate join command
if [[ -z "$JOIN_COMMAND" ]]; then
    echo "❌ No join command provided. Exiting."
    exit 1
fi

# Execute join command
echo "Joining cluster with command: $JOIN_COMMAND"
eval $JOIN_COMMAND

# Check if join was successful
if [ $? -eq 0 ]; then
    echo "✅ Successfully joined Kubernetes cluster!"
    
    # Wait a moment for node registration
    sleep 10
    
    # Instructions for verification
    echo ""
    echo "=============================================="
    echo " Worker Node Setup Complete!"
    echo "=============================================="
    echo "To verify this worker node, run on the MASTER:"
    echo "  kubectl get nodes"
    echo ""
    echo "Current node hostname: $(hostname)"
else
    echo "❌ Failed to join Kubernetes cluster"
    exit 1
fi