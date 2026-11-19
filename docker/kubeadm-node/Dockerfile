FROM debian:bookworm-slim

ARG K8S_MINOR=1.36
ENV DEBIAN_FRONTEND=noninteractive

# Debian-based Vagrant Docker-provider "node" for the kubeadm lab.
# Kubernetes tools are baked into the image so `vagrant up` only has to run
# kubeadm init/join instead of installing packages every time.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg apt-transport-https \
    systemd systemd-sysv dbus openssh-server sudo \
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
  && sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml \
  && rm -rf /var/lib/apt/lists/*

# The host's swap cannot be turned off from inside a container. kubeadm's
# preflight is ignored by the scripts, but kubelet also checks swap at runtime.
# This drop-in loads after kubeadm's 10-kubeadm.conf and disables that check.
RUN mkdir -p /etc/systemd/system/kubelet.service.d \
  && printf '[Service]\nEnvironment="KUBELET_EXTRA_ARGS=--fail-swap-on=false"\n' \
       > /etc/systemd/system/kubelet.service.d/20-swap.conf

# SSH access for Vagrant (root password is used by the Docker provider).
# /run is a tmpfs at runtime, so a tmpfiles entry recreates /run/sshd on boot.
RUN mkdir -p /var/run/sshd /etc/tmpfiles.d \
  && printf 'd /run/sshd 0755 root root -\n' > /etc/tmpfiles.d/sshd.conf \
  && sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config \
  && sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config \
  && sed -i 's@session\s*required\s*pam_loginuid.so@session optional pam_loginuid.so@g' /etc/pam.d/sshd \
  && echo 'root:vagrant' | chpasswd \
  && (systemctl enable ssh || true)

# Vagrant SSHes to the container address on port 22.
EXPOSE 22

RUN systemctl mask \
    getty@tty1.service \
    getty-static.service \
    systemd-remount-fs.service \
    systemd-logind.service \
    console-getty.service \
  || true

STOPSIGNAL SIGRTMIN+3
VOLUME ["/sys/fs/cgroup"]
CMD ["/sbin/init"]
