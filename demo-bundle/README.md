# Demo Kubernetes en 3 nodos (k3d) — 4 cosas que pide el ejercicio

Todo se crea con **Docker + k3d**: 1 control-plane y 2 workers como contenedores.
No hace falta Vagrant, VirtualBox ni `kubectl` en el host más allá del binario
cliente. Arranca en ~1 minuto.

## Requisitos (una vez)

```bash
sudo pacman -S docker k3d kubectl curl     # Arch
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"            # cerrar sesión y volver a entrar
docker info                                # debe funcionar SIN sudo
```

En Docker Desktop/WSL: instalar k3d y kubectl dentro de la distro, activar la
integración WSL y clonar/copiar esta carpeta en ext4 (no en `/mnt/c` ni `/mnt/e`).
Necesitas los puertos `8080` y `8081` libres.

## Arrancar

Desde dentro de la carpeta del ZIP:

```bash
bash start.sh
```

Eso carga `images/cda-demo.tar`, crea el cluster `cda-demo`, importa la imagen
en los 3 nodos y deja 2 réplicas del Deployment `demo` corriendo.

Comprobación rápida:

```bash
kubectl get nodes -o wide
kubectl get pods -o wide
curl http://localhost:8080/healthz
```

Cuando termines: `bash teardown.sh`.

---

## 1) Balanceo de carga

Ver qué réplica responde (los nombres de pod cambian):

```bash
for i in $(seq 1 8); do curl -s http://localhost:8080/api/whoami; echo; done
```

Comparar **sin balanceo** (port-forward a un solo pod, `:8081`) contra **con
balanceo** (Service, `:8080`). Son 20 peticiones que consumen 300 ms de CPU
cada una, con 10 concurrentes: un solo pod tarda el doble que dos:

```bash
bash bench.sh
```

Salida esperada: sin balanceo ~3000 ms, con balanceo ~1500 ms. Puedes cambiar
la carga con `N=40 PAR=10 bash bench.sh`.

## 2) Escalado horizontal

**Manual:**

```bash
kubectl scale deployment/demo --replicas=4
kubectl get pods -l app=demo
kubectl scale deployment/demo --replicas=2
```

**Automático por CPU** (el HPA va de 2 a 4 al superar el 50% de CPU):

```bash
kubectl apply -f manifests/load.yaml
watch kubectl get hpa,pods -l app=demo
```

En ~15 s `REPLICAS` pasa de 2 a 4. Justo al escalar puede aparecer `<unknown>`
unos segundos mientras las réplicas nuevas empiezan a enviar métricas. Cuando
`TARGETS` marque más del 50% y `REPLICAS` esté en 4:

```bash
kubectl delete job demo-load
watch kubectl get hpa -w          # vuelve a 2 tras la ventana de estabilización
```

## 3) Fallo de un pod

```bash
kubectl get pods -l app=demo -w
```

En otra terminal:

```bash
kubectl delete pod -l app=demo
```

Verás los pods morir y aparecer otros nuevos automáticamente: el ReplicaSet
mantiene siempre las réplicas configuradas. Si habías escalado a 4, se
recrearán 4.

## 4) Fallo del nodo master

```bash
docker stop k3d-cda-demo-server-0
kubectl get nodes --request-timeout=5s   # deja de responder
curl --max-time 3 http://localhost:8080/healthz   # los pods siguen levantados
docker start k3d-cda-demo-server-0
docker restart k3d-cda-demo-serverlb     # el proxy necesita reconectar
kubectl get nodes                        # vuelve a responder
```

**¿Es posible?** Sí, y en este cluster es un único punto de fallo: el API server
y etcd viven solo en ese contenedor. Los pods de los workers siguen corriendo
(por eso el `curl` sigue funcionando), pero Kubernetes deja de aceptar cambios,
de programar pods y de recrear los que fallan. Para que el control-plane sea
tolerante a fallos hacen falta **3 control-planes** (número impar, para que etcd
tenga quórum) y un balanceador delante del API server. Se puede crear con
`servers: 3` en `k3d-cluster.yaml`.

Nota: `start.sh` marca el nodo control-plane con `NoSchedule`, así que los
pods de la demo solo corren en los 2 workers. En el apagado se aprecia que los
pods no se caen; lo que desaparece es la capacidad de gestionarlos.

---

## Notas

- `start.sh` modifica el contexto actual de kubectl a `k3d-cda-demo`;
  `bash teardown.sh` borra el cluster.
- El ZIP incluye `cda-demo:latest` y la imagen de k3s fijada, así que no se
  compila nada. k3d solo puede descargar sus dos imágenes auxiliares pequeñas
  (`k3d-tools`, `k3d-proxy`) si no están en caché.
- Si `bench.sh` pierde el port-forward tras borrar pods, vuelve a ejecutarlo:
  lo recrea automáticamente.
