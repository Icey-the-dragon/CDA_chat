CDA - Kubernetes con kubeadm (una VM)

Requisito: VirtualBox 7 en Windows. Nada mas.

1) Copia esta carpeta al PC del profesor.
2) Ejecuta start.bat (Windows) o start.sh (Linux: ./start.sh).
3) Espera 2-3 minutos. Se abre la VM y el navegador en la URL que indica
   la ventana (normalmente http://127.0.0.1:8080/).

Dentro ya esta todo instalado y configurado: swap desactivada, Flannel,
cluster kubeadm con 1 master + 2 workers, la aplicacion y el HPA.
No hace falta Internet ni Docker en el host.

Dentro de la VM: usuario vagrant, contrasena vagrant. El atajo "k" equivale
a "sudo docker exec cda-master kubectl".

Cuatro comprobaciones (desde una terminal de la VM):

1) Balanceo: abre la web y pulsa "Pedir otra"; el pod cambia.
   sudo docker exec cda-master sh /tmp/bench-run.sh

2) Escalado manual y automatico:
   k scale deployment/demo --replicas=4
   k apply -f /tmp/load.yaml

3) Fallo de un pod:
   k delete pod "$(k get pods -l app=demo -o jsonpath='{.items[0].metadata.name}')"
   k get pods -l app=demo -w

4) Fallo del master:
   sudo docker stop cda-master
   sudo docker start cda-master
   La web sigue respondiendo porque el Service esta en los workers.

Para apagar: cierra la ventana de la VM o ejecuta:
"C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" controlvm CDA-Kubeadm-VM poweroff
