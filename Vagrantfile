Vagrant.configure("2") do |config|
  config.vm.box = "ubuntu/jammy64"

  # ise rsync or disable shared folders to avoid Windows NFS/vboxsf errors
  config.vm.synced_folder ".", "/vagrant", type: "rsync",
    rsync__exclude: [".git/", ".vagrant/", "node_modules/"] # keep node_modules out of the VMs

  # static pass so workers cn join instantly without waiting
  K3S_TOKEN = "supah-secret-:3" #private token / password to join cluster

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
        --flannel-iface enp0s8
      
      # Copy kubeconfig to /vagrant so your host/master can use it if synced (mostly if i want to attach from host something)
      sudo cp /etc/rancher/k3s/k3s.yaml /vagrant/kubeconfig.yaml 2>/dev/null || true
      sudo chmod 644 /vagrant/kubeconfig.yaml 2>/dev/null || true

      if [ -d "/vagrant/kubernetes" ]; then
        sudo k3s kubectl apply -f /vagrant/kubernetes/
      else
        echo "Manifests folder not found!"
      fi
    SHELL
  end

  # Worker Nodes
  nodes = {
    "k3s-worker-grafana" => { ip: "192.168.56.11", role: "grafana", memory: "768" },
    "k3s-worker-db"      => { ip: "192.168.56.12", role: "db",      memory: "1024" }, # MariaDB needs headroom
    "k3s-worker-chat"    => { ip: "192.168.56.13", role: "chat",    memory: "512" },
    "k3s-worker-nginx"   => { ip: "192.168.56.14", role: "nginx",   memory: "512", forward_port: 8080, node_port: 30080 } # webUI /grafana proxied to graphana WebUI, etc
  }

  nodes.each do |name, info|
    config.vm.define name do |node|
      node.vm.hostname = name
      node.vm.network "private_network", ip: info[:ip]
      node.vm.provider "virtualbox" do |vb|
        vb.memory = info[:memory] || "512"
        vb.cpus = 1
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
          if [ -f /vagrant/chat-server.tar ]; then
            echo "Preloading chat-server image from /vagrant/chat-server.tar..."
            sudo mkdir -p /var/lib/rancher/k3s/agent/images
            sudo cp /vagrant/chat-server.tar /var/lib/rancher/k3s/agent/images/chat-server.tar
          else
            echo "WARNING: /vagrant/chat-server.tar not found; the chat pod will stay in ErrImagePull."
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
        --flannel-iface enp0s8
        # thank god for predictable network interface names 

        # On a re-provision the agent is already running, so import a rebuilt
        # tarball immediately instead of waiting for the next k3s restart.
        if [ "#{info[:role]}" = "chat" ] && [ -f /vagrant/chat-server.tar ] && systemctl is-active --quiet k3s-agent; then
          for attempt in 1 2 3 4 5; do
            sudo k3s ctr images import /vagrant/chat-server.tar && break
            sleep 3
          done
        fi
        SHELL
    end
  end
end