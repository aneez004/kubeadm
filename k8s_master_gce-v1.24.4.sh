echo "\$nrconf{restart} = 'a';" | sudo tee -a /etc/needrestart/needrestart.conf
sudo apt-get update
sudo apt-get install apt-transport-https ca-certificates curl gnupg-agent software-properties-common -y      
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update -y
sudo apt-get install -y containerd.io docker-ce-cli


#Configure iptables

cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
sudo sysctl --system

#Add the Kubernetes apt repository and public signing key
sudo curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg

echo 'deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main' | sudo tee /etc/apt/sources.list.d/kubernetes.list

# Install kubelet kubectl and kubeadm


sudo apt-get update
sudo apt-get install -y kubelet=1.24.4-00 kubeadm=1.24.4-00 kubectl=1.24.4-00
sudo apt-mark hold kubelet kubeadm kubectl

# Disable swap memory

swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

#Enable and restart the services containerd and kubelet

sudo systemctl enable kubelet
sudo systemctl restart kubelet
#rm /etc/containerd/config.toml
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null 2>&1
sed -i 's/SystemdCgroup \= false/SystemdCgroup \= true/g' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd
sudo systemctl daemon-reload

# Set hostname as private ipv4 dnsname from the instance metadata

sudo hostnamectl set-hostname $(curl http://169.254.169.254/latest/meta-data/local-hostname)

#cluster_name = $1

# Create a kubeadm configuration file which will be used during init
cat <<EOF> /tmp/kubeconfigold.yaml
apiVersion: kubeadm.k8s.io/v1beta2
kind: ClusterConfiguration
apiServer:
  extraArgs:
    cloud-provider: gce
clusterName: kubernetes
controlPlaneEndpoint: $(curl "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip" -H "Metadata-Flavor: Google"):6443
controllerManager:
  extraArgs:
    cloud-provider: gce
    configure-cloud-routes: 'false'
kubernetesVersion: v1.24.4
networking:
  dnsDomain: cluster.local
  podSubnet: 192.168.0.0/16
  serviceSubnet: 10.96.0.0/12
scheduler:
---
apiVersion: kubeadm.k8s.io/v1beta2
kind: InitConfiguration
nodeRegistration:
  name: '$(curl  "http://metadata.google.internal/computeMetadata/v1/instance/hostname" -H "Metadata-Flavor: Google")'
  kubeletExtraArgs:
    cloud-provider: gce
EOF

# controlplane endpoint and node registration name will come from the instance metadata. 


# Migrate kubeconfig to a version compatible with the current kubeadm version
 kubeadm config migrate --old-config /tmp/kubeconfigold.yaml --new-config /tmp/kubeconfig.yaml
export HOME=/root
# Creates the kubernetes cluster using the config file
kubeadm init --config /tmp/kubeconfig.yaml

# Copy config file to .kube directory under the user's home directory 
mkdir -p ~/.kube
mkdir -p /home/ubuntu/.kube
cp /etc/kubernetes/admin.conf ~/.kube/config
cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
chown -R ubuntu:ubuntu /home/ubuntu/.kube

#Install calico CNI
wget -O /tmp/calico.yaml https://docs.projectcalico.org/manifests/calico.yaml
kubectl apply -f /tmp/calico.yaml


echo "######### Kubernetes Cluster Creation is Complete   #########"

echo "####### Verify using kubectl commands #########"
