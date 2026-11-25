# Entrega OVA: un script y funciona

Este modo de entrega está pensado para el profesor: **solo necesita
VirtualBox y `curl`**. No necesita Vagrant, Docker, `kubectl`, k3d ni acceso a
Internet. Copia la carpeta del repositorio (con `scripts/` y `ova/`) y ejecuta
un comando.

> Los `.ova` **no están en Git** (son grandes). Se generan una vez y se entregan
> aparte, por ejemplo en un USB o ZIP. `.gitignore` ya excluye `ova/` y `*.ova`.

## En el ordenador del profesor

```bash
# Opción A: demo mínima k3d (1 server + 2 agents), panel visual en :8080
bash scripts/launch-ova.sh demo

# Opción B: laboratorio kubeadm (1 control-plane + 2 workers)
bash scripts/launch-ova.sh kubeadm

# Opción B con comprobación automática incluida
bash scripts/launch-ova.sh kubeadm verify
```

El script:

1. Importa cada OVA si la VM no existe ya.
2. Borra las reglas NAT antiguas (las de Vagrant) y crea solo los
   port-forwards necesarios, ligados a `127.0.0.1`.
3. Crea/configura el adaptador host-only `vboxnet0` (`192.168.56.1/24`) para
   la red estática de los nodos kubeadm.
4. Arranca las VM en orden y espera a que `/healthz` o `/api/health`
   respondan (hasta 420 s por defecto).
5. Abre el navegador en la UI correspondiente.

| Modo | URL | VM |
| --- | --- | --- |
| `demo` | <http://127.0.0.1:8080/> | `cda-demo-vm` |
| `kubeadm` | <http://127.0.0.1:18080/> | `kubeadm-worker-infra` |
| `kubeadm` | <http://127.0.0.1:18081/> | `kubeadm-worker-app` |
| `kubeadm` | <http://127.0.0.1:18082/> | `kubeadm-controlplane` |
| `kubeadm` | <http://127.0.0.1:18080/grafana/> | Grafana |

Las tres URLs de kubeadm llegan al mismo NodePort; usar una u otra demuestra
que el servicio sigue accesible aunque se apague un worker. El puerto 18082
se publica en el control-plane para poder comprobar el escenario de fallo de
master sin depender de los workers.

Para apagar o reimportar limpio:

```bash
bash scripts/launch-ova.sh kubeadm stop
bash scripts/launch-ova.sh kubeadm reset   # borra las VM y las vuelve a importar
```

Opciones útiles:

```bash
NO_OPEN=1 bash scripts/launch-ova.sh demo        # no abrir navegador
VBOX_TYPE=gui bash scripts/launch-ova.sh demo    # ver la consola de las VM
SSH_PF=1 bash scripts/launch-ova.sh kubeadm      # SSH en 2201-2203 (opcional)
WAIT_SECONDS=600 bash scripts/launch-ova.sh kubeadm
HOSTONLY_NET=vboxnet1 HOSTONLY_IP=192.168.56.1 bash scripts/launch-ova.sh kubeadm
```

No ejecutes estos scripts con `sudo`: VirtualBox no debe correr como root.

## Demostrar los cuatro requisitos

### Opción A: demo k3d (la más visual para balanceo)

Tras `bash scripts/launch-ova.sh demo`, abre <http://127.0.0.1:8080/>. El panel
muestra pod y nodo de cada respuesta, barras por réplica y latencias.

```bash
# Balanceo: cambia el pod que responde
for i in $(seq 1 8); do curl -s http://127.0.0.1:8080/api/whoami; echo; done

# Comparación con/sin balanceo (se ejecuta DENTRO de la VM)
bash scripts/ova-exec.sh cda-demo-vm 'cd /opt/demo-bundle && bash bench.sh'

# Escalado manual
bash scripts/ova-exec.sh cda-demo-vm 'kubectl scale deployment/demo --replicas=4'

# Fallo de UN pod
bash scripts/ova-exec.sh cda-demo-vm \
  'POD=$(kubectl get pods -l app=demo --field-selector=status.phase=Running -o jsonpath="{.items[0].metadata.name}"); kubectl delete pod "$POD"; kubectl get pods -l app=demo -w'

# Escalado automático por CPU (HPA 2 -> 4)
bash scripts/ova-exec.sh cda-demo-vm 'kubectl apply -f /opt/demo-bundle/manifests/load.yaml'
bash scripts/ova-exec.sh cda-demo-vm 'kubectl get hpa -w'

# Fallo del master de k3d: la app sigue viva, la API deja de responder
VBoxManage controlvm cda-demo-vm poweroff
```

En k3d el "master" es un contenedor dentro de la VM; el SPOF real es el
`server-0`. Apagando toda la VM se ve el efecto equivalente: la app se apaga
con ella. Para una demo de master con la app todavía corriendo, usa la Opción B.

### Opción B: kubeadm (la que pide la práctica)

Tras `bash scripts/launch-ova.sh kubeadm`:

```bash
# Comprobación completa: swap, CNI, Ready, HPA, pod y worker
bash scripts/kubeadm-verify-ova.sh

# Los 11 escenarios de fallo, con comprobación de round-trip tras cada uno
bash scripts/kubeadm-chaos-ova.sh

# kubectl dentro del control-plane (sin kubectl en el host)
bash scripts/kubeadm-ova-kubectl.sh get nodes -o wide
bash scripts/kubeadm-ova-kubectl.sh get pods -o wide
```

1. **Balanceo:** dos réplicas de `chat-server` y dos de `nginx-router` detrás
   del Service. Los escenarios del chaos suite comprueban el round-trip
   POST/GET tras matar pods.
2. **Escalado manual y automático:**
   ```bash
   bash scripts/kubeadm-ova-kubectl.sh scale deployment/chat-server --replicas=4
   bash scripts/kubeadm-ova-kubectl.sh apply -f /opt/cda-chat/kubernetes/demo/load-generator.yaml
   bash scripts/kubeadm-ova-kubectl.sh get hpa chat-server -w
   ```
   De vuelta a 2 con `--replicas=2`. El HPA del laboratorio va de 2 a 4 al 60 %
   de CPU.
3. **Fallo de un pod:**
   ```bash
   POD="$(bash scripts/kubeadm-ova-kubectl.sh get pods -l app=chat-server \
     --field-selector=status.phase=Running \
     -o jsonpath='{.items[0].metadata.name}' | tr -d '\r')"
   bash scripts/kubeadm-ova-kubectl.sh delete pod "$POD"
   bash scripts/kubeadm-ova-kubectl.sh get pods -l app=chat-server -w
   ```
   El ReplicaSet crea otro pod automáticamente.
4. **Fallo del master:**
   ```bash
   bash scripts/kubeadm-controlplane-failure-ova.sh
   ```
   Detiene el kubelet del control-plane y comprueba que
   `http://127.0.0.1:18080/api/health` y `:18081` siguen respondiendo. Es
   posible porque los pods ya programados siguen corriendo en los workers y el
   Service/NodePort sigue enrutando. No es tolerancia a fallos completa: sin
   API server no se pueden crear pods ni sustituir los que fallan. Para eso
   harían falta 3 control-planes (quórum etcd) y un balanceador del API.

Los resultados se guardan en `docs/evidence/kubeadm-verify.txt`,
`kubeadm-chaos.txt` y `kubeadm-controlplane-failure.txt`.

Los comandos `*-ova.sh` usan `VBoxManage guestcontrol` mediante
`scripts/ova-bin/vagrant`, así que no hace falta ni Vagrant ni SSH en el host.
Las credenciales por defecto dentro de las VM son `vagrant`/`vagrant`;
se pueden cambiar con `OVA_GUEST_USER` y `OVA_GUEST_PASSWORD`.

## Preparar los OVA (en la máquina que construye el laboratorio)

Necesitas Vagrant + VirtualBox. El modo kubeadm además necesita Docker para
construir `chat-server:latest`.

```bash
# Demo mínima: VM con Docker + k3d + bundle en /opt/demo-bundle
bash scripts/demo-ova-up.sh
bash scripts/export-ova.sh demo
bash scripts/demo-ova-down.sh        # ya no hace falta la VM original

# Kubeadm: 1 control-plane + 2 workers, con HA y manifiestos aplicados
bash scripts/kubeadm-up.sh
bash scripts/kubeadm-verify.sh
bash scripts/export-ova.sh kubeadm
```

`scripts/export-ova.sh` apaga las VM antes de exportar para que etcd y
containerd queden en un estado consistente, escribe `ova/SHA256SUMS` y un
`ova/README.txt`. El resultado es:

```text
ova/
  demo.ova                      # modo demo
  kubeadm-controlplane.ova
  kubeadm-worker-infra.ova
  kubeadm-worker-app.ova
  SHA256SUMS
  README.txt
```

Copia esa carpeta `ova/` junto con `scripts/` al ordenador del profesor.

## Limitaciones y solución de problemas

- **Tamaño:** tres OVA kubeadm suelen ocupar varios GB. Se entregan aparte;
  no se versionan.
- **Red host-only:** los nodos kubeadm usan IP fijas `192.168.56.20-22`. El
  launcher crea `vboxnet0` si falta. Si ya existe con otra IP, usa
  `HOSTONLY_NET=vboxnet1` (o libera ese adaptador). No hace falta DHCP.
- **Puertos:** `8080`, `18080`, `18081` y `18082` deben estar libres en
  `127.0.0.1`. Cierra otros laboratorios k3d/Vagrant antes de lanzar.
- **Certificados:** los certificados de kubeadm duran aproximadamente un año
  desde la exportación. Si la entrega es muy posterior, vuelve a exportar.
- **SPOF:** queda un único control-plane, tal como pide el enunciado ("un nodo
  máster"). La app sobrevive a su caída, pero Kubernetes pierde la capacidad de
  gestionar pods; está explicado en `docs/KUBEADM_LAB.md`.
- **MAC y reglas NAT:** el launcher regenera las MAC y sustituye las reglas
  NAT importadas, por lo que se pueden importar varias copias del mismo OVA
  sin conflictos.
- **Si la app no responde:** revisa el estado con
  `VBoxManage showvminfo kubeadm-controlplane | grep State` y el log
  `docs/evidence/ova-launch-kubeadm.txt`. Un `reset` suele resolver una
  importación previa defectuosa.
