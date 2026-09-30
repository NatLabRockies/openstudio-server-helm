#!/usr/bin/env bash
# Bypass Lens port-forward by using direct kubectl
# Keeps localhost:61570 -> openstudio-server/web:80 alive

NAMESPACE="openstudio-server"
SERVICE="web"
LOCAL_PORT=61570
SERVICE_PORT=80

# Kill any existing kubectl port-forward on this port (including Lens-managed
# ones, which invoke kubectl as `kubectl --kubeconfig <path> port-forward ...`
# so "kubectl port-forward" is not a contiguous substring - match loosely
# instead of requiring "kubectl" and "port-forward" to be adjacent).
pkill -f "kubectl.*port-forward.*${LOCAL_PORT}:${SERVICE_PORT}" 2>/dev/null || true
sleep 1

echo "Starting kubectl port-forward: localhost:${LOCAL_PORT} -> ${SERVICE}:${SERVICE_PORT} (${NAMESPACE})"
kubectl port-forward -n "${NAMESPACE}" "service/${SERVICE}" "${LOCAL_PORT}:${SERVICE_PORT}" >> /tmp/kubectl_port_forward.log 2>&1 &
echo $! > /tmp/kubectl_port_forward.pid
echo "Started PID $(cat /tmp/kubectl_port_forward.pid)"
