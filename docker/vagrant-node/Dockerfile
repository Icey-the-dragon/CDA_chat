FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Base image for Vagrant's Docker provider to emulate lab nodes.
# Installs SSH (for Vagrant), systemd, and tools needed by k3s provisioning.
RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-server sudo curl ca-certificates iproute2 iptables \
    conntrack socat ebtables ethtool kmod util-linux \
    systemd systemd-sysv dbus \
  && rm -rf /var/lib/apt/lists/*

# Configure SSH for Vagrant (lab convenience: password auth enabled).
RUN mkdir -p /var/run/sshd \
  && sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config \
  && sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config \
  && echo 'root:vagrant' | chpasswd \
  && (systemctl enable ssh || systemctl enable sshd || true)

# Vagrant typically expects a 'vagrant' user with passwordless sudo.
RUN useradd -m -s /bin/bash vagrant \
  && echo 'vagrant:vagrant' | chpasswd \
  && echo 'vagrant ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/vagrant \
  && chmod 0440 /etc/sudoers.d/vagrant

# Reduce systemd noise in containers.
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
