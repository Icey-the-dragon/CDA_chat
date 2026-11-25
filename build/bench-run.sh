#!/bin/sh
set -e
SVC="$(kubectl get svc demo -o jsonpath='{.spec.clusterIP}')"
sed "s/__SVC__/$SVC/" /tmp/bench.mjs > /tmp/bench-ready.mjs
POD="$(kubectl get pods -l app=demo --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')"
kubectl cp /tmp/bench-ready.mjs "$POD":/tmp/bench.mjs
kubectl exec "$POD" -- node /tmp/bench.mjs
