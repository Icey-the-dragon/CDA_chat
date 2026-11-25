#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

MASTER=cda-master
W1=cda-worker-1
W2=cda-worker-2
NET=cda-k8s
SUBNET=172.28.0.0/16

echo "==> VM prerequisites"
swapoff -a 2>/dev/null || true
sed -i '/\bswap\b/s/^/#/' /etc/fstab 2>/dev/null || true
printf 'overlay\nbr_netfilter\n' > /etc/modules-load.d/k8s.conf
modprobe overlay
modprobe br_netfilter
cat > /etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
sysctl --system >/dev/null

# The OVA is imported with a fresh MAC. Make networking independent of the
# original Vagrant MAC so the guest does not hang in networkd-wait-online.
echo "==> Network"
cat > /etc/netplan/01-cda.yaml <<'EOF'
network:
  version: 2
  ethernets:
    enp0s3:
      dhcp4: true
      optional: true
EOF
chmod 600 /etc/netplan/01-cda.yaml
rm -f /etc/netplan/50-cloud-init.yaml
printf 'network: {config: disabled}\n' > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
systemctl mask systemd-networkd-wait-online.service >/dev/null 2>&1 || true
# Do not apply here: that would drop the Vagrant SSH session. The config is
# generated now and takes effect on the next boot (after the OVA is imported).
netplan generate || true

echo "==> Docker"
apt-get update -qq
apt-get install -y -qq docker.io >/dev/null
systemctl enable --now docker

echo "==> Loading images"
docker load -i /home/vagrant/kubeadm-node.tar >/dev/null
docker load -i /home/vagrant/cda-demo.tar >/dev/null

echo "==> Creating node network"
docker network inspect "$NET" >/dev/null 2>&1 || docker network create --subnet "$SUBNET" "$NET" >/dev/null

start_node() {
  local name="$1" ip="$2" extra="${3:-}"
  docker rm -f "$name" >/dev/null 2>&1 || true
  # shellcheck disable=SC2086
  docker run -d --name "$name" --hostname "$name" --restart unless-stopped \
    --privileged --cgroupns=host \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw -v /lib/modules:/lib/modules:ro \
    --tmpfs /run:exec,mode=755 --tmpfs /run/lock:exec,mode=1777 \
    --network "$NET" --ip "$ip" $extra \
    cda-kubeadm-node:latest >/dev/null
}

echo "==> Starting 3 kubeadm nodes"
start_node "$MASTER" 172.28.0.10
start_node "$W1" 172.28.0.11 '-p 30080:30080'
start_node "$W2" 172.28.0.12

for node in "$MASTER" "$W1" "$W2"; do
  for _ in $(seq 1 60); do
    if docker exec "$node" systemctl is-active containerd >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
done

echo "==> kubeadm init"
docker exec "$MASTER" kubeadm init \
  --apiserver-advertise-address=172.28.0.10 \
  --pod-network-cidr=10.244.0.0/16 \
  --ignore-preflight-errors=Swap,SystemVerification >/dev/null
docker exec "$MASTER" mkdir -p /root/.kube
docker exec "$MASTER" cp /etc/kubernetes/admin.conf /root/.kube/config

# Nested containerd cannot write host sysctls; kube-proxy would CrashLoop.
echo "==> Patching kube-proxy and CoreDNS for nested containers"
docker exec "$MASTER" bash -lc '
  kubectl -n kube-system get cm kube-proxy -o go-template="{{index .data \"config.conf\"}}" > /tmp/kube-proxy.conf
  perl -0pi -e "s/maxPerCore: null/maxPerCore: 0/; s/min: null/min: 0/; s/tcpCloseWaitTimeout: null/tcpCloseWaitTimeout: 0s/; s/tcpEstablishedTimeout: null/tcpEstablishedTimeout: 0s/" /tmp/kube-proxy.conf
  kubectl -n kube-system create cm kube-proxy --from-file=config.conf=/tmp/kube-proxy.conf --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n kube-system get cm coredns -o go-template="{{index .data \"Corefile\"}}" > /tmp/Corefile
  sed -i "/^[[:space:]]*loop$/d" /tmp/Corefile
  kubectl -n kube-system create cm coredns --from-file=Corefile=/tmp/Corefile --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n kube-system delete pod -l k8s-app=kube-proxy --wait=false
  kubectl -n kube-system delete pod -l k8s-app=kube-dns --wait=false
' >/dev/null 2>&1 || true

echo "==> Installing Flannel CNI"
docker cp /home/vagrant/manifests/kube-flannel.yml "$MASTER":/tmp/kube-flannel.yml
docker exec "$MASTER" kubectl apply -f /tmp/kube-flannel.yml >/dev/null

echo "==> Joining workers"
JOIN="$(docker exec "$MASTER" kubeadm token create --print-join-command)"
for node in "$W1" "$W2"; do
  docker exec "$node" bash -lc "$JOIN --ignore-preflight-errors=Swap,SystemVerification" >/dev/null
done

echo "==> Waiting for nodes to be Ready"
docker exec "$MASTER" kubectl wait --for=condition=Ready nodes --all --timeout=300s >/dev/null

echo "==> Importing demo image into every node"
for node in "$MASTER" "$W1" "$W2"; do
  docker cp /home/vagrant/cda-demo.tar "$node":/tmp/cda-demo.tar
  docker exec "$node" ctr -n k8s.io images import /tmp/cda-demo.tar >/dev/null
done

echo "==> Applying demo and metrics-server"
docker cp /home/vagrant/manifests/demo.yaml "$MASTER":/tmp/demo.yaml
docker cp /home/vagrant/manifests/metrics-server.yaml "$MASTER":/tmp/metrics-server.yaml
docker cp /home/vagrant/bench.mjs "$MASTER":/tmp/bench.mjs
docker cp /home/vagrant/bench-run.sh "$MASTER":/tmp/bench-run.sh
docker cp /home/vagrant/load.yaml "$MASTER":/tmp/load.yaml
docker exec "$MASTER" kubectl apply -f /tmp/demo.yaml >/dev/null
docker exec "$MASTER" kubectl apply -f /tmp/metrics-server.yaml >/dev/null
docker exec "$MASTER" kubectl -n kube-system rollout status deploy/metrics-server --timeout=300s >/dev/null
docker exec "$MASTER" kubectl rollout status deploy/demo --timeout=300s >/dev/null

# Tiny helper so the four demos can be run inside the VM with just `k ...`.
cat > /usr/local/bin/k <<EOF
#!/bin/sh
exec sudo docker exec $MASTER kubectl "\$@"
EOF
chmod +x /usr/local/bin/k

echo "==> Ready"
docker exec "$MASTER" kubectl get nodes -o wide
docker exec "$MASTER" kubectl get pods -o wide
