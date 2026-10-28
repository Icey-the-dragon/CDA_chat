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
      
      # Copy kubeconfig to /vagrant so your host/master can use it if synced
      sudo cp /etc/rancher/k3s/k3s.yaml /vagrant/kubeconfig.yaml 2>/dev/null || true
      sudo chmod 644 /vagrant/kubeconfig.yaml 2>/dev/null || true
    SHELL
  end

  # Worker Nodes
  nodes = {
    "k3s-worker-grafana" => "192.168.56.11",
    "k3s-worker-db"      => "192.168.56.12",
    "k3s-worker-chat"    => "192.168.56.13",
    "k3s-worker-nginx"   => "192.168.56.14"
  }

  nodes.each do |name, ip|
    config.vm.define name do |node|
      node.vm.hostname = name
      node.vm.network "private_network", ip: ip
      node.vm.provider "virtualbox" do |vb|
        vb.memory = "512" # 1GB minimum per worker for databases/apps
        vb.cpus = 1
      end
      node.vm.provision "shell", inline: <<-SHELL
        echo "Waiting for K3s Master API to become available..."
        until curl -k -s https://192.168.56.10:6443/cacerts > /dev/null; do
          sleep 3
        done

        echo "Installing K3s Worker and joining master..."
        curl -sfL https://get.k3s.io | K3S_URL="https://192.168.56.10:6443" K3S_TOKEN="#{K3S_TOKEN}" sh -s - agent --node-ip #{ip}
      SHELL
    end
  end
end