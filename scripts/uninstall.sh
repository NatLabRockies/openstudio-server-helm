#!/usr/bin/env bash
# Uninstall the openstudio-server release.
#
# The chart's pre-delete hook (templates/hooks/pre-delete-hook.yaml) handles
# the cleanup ordering: it deletes the app Deployments/StatefulSets (web,
# web-background, rserve, worker, db, redis) while deliberately KEEPING the
# NFS server provisioner up until the NFS clients have unmounted, then Helm
# deletes the remaining release resources.
#
# Do NOT manually `kubectl delete deployment web web-background rserve` before
# uninstalling -- that races the hook and can leave the release in a broken
# half-deleted state. The hook now runs without `--wait` so Failed/Error pods
# (e.g. OOM-killed web) do not block it, and the hook Job itself will be
# removed by Helm once it succeeds.
#
# Usage:
#   scripts/uninstall.sh [--namespace <ns>] [--timeout 10m]
#
# NOTE: while the cluster's external API-facing gateway has intermittent
# 502s (see docs/port-forward-and-jump-pod-troubleshooting.md), `helm uninstall` makes many
# sequential API calls and can fail outright even though the cluster is
# healthy. This wraps it (and the verification kubectl call) in retries
# instead of treating the first 502 as fatal.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib/retry_cmd.sh

NAMESPACE="${NAMESPACE:-openstudio-server}"
RELEASE="${RELEASE:-openstudio-server}"
TIMEOUT="${TIMEOUT:-10m}"

echo "Uninstalling Helm release '${RELEASE}' from namespace '${NAMESPACE}' (timeout ${TIMEOUT})..."
retry_cmd helm uninstall "${RELEASE}" --namespace "${NAMESPACE}" --wait --timeout "${TIMEOUT}" --debug

echo "Verifying remaining resources in namespace '${NAMESPACE}':"
retry_cmd kubectl get all,pvc,cm,secret,sa,role,rolebinding,job -n "${NAMESPACE}" || echo "  (namespace '${NAMESPACE}' is empty or no longer exists)"
