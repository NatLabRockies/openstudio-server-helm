#!/usr/bin/env bash
# Rebuild the nginx upstream on the OpenStudio proxy VM from a Kubernetes cluster's node list.
#
# Reads the web Service NodePort and the node InternalIPs with kubectl, checks which nodes
# answer on that NodePort *from the proxy VM*, rewrites the upstream block, validates with
# `nginx -t`, reloads nginx, and rolls back if validation fails.
#
# Usage:
#   update-proxy-upstream.sh --proxy-host 10.60.105.249 --ssh-user cloud --ssh-key ~/.ssh/id_rsa \
#       --kubeconfig ~/.kube/my-cluster.yaml
#   update-proxy-upstream.sh --local ...   # run directly on the proxy VM (kubectl must be installed there)
#
# Run with --help for all options. Compatible with bash 3.2 (macOS default).
set -euo pipefail

NAMESPACE="${NAMESPACE:-openstudio-server}"
SERVICE="${SERVICE:-web}"
PORT_NAME="${PORT_NAME:-}"            # defaults to the first port of the Service
NODEPORT="${NODEPORT:-}"              # defaults to the Service's NodePort
KUBECONFIG_PATH="${KUBECONFIG:-}"
PROXY_HOST="${PROXY_HOST:-}"
SSH_USER="${SSH_USER:-cloud}"
SSH_KEY="${SSH_KEY:-}"
NGINX_CONF="${NGINX_CONF:-/etc/nginx/conf.d/proxy.conf}"
UPSTREAM_NAME="${UPSTREAM_NAME:-openstudio_backend}"
NODE_SELECTOR="${NODE_SELECTOR:-}"    # optional label selector, e.g. "node-role.kubernetes.io/worker"
INCLUDE_CONTROL_PLANE=false
SKIP_VERIFY=false
DRY_RUN=false
LOCAL=false

usage() {
  cat <<EOF
Options (env var equivalents in parentheses):
  --proxy-host HOST      Proxy VM address (PROXY_HOST). Required unless --local.
  --ssh-user USER        SSH user on the proxy VM (SSH_USER, default: cloud)
  --ssh-key PATH         SSH private key (SSH_KEY)
  --kubeconfig PATH      Kubeconfig for the cluster (KUBECONFIG)
  --namespace NS         Namespace of the web Service (NAMESPACE, default: openstudio-server)
  --service NAME         Service exposing the web app (SERVICE, default: web)
  --port-name NAME       Service port name to use (PORT_NAME, default: first port)
  --nodeport PORT        Override the NodePort (NODEPORT)
  --node-selector SEL    kubectl label selector to restrict nodes (NODE_SELECTOR)
  --include-control-plane  Also consider control-plane nodes
  --nginx-conf PATH      nginx config file containing the upstream (NGINX_CONF)
  --upstream-name NAME   Upstream block name (UPSTREAM_NAME, default: openstudio_backend)
  --skip-verify          Do not test nodes from the proxy VM; use every Ready node
  --dry-run              Print the resulting upstream block and exit
  --local                Run on the proxy VM itself instead of via SSH
  -h, --help             Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --proxy-host) PROXY_HOST="$2"; shift 2 ;;
    --ssh-user) SSH_USER="$2"; shift 2 ;;
    --ssh-key) SSH_KEY="$2"; shift 2 ;;
    --kubeconfig) KUBECONFIG_PATH="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --service) SERVICE="$2"; shift 2 ;;
    --port-name) PORT_NAME="$2"; shift 2 ;;
    --nodeport) NODEPORT="$2"; shift 2 ;;
    --node-selector) NODE_SELECTOR="$2"; shift 2 ;;
    --include-control-plane) INCLUDE_CONTROL_PLANE=true; shift ;;
    --nginx-conf) NGINX_CONF="$2"; shift 2 ;;
    --upstream-name) UPSTREAM_NAME="$2"; shift 2 ;;
    --skip-verify) SKIP_VERIFY=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --local) LOCAL=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }
if ! $LOCAL && [[ -z "$PROXY_HOST" ]]; then
  echo "--proxy-host is required unless --local is used" >&2; exit 2
fi

KUBECTL=(kubectl)
[[ -n "$KUBECONFIG_PATH" ]] && KUBECTL+=(--kubeconfig "$KUBECONFIG_PATH")

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
[[ -n "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY" -o IdentitiesOnly=yes)

run_on_proxy() {
  if $LOCAL; then bash -s -- "$@"; else ssh "${SSH_OPTS[@]}" "${SSH_USER}@${PROXY_HOST}" bash -s -- "$@" 2> >(grep -v -e '^\*\*' >&2); fi
}

if [[ -z "$NODEPORT" ]]; then
  if [[ -n "$PORT_NAME" ]]; then
    jp="{.spec.ports[?(@.name==\"${PORT_NAME}\")].nodePort}"
  else
    jp='{.spec.ports[0].nodePort}'
  fi
  svc_type="$("${KUBECTL[@]}" -n "$NAMESPACE" get svc "$SERVICE" -o jsonpath='{.spec.type}')"
  NODEPORT="$("${KUBECTL[@]}" -n "$NAMESPACE" get svc "$SERVICE" -o jsonpath="$jp")"
  if [[ -z "$NODEPORT" || "$svc_type" == "ClusterIP" ]]; then
    echo "Service ${NAMESPACE}/${SERVICE} is type ${svc_type} with no NodePort; set it to NodePort first." >&2
    exit 1
  fi
fi
echo "Service ${NAMESPACE}/${SERVICE} NodePort: ${NODEPORT}"

selector_args=()
[[ -n "$NODE_SELECTOR" ]] && selector_args=(-l "$NODE_SELECTOR")
# One line per node: name Ready(True/False) control-plane(yes/no) InternalIP
tmpl='{{range .items}}{{$n:=.metadata.name}}{{$r:="False"}}{{range .status.conditions}}{{if eq .type "Ready"}}{{$r = .status}}{{end}}{{end}}{{$cp:="no"}}{{if index .metadata.labels "node-role.kubernetes.io/control-plane"}}{{$cp = "yes"}}{{end}}{{range .status.addresses}}{{if eq .type "InternalIP"}}{{$n}} {{$r}} {{$cp}} {{.address}}{{"\n"}}{{end}}{{end}}{{end}}'
rows="$("${KUBECTL[@]}" get nodes ${selector_args[@]+"${selector_args[@]}"} -o go-template="$tmpl")"

candidates=()
while read -r name ready cp ip; do
  [[ -n "$name" ]] || continue
  [[ "$ready" == "True" ]] || { echo "skip (not Ready): $name"; continue; }
  if [[ "$cp" == "yes" ]] && ! $INCLUDE_CONTROL_PLANE; then echo "skip (control-plane): $name"; continue; fi
  candidates+=("$ip")
done <<<"$rows"
[[ ${#candidates[@]} -gt 0 ]] || { echo "No candidate nodes found." >&2; exit 1; }
echo "Candidate nodes: ${candidates[*]}"

if $SKIP_VERIFY; then
  servers=("${candidates[@]}")
else
  out="$(run_on_proxy "$NODEPORT" "${candidates[@]}" <<'EOF'
port="$1"; shift
for ip in "$@"; do
  code=$(curl -s -m 4 -o /dev/null -w '%{http_code}' "http://${ip}:${port}/" || true)
  [ "$code" != "000" ] && echo "$ip"
done
exit 0
EOF
)"
  servers=()
  while read -r ip; do [[ -n "$ip" ]] && servers+=("$ip"); done <<<"$out"
fi
[[ ${#servers[@]} -gt 0 ]] || { echo "No node is reachable on ${NODEPORT} from the proxy VM." >&2; exit 1; }
echo "Upstream nodes: ${servers[*]}"

if $DRY_RUN; then
  echo "upstream ${UPSTREAM_NAME} {"
  for ip in "${servers[@]}"; do echo "  server ${ip}:${NODEPORT};"; done
  echo "}"
  exit 0
fi

run_on_proxy "$NGINX_CONF" "$UPSTREAM_NAME" "$NODEPORT" "${servers[@]}" <<'EOF'
set -euo pipefail
conf="$1"; name="$2"; port="$3"; shift 3
sudo test -f "$conf" || { echo "$conf not found" >&2; exit 1; }
backup="${conf}.bak.$(date +%Y%m%d%H%M%S)"
sudo cp -p "$conf" "$backup"
tmp=$(mktemp)
servers=""
for ip in "$@"; do servers="${servers}  server ${ip}:${port};"$'\n'; done
sudo awk -v name="$name" -v servers="$servers" '
  index($0, "upstream " name " {") == 1 { printf "upstream %s {\n%s}\n", name, servers; skip=1; next }
  skip && /^\}/ { skip=0; next }
  !skip { print }' "$conf" > "$tmp"
grep -q "^upstream ${name} {" "$tmp" || { echo "upstream ${name} not found in $conf" >&2; rm -f "$tmp"; exit 1; }
sudo install -m 0644 -o root -g root "$tmp" "$conf"
rm -f "$tmp"
if sudo nginx -t 2>&1; then
  sudo systemctl reload nginx
  echo "nginx reloaded; backup at $backup"
else
  echo "nginx -t failed; restoring $backup" >&2
  sudo cp -p "$backup" "$conf"
  exit 1
fi
EOF
echo "Done."
