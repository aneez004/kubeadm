#!/bin/bash
echo "\$nrconf{restart} = 'a';" | sudo tee -a /etc/needrestart/needrestart.conf
apt update -y
apt-get install apt-transport-https ca-certificates curl gnupg-agent software-properties-common -y      
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update -y
apt-get install -y containerd.io docker-ce-cli


#Configure iptables

cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
sysctl --system

#Add the Kubernetes apt repository and public signing key
curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg

echo 'deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main' | tee /etc/apt/sources.list.d/kubernetes.list

# Install kubelet kubectl and kubeadm


apt-get update
apt-get install -y kubelet=1.24.4-00 kubeadm=1.24.4-00 kubectl=1.24.4-00
apt-mark hold kubelet kubeadm kubectl

# Disable swap memory

swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

#Enable and restart the services containerd and kubelet

systemctl enable kubelet
systemctl restart kubelet
#rm /etc/containerd/config.toml
containerd config default | tee /etc/containerd/config.toml >/dev/null 2>&1
sed -i 's/SystemdCgroup \= false/SystemdCgroup \= true/g' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd
systemctl daemon-reload

# Set hostname as private ipv4 dnsname from the instance metadata

hostnamectl set-hostname $(curl  "http://metadata.google.internal/computeMetadata/v1/instance/hostname" -H "Metadata-Flavor: Google")

apiserver=$1
token=$2
cacerthash=$3
# Create a kubeadm configuration file which will be used during join
cat <<EOF> /tmp/kubeconfigold.yaml
apiVersion: kubeadm.k8s.io/v1beta2
kind: JoinConfiguration
nodeRegistration:
  name: '$(curl  "http://metadata.google.internal/computeMetadata/v1/instance/hostname" -H "Metadata-Flavor: Google")'
  kubeletExtraArgs:
    cloud-provider: gce
discovery:
  bootstrapToken:
    apiServerEndpoint: $apiserver
    token: $token
    caCertHashes:
    - $cacerthash    
EOF

#node registration name will come from the instance metadata. 


# Migrate kubeconfig to a version compatible with the current kubeadm version

kubeadm config migrate --old-config /tmp/kubeconfigold.yaml --new-config /tmp/kubeconfig.yaml
# Creates the kubernetes cluster using the config file
kubeadm join --config /tmp/kubeconfig.yaml

# Verify that the node is added to the cluster , from the master node

echo "Use kubectl commands on master node to verify that the worker node is added to the cluster and is in ready state"
