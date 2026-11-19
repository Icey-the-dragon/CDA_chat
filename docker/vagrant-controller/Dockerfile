FROM debian:bookworm-slim

ARG VAGRANT_VERSION=2.4.9
ENV DEBIAN_FRONTEND=noninteractive

# "Controller" image: Vagrant + Docker CLI live here. It does NOT run the
# cluster nodes; it talks to the HOST Docker daemon through /var/run/docker.sock
# so the 5 node containers are created as siblings on the host.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg openssh-client docker.io rsync \
  && curl -fsSL "https://releases.hashicorp.com/vagrant/${VAGRANT_VERSION}/vagrant_${VAGRANT_VERSION}-1_amd64.deb" \
      -o /tmp/vagrant.deb \
  && (dpkg -i /tmp/vagrant.deb || apt-get -f install -y) \
  && rm -f /tmp/vagrant.deb \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

CMD ["bash"]
