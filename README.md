# CDA · Kubernetes con kubeadm en una sola VM

Este repo contiene solo lo necesario para **entregar, usar y recrear** el
montaje minimalista: una VM de VirtualBox con Docker y tres contenedores
(`cda-master`, `cda-worker-1`, `cda-worker-2`) que forman un clúster kubeadm
de 1 master + 2 workers. Ya incluye Flannel, metrics-server, la app de demo,
Service NodePort `30080` y HPA `2 → 4`.

## Usarlo (profesor)

Copiar la carpeta `delivery/` al PC y ejecutar:

- Windows: `start.bat`
- Linux: `./start.sh`

El script importa `cda-kubeadm.ova` si hace falta, arranca la VM, espera a
`http://127.0.0.1:8080/healthz` y abre el navegador. No hacen falta Vagrant,
Docker, kubectl ni Internet en el PC del profesor.

Detalles y las cuatro comprobaciones están en `delivery/README.txt`.

## Recrearlo (PC de construcción)

Requisitos en el PC que construye: Docker, Vagrant, VirtualBox y la box
`ubuntu/jammy64` ya cacheada.

1. Si faltan las imágenes (están ignoradas por Git), generarlas:

   ```bash
   docker build -f build/kubeadm-node.Dockerfile --build-arg K8S_MINOR=1.31 \
     -t cda-kubeadm-node:latest build
   docker save -o build/images/kubeadm-node.tar cda-kubeadm-node:latest

   docker build -t cda-demo:latest demo-bundle/app
   docker save -o build/images/cda-demo.tar cda-demo:latest
   ```

2. Crear y aprovisionar la VM:

   ```bash
   cd build
   vagrant up
   ```

   `build/setup.sh` desactiva swap, fija red independiente de la MAC, instala
   Docker, levanta los 3 nodos, hace `kubeadm init`, instala Flannel, une los
   workers, importa la imagen de la app y aplica los manifiestos.

3. Comprobar y **apagar limpiamente** (importante: no usar `vagrant halt`):

   ```bash
   vagrant ssh -c "curl -s http://127.0.0.1:30080/healthz; echo; sudo poweroff"
   ```

4. Exportar el OVA:

   ```bash
   VBoxManage modifyvm CDA-Kubeadm-VM --natpf1 delete ssh
   VBoxManage export CDA-Kubeadm-VM \
     -o ../delivery/cda-kubeadm.ova --ovf20
   VBoxManage unregistervm CDA-Kubeadm-VM --delete
   ```

5. Probar el entregable con solo `delivery/start.bat` o `delivery/start.sh`.

> El apagado debe ser limpio (`sudo poweroff`). Un apagado forzado deja el
> sistema de archivos en un estado que puede bloquear el arranque tras
> importar el OVA con una MAC nueva.
>
> En Windows con WSL2/Docker Desktop activo, VirtualBox puede caer en el modo
> Hyper-V y volverse extremadamente lento. El Vagrantfile ya fuerza
> `--paravirtprovider legacy` para evitarlo; si aun así la VM no arranca,
> ejecuta `wsl --shutdown` antes de `vagrant up`.

## Archivos

- `build/` — construcción de la VM; no la necesita el profesor.
- `delivery/` — entregable: `start.bat`, `start.sh`, `README.txt` y el OVA.
- `demo-bundle/app/` — código fuente de la app de demo.
- `build/images/` y `*.ova` — ignorados por Git; se generan localmente.
