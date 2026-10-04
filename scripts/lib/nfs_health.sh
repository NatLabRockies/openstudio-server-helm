#!/usr/bin/env bash
# Shared NFS / cluster health checks. Source this file; needs $NAMESPACE.
#
# Why: if the NFS server pod restarts (e.g. preempted), every NFS client that keeps
# running has a stale mount ("Stale file handle"). web-background and rserve then fail
# every analysis (mkdir /mnt/openstudio -> "File exists", Rserve setwd() -> "Unknown
# variable/method"), so analyses "complete" with 0 datapoints without any visible error.

# Deployments that mount the shared NFS PVC at /mnt/openstudio.
NFS_CLIENT_DEPLOYS="${NFS_CLIENT_DEPLOYS:-web web-background rserve}"

# Returns 0 if the deployment's pod can read/write /mnt/openstudio.
nfs_client_ok() {
  kubectl exec -n "$NAMESPACE" "deploy/$1" -- sh -c \
    't=/mnt/openstudio/.nfs_health_$$; ls /mnt/openstudio >/dev/null 2>&1 && : > "$t" && rm -f "$t"' \
    >/dev/null 2>&1
}

# Fails (return 1) if the chart's PriorityClasses are missing: pods using them cannot be created.
check_priority_classes() {
  local missing=0 pc
  for pc in high-priority low-priority; do
    if ! kubectl get priorityclass "$pc" >/dev/null 2>&1; then
      echo "ERROR: PriorityClass '$pc' is missing; pods that reference it cannot be created." >&2
      missing=1
    fi
  done
  return $missing
}

# Verify every NFS client; restart stale ones (RESTART_STALE=0 only reports).
# Call this BEFORE submitting work; restarting web-background drops any in-flight job.
ensure_nfs_clients_healthy() {
  local d bad=() rc=0
  for d in $NFS_CLIENT_DEPLOYS; do
    kubectl get deploy -n "$NAMESPACE" "$d" >/dev/null 2>&1 || continue
    if nfs_client_ok "$d"; then
      echo "  OK: $d can access /mnt/openstudio"
    else
      echo "  STALE/BROKEN: $d cannot access /mnt/openstudio" >&2
      bad+=("$d")
    fi
  done
  (( ${#bad[@]} == 0 )) && return 0
  if [[ "${RESTART_STALE:-1}" != "1" ]]; then
    echo "Restart these deployments to remount NFS: ${bad[*]}" >&2
    return 1
  fi
  for d in "${bad[@]}"; do
    echo "  restarting $d to remount NFS..."
    kubectl rollout restart -n "$NAMESPACE" "deploy/$d" >/dev/null
  done
  for d in "${bad[@]}"; do
    kubectl rollout status -n "$NAMESPACE" "deploy/$d" --timeout=300s || rc=1
    nfs_client_ok "$d" || { echo "ERROR: $d still cannot access /mnt/openstudio after restart" >&2; rc=1; }
  done
  return $rc
}
