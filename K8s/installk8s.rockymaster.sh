#!/bin/bash

# ============================================================
# Kubernetes + Containerd Installation Script for Rocky Linux 9
# Author: Shaj
# Version: 2.1
# ============================================================

set -e # Exit immediately if a command exits with a non-zero status

KUBERNETES_VERSION="1.32"

echo "=============================================="
echo " Starting Kubernetes $KUBERNETES_VERSION with Containerd setup"
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
# Step 8: Initialize Kubernetes control plane
# ============================================================
echo "[8/9] Initializing Kubernetes cluster..."

# Configure kubeadm to use containerd
cat <<EOF | tee /tmp/kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
nodeRegistration:
  criSocket: "unix:///var/run/containerd/containerd.sock"
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
networking:
  podSubnet: "192.168.0.0/16"
EOF

kubeadm init --config=/tmp/kubeadm-config.yaml | tee /root/bootstrap.txt

# Check if initialization was successful
if [ $? -eq 0 ]; then
    echo "✅ Kubernetes cluster initialized successfully"
else
    echo "❌ Kubernetes cluster initialization failed"
    exit 1
fi

# ============================================================
# Configure kubectl for both root and student user
# ============================================================

echo "Configuring kubectl for root user..."
mkdir -p /root/.kube
cp -i /etc/kubernetes/admin.conf /root/.kube/config
chown root:root /root/.kube/config

echo "Configuring kubectl for student user..."
mkdir -p /home/student/.kube
cp -i /etc/kubernetes/admin.conf /home/student/.kube/config
chown student:student /home/student/.kube/config
chmod 600 /home/student/.kube/config

# Add KUBECONFIG to student's bashrc
echo "export KUBECONFIG=/home/student/.kube/config" >> /home/student/.bashrc

# ============================================================
# Step 9: Configure kubectl and networking
# ============================================================
echo "[9/9] Configuring kubectl and networking..."

# Configure kubectl for root user
mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

# Install Calico CNI
echo "Installing Calico CNI..."
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.30.3/manifests/calico.yaml

echo "✅ Calico network plugin installed"

# Wait for pods to be ready
echo "Waiting for system pods to be ready..."
sleep 60

echo "✅ Kubernetes Pod Status:"
kubectl get pods -A

echo "✅ Kubernetes Node Status:"
kubectl get nodes

echo "=============================================="
echo " Kubernetes $KUBERNETES_VERSION + Containerd setup complete!"
echo "=============================================="
echo ""
echo "To start using your cluster:"
echo "1. Run: kubectl get pods -A"
echo "2. To join worker nodes, use the command from: /root/bootstrap.txt"
echo "3. Remove taint for single-node cluster: kubectl taint nodes --all node-role.kubernetes.io/control-plane-"
echo "=============================================="