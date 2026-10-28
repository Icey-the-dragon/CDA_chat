Vagrant.configure("2") do |config|
  config.vm.box = "ubuntu/jammy64"

  # ise rsync or disable shared folders to avoid Windows NFS/vboxsf errors
  config.vm.synced_folder ".", "/vagrant", type: "rsync" #opt:, disabled: true, you can disable since we are copying the agent file from worker nodes via a private network and token ( not secure, should probably be a straight copy or .env)

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
      curl -sfL https://get.k3s.io | K3S_TOKEN="#{K3S_TOKEN}" sh -s - server --cluster-init
      
      # Copy kubeconfig to /vagrant so your host/master can use it if synced (mostly if i want to attach from host something)
      sudo cp /etc/rancher/k3s/k3s.yaml /vagrant/kubeconfig.yaml 2>/dev/null || true
      sudo chmod 644 /vagrant/kubeconfig.yaml 2>/dev/null || true

      if [ -d "/vagrant/manifests" ]; then
        sudo k3s kubectl apply -f /vagrant/kubernetes/
      else
        echo "Manifests folder not found!"
      fi
    SHELL
  end

  # Worker Nodes
  nodes = {
    "k3s-worker-grafana" => { ip: "192.168.56.11", role: "grafana" },
    "k3s-worker-db"      => { ip: "192.168.56.12", role: "db" },
    "k3s-worker-chat"    => { ip: "192.168.56.13", role: "chat" },
    "k3s-worker-nginx"   => { ip: "192.168.56.14", role: "nginx", forward_port: 8080, node_port: 30080 } # webUI /grafana proxied to graphana WebUI, etc
  }

  nodes.each do |name, info|
    config.vm.define name do |node|
      node.vm.hostname = name
      node.vm.network "private_network", ip: info[:ip]
      node.vm.provider "virtualbox" do |vb|
        vb.memory = "512" # 1GB minimum per worker for databases/apps
        vb.cpus = 1
      end

      #port forwards
      if info[:forward_port]
        node.vm.network "forwarded_port", guest: info[:node_port], host: info[:forward_port]
      end

      node.vm.provision "shell", inline: <<-SHELL
        echo "Waiting for K3s Master API..."
        until curl -k -s https://192.168.56.10:6443/cacerts > /dev/null; do
        sleep 3
        done

        echo "Joining cluster and applying role=#{info[:role]}..."
        curl -sfL https://get.k3s.io | K3S_URL="https://192.168.56.10:6443" K3S_TOKEN="#{K3S_TOKEN}" sh -s - agent \
        --node-ip #{info[:ip]} \
        --node-name #{name} \
        --node-label role=#{info[:role]}
        SHELL
    end
  end
end