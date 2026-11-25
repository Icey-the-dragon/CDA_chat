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

### La página de la demo

Abre **http://localhost:8080/**. Es un panel que se actualiza solo, sin depender
de la API de Kubernetes ni de servicios externos:

- **Última réplica que respondió** y el nodo donde está.
- **Peticiones del panel**, **réplicas detectadas** y **latencia media**.
- **Distribución entre réplicas**: barras con el número de respuestas por pod.
- **Log en vivo** con hora, pod,endpoint y duración de cada petición.
- Control **Peticiones** (10–10000) y selector **Ligera / CPU (300 ms)** para el
  botón `Generar carga`. Muestra progreso y `req/s` en el log, con un máximo de
  25 peticiones concurrentes para no saturar el navegador.
- Botones `Pedir otra` y `Limpiar`. El interruptor `Auto` activa una petición
  cada 700 ms.
- Aviso: el modo CPU con valores altos tarda mucho (10000 × 300 ms son ~3000 s
  de CPU). Usa el modo **Ligera** para volúmenes grandes.

Todo se calcula en el navegador a partir de las respuestas de `/api/whoami`, así
que verás aparecer nuevos pods en cuanto escale o se recree un ReplicaSet.

Cuando termines: `bash teardown.sh`.

---

## 1) Balanceo de carga

En la página, pulsa `Pedir otra` varias veces: verás cómo cambia el nombre del
pod y cómo crecen las barras de distribución. Por terminal:

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

En otra terminal, borra **un solo pod** por su nombre:

```bash
POD="$(kubectl get pods -l app=demo --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}')"
echo "Borrando $POD"
kubectl delete pod "$POD"
```

Verás ese pod morir y aparecer uno nuevo automáticamente: el ReplicaSet
mantiene siempre las réplicas configuradas. Si habías escalado a 4, se
recrearán 4. (`kubectl delete pod -l app=demo` borraría los cuatro a la vez;
sirve para ver la recuperación completa, pero no es "un pod".)

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
- Si el ZIP incluye `images/cda-demo.tar` y `images/k3s.tar`, no se compila
  nada. Si no están, `start.sh` construye `cda-demo:latest` desde `app/` y k3d
  descarga la imagen de k3s fijada; en ese caso hace falta acceso a un
  registry. La OVA de `scripts/launch-ova.sh demo` ya trae todo precargado.
- Si `bench.sh` pierde el port-forward tras borrar pods, vuelve a ejecutarlo:
  lo recrea automáticamente.
