Vagrant.configure("2") do |config|
  config.vm.box = "ubuntu/jammy64"

  # A loaded host (or one that just resumed from sleep) can take longer than
  # net-ssh's 15 second banner timeout before a VM answers. Retry instead of
  # failing provisioning with "timeout during server version negotiating".
  config.ssh.connect_timeout = 60
  config.ssh.connect_retries = 10
  config.ssh.connect_retry_delay = 5
  config.vm.boot_timeout = 600

  # ise rsync or disable shared folders to avoid Windows NFS/vboxsf errors
  config.vm.synced_folder ".", "/vagrant", type: "rsync",
    rsync__exclude: [".git/", ".vagrant/", "node_modules/"] # keep node_modules out of the VMs

  # static pass so workers cn join instantly without waiting
  K3S_TOKEN = "supah-secret-:3" #private token / password to join cluster

  # Worker topology. Each worker applies its own role label when it joins.
  nodes = {
    "k3s-worker-grafana" => { ip: "192.168.56.11", role: "grafana", memory: "756" },
    "k3s-worker-db"      => { ip: "192.168.56.12", role: "db",      memory: "1024" }, # MariaDB needs headroom
    # The app worker hosts the autoscaled chat replicas. Keep it at 1 vCPU:
    # with Windows Hyper-V enabled, VirtualBox falls back to NEM and this guest
    # hangs during boot when it has 2 vCPUs (the 1 vCPU config boots reliably).
    # The HPA demo still has plenty of CPU pressure because the chat pods
    # request 100m each and the load generator drives them past 60%.
    "k3s-worker-chat"    => { ip: "192.168.56.13", role: "chat",    memory: "1536", cpus: 1 },
    "k3s-worker-nginx"   => { ip: "192.168.56.14", role: "nginx",   memory: "512", forward_port: 8080, node_port: 30080 } # webUI /grafana proxied to graphana WebUI, etc
  }

  # Master Node (Controller)
  config.vm.define "k3s-master" do |master|
    master.vm.network "private_network", ip: "192.168.56.10"

    master.vm.hostname = "k3s-master" # <--- Unique Hostname

    master.vm.provider "virtualbox" do |vb|
      vb.memory = "1536" # At least 1.5GB for master
      vb.cpus = 2
    end
    master.vm.provision "shell", inline: <<-SHELL
      echo "Installing K3s Master..."
      curl -sfL https://get.k3s.io | K3S_TOKEN="#{K3S_TOKEN}" sh -s - server --cluster-init \
        --node-ip 192.168.56.10 \
        --advertise-address 192.168.56.10 \
        --node-name k3s-master \
        --node-label role=control-plane \
        --node-label node-role.kubernetes.io/control-plane= \
        --flannel-iface enp0s8
      
      # Copy kubeconfig to /vagrant so your host/master can use it if synced (mostly if i want to attach from host something)
      sudo cp /etc/rancher/k3s/k3s.yaml /vagrant/kubeconfig.yaml 2>/dev/null || true
      sudo chmod 644 /vagrant/kubeconfig.yaml 2>/dev/null || true

      # Make the label idempotent for clusters created before this line existed.
      sudo k3s kubectl label node k3s-master \
        role=control-plane \
        node-role.kubernetes.io/control-plane= \
        --overwrite 2>/dev/null || true

      if [ -d "/vagrant/kubernetes" ]; then
        sudo k3s kubectl apply -f /vagrant/kubernetes/
        # default.conf is mounted with subPath, so ConfigMap updates do not
        # reach the running nginx pod. Roll it on every provision.
        sudo k3s kubectl rollout restart deployment/nginx-router 2>/dev/null || true
      else
        echo "Manifests folder not found!"
      fi
    SHELL
  end

  # Worker Nodes
  nodes.each do |name, info|
    config.vm.define name do |node|
      node.vm.hostname = name
      node.vm.network "private_network", ip: info[:ip]
      node.vm.provider "virtualbox" do |vb|
        vb.memory = info[:memory] || "512"
        vb.cpus = info[:cpus] || 1
      end

      #port forwards
      if info[:forward_port]
        node.vm.network "forwarded_port", guest: info[:node_port], host: info[:forward_port]
      end

      node.vm.provision "shell", inline: <<-SHELL
        # k3s imports every tarball found in this directory when it starts, so
        # the locally built chat image exists before the pod is scheduled.
        # The tarball is built on the host and reaches this VM through /vagrant.
        if [ "#{info[:role]}" = "chat" ]; then
          if [ -f /vagrant/images/chat-server.tar ]; then
            echo "Preloading chat-server image from /vagrant/images/chat-server.tar..."
            sudo mkdir -p /var/lib/rancher/k3s/agent/images
            sudo cp /vagrant/images/chat-server.tar /var/lib/rancher/k3s/agent/images/chat-server.tar
          else
            echo "WARNING: /vagrant/images/chat-server.tar not found; the chat pod will stay in ErrImagePull."
          fi
        fi

        echo "Waiting for K3s Master API..."
        until curl -k -s https://192.168.56.10:6443/cacerts > /dev/null; do
        sleep 3
        done

        echo "Joining cluster and applying role=#{info[:role]}..."
        curl -sfL https://get.k3s.io | K3S_URL="https://192.168.56.10:6443" K3S_TOKEN="#{K3S_TOKEN}" sh -s - agent \
        --node-ip #{info[:ip]} \
        --node-name #{name} \
        --node-label role=#{info[:role]} \
        --node-label node-role.kubernetes.io/#{info[:role]}= \
        --flannel-iface enp0s8
        # thank god for predictable network interface names 

        # On a re-provision the agent is already running, so import a rebuilt
        # tarball immediately instead of waiting for the next k3s restart.
        if [ "#{info[:role]}" = "chat" ] && [ -f /vagrant/images/chat-server.tar ] && systemctl is-active --quiet k3s-agent; then
          for attempt in 1 2 3 4 5; do
            sudo k3s ctr images import /vagrant/images/chat-server.tar && break
            sleep 3
          done
        fi
        SHELL
    end
  end
end