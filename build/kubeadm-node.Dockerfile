FROM debian:bookworm-slim

ARG K8S_MINOR=1.31
ENV DEBIAN_FRONTEND=noninteractive

# One Kubernetes "node" as a container: kubeadm + kubelet + containerd.
# Runs systemd as PID 1 so the services survive a VM reboot.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg apt-transport-https \
      systemd systemd-sysv dbus perl \
      iproute2 iptables conntrack socat ebtables ethtool kmod util-linux \
      containerd \
  && mkdir -p /etc/apt/keyrings \
  && curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key" \
       | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg \
  && echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/ /" \
       > /etc/apt/sources.list.d/kubernetes.list \
  && apt-get update \
  && apt-get install -y --no-install-recommends kubelet kubeadm kubectl \
  && apt-mark hold kubelet kubeadm kubectl \
  && mkdir -p /etc/containerd \
  && containerd config default > /etc/containerd/config.toml \
  && sed -i 's/SystemdCgroup = true/SystemdCgroup = false/' /etc/containerd/config.toml \
  && sed -i 's/^\([[:space:]]*\)snapshotter = .*/\1snapshotter = "native"/' /etc/containerd/config.toml \
  && sed -i 's|sandbox_image = "registry.k8s.io/pause:3.6"|sandbox_image = "registry.k8s.io/pause:3.10"|' /etc/containerd/config.toml \
  && rm -rf /var/lib/apt/lists/*

# Nested containerd uses cgroupfs; swap is already off in the VM.
RUN printf 'KUBELET_EXTRA_ARGS=--fail-swap-on=false --cgroup-driver=cgroupfs\n' \
      > /etc/default/kubelet

RUN systemctl mask \
      getty@tty1.service getty-static.service systemd-remount-fs.service \
      systemd-logind.service console-getty.service || true

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
