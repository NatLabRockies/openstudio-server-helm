#!/usr/bin/env bash
# Submit an openstudio-bem-to-surrogate-gem rake task (e.g. execute_sequential)
# from *inside* the cluster via the jump-pod, instead of over the
# kubectl port-forward tunnel (localhost:61570), which drops on long runs.
#
# Requires jump_pod.enabled=true (helm --set jump_pod.enabled=true).
#
# What this does:
#   1. Packs a minimal copy of the gem project (skips vendored .bundle gems, .venv,
#      measure test output,
#      old outputs/, spec/integration, tmp, sweep_results, SR1, notebook)
#   2. Copies it into the jump pod under /mnt/openstudio/bem-to-surrogate (PVC)
#   3. Rewrites the *copy's* configs.yml to use the in-cluster server URL
#      and the openstudio_meta CLI already baked into the pod image
#   4. Installs any missing gem deps (image ships most of them already),
#      self-healing stale Gemfile.lock entries that bundler flags
#   5. Launches `rake <task>` detached (setsid/nohup) inside the pod so a
#      dropped kubectl exec/tunnel does NOT kill the run
#
# Usage:
#   ./submit_from_jump_pod.sh /path/to/openstudio-bem-to-surrogate-gem [rake_task]
#
# rake_task defaults to execute_sequential (e.g. pass "execute" or
# "submit_osa" to run something else).
#
# Env overrides: NAMESPACE, JUMP_POD_LABEL, IN_CLUSTER_SERVER_URI,
#                OS_META_PATH, REMOTE_ROOT, SKIP_COPY, SKIP_BUNDLE,
#                CHECK_ONLY (1 = read-only: report expected vs created batches
#                using the already-staged project; nothing is copied or deleted),
#                PVC_ROOT, FORCE_RESTAGE (1 = restage even if rake is running),
#                JUMP_POD_RELEASE (Helm release label to select the pod),
#                RELOCK_ON_FAILURE (1 = last-resort full lockfile re-resolve),
#                SKIP_BATCH_RANGES (e.g. "6785-6912": never submit those batches),
#                OSA_SUBMIT_CONCURRENCY (parallel run_analysis calls, default 4),
#                OSA_CANARY (0 disables the per-measure-configuration canary that
#                aborts submission if >OSA_CANARY_MAX_FAILURE_FRACTION (0.2) of the
#                first finished datapoints of a new configuration fail),
#                OSA_CANARY_MIN_COMPLETED (20), OSA_CANARY_TIMEOUT_SECONDS (1800)

set -euo pipefail

# macOS has no `timeout`; use GNU `gtimeout` (brew install coreutils) when
# present and otherwise run the command without a timeout.
with_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
  else "$@"; fi
}

NAMESPACE="${NAMESPACE:-openstudio-server}"
JUMP_POD_LABEL="${JUMP_POD_LABEL:-jump-pod}"
IN_CLUSTER_SERVER_URI="${IN_CLUSTER_SERVER_URI:-http://web}"
OS_META_PATH="${OS_META_PATH:-/opt/openstudio/bin/openstudio_meta}"
# openstudio_meta forces this GEM_HOME internally; its gems must live here.
META_GEM_HOME="${META_GEM_HOME:-/opt/openstudio/gems}"
# Default to the NFS PVC (/mnt/openstudio) so the staged repo, log, PID lock and
# submit manifest survive pod eviction/recreation (/outputs is an emptyDir).
REMOTE_ROOT="${REMOTE_ROOT:-/mnt/openstudio/bem-to-surrogate}"
PVC_ROOT="${PVC_ROOT:-/mnt/openstudio}"
# REMOTE_ROOT is wiped on re-stage; it must be a strict descendant of the PVC so the
# wipe can't hit unrelated data and the sibling STATE_DIR stays on durable storage.
REMOTE_ROOT="${REMOTE_ROOT%/}"
case "$REMOTE_ROOT" in
  "${PVC_ROOT}"/?*) ;;
  *) echo "REMOTE_ROOT (${REMOTE_ROOT}) must be a subdirectory of ${PVC_ROOT}" >&2; exit 1 ;;
esac
case "$REMOTE_ROOT" in
  *..*|*[[:space:]\'\"]*) echo "REMOTE_ROOT contains unsupported characters" >&2; exit 1 ;;
esac
STATE_DIR="${REMOTE_ROOT}.state"   # survives the re-stage wipe of REMOTE_ROOT
FORCE_RESTAGE="${FORCE_RESTAGE:-0}" # 1 = restage even if a submission is still running
CHECK_ONLY="${CHECK_ONLY:-0}"      # 1 = only compare expected vs created batches
CHUNK_SIZE="${CHUNK_SIZE:-100m}"   # split size for the resilient copy
OSA_SUBMIT_CONCURRENCY="${OSA_SUBMIT_CONCURRENCY:-4}"
OSA_CANARY="${OSA_CANARY:-1}"
OSA_CANARY_MIN_COMPLETED="${OSA_CANARY_MIN_COMPLETED:-20}"
OSA_CANARY_MAX_FAILURE_FRACTION="${OSA_CANARY_MAX_FAILURE_FRACTION:-0.2}"
OSA_CANARY_TIMEOUT_SECONDS="${OSA_CANARY_TIMEOUT_SECONDS:-1800}"
MAX_RETRIES="${MAX_RETRIES:-6}"    # retries per chunk/command before giving up
SKIP_COPY="${SKIP_COPY:-0}"        # 1 = reuse project already staged in the pod
SKIP_BUNDLE="${SKIP_BUNDLE:-0}"    # 1 = skip bundle install (already done)
RELOCK_ON_FAILURE="${RELOCK_ON_FAILURE:-0}" # 1 = allow full Gemfile.lock re-resolve in pod as last resort
BUNDLE_FATAL_RC=86                 # in-pod exit code meaning "bundler failed deterministically"

# Retry a kubectl command a few times with backoff; the apiserver connection
# (same one port-forward uses) can drop mid-transfer, so treat that as
# transient rather than fatal. If RETRY_STOP_RC is set and the command exits
# with that code, the failure is permanent and is returned without retrying.
retry_kubectl() {
  local attempt=1
  local delay=5
  local rc
  while true; do
    rc=0
    "$@" || rc=$?
    (( rc == 0 )) && return 0
    if [[ -n "${RETRY_STOP_RC:-}" && "$rc" == "$RETRY_STOP_RC" ]]; then
      echo "Command failed permanently (exit ${rc}), not retrying: $*" >&2
      return "$rc"
    fi
    if (( attempt >= MAX_RETRIES )); then
      echo "Command failed after ${attempt} attempts: $*" >&2
      return 1
    fi
    echo "  (attempt ${attempt} failed, retrying in ${delay}s: $*)" >&2
    sleep "$delay"
    attempt=$(( attempt + 1 ))
    delay=$(( delay * 2 ))
  done
}

GEM_DIR="${1:?Usage: $0 /path/to/openstudio-bem-to-surrogate-gem [rake_task]}"
RAKE_TASK="${2:-execute_sequential}"

GEM_DIR="$(cd "$GEM_DIR" && pwd)"
CONFIG_FILE="${GEM_DIR}/configs.yml"
[[ -f "$CONFIG_FILE" ]] || { echo "configs.yml not found at ${CONFIG_FILE}" >&2; exit 1; }

# The batch definitions (parametric_space_Batch*.json / measure_space_Batch*.json)
# live in outputs/<project_name>/. _read_parametric_spaces globs that folder, so
# the project dir MUST be copied or the run silently falls back to the single
# default parametric_space.json instead of the full batch set.
PROJECT_NAME="$(awk '/^project_structure:/{f=1} f&&/^[[:space:]]+project_name:/{print $2; exit}' "$CONFIG_FILE" | tr -d '"'"'"'')"
[[ -n "$PROJECT_NAME" ]] || { echo "Could not read project_name from ${CONFIG_FILE}" >&2; exit 1; }
PROJECT_DIR="${GEM_DIR}/outputs/${PROJECT_NAME}"
[[ -d "$PROJECT_DIR" ]] || { echo "Project dir not found at ${PROJECT_DIR}" >&2; exit 1; }
BATCH_COUNT="$(find "$PROJECT_DIR" -maxdepth 1 -name 'parametric_space*.json' | wc -l | tr -d ' ')"
echo "=== Project '${PROJECT_NAME}': ${BATCH_COUNT} parametric_space batch file(s) ==="

get_jump_pod() {
  local pod="" attempt=1 delay=5 selector="app=${JUMP_POD_LABEL}" pods n
  [[ -n "${JUMP_POD_RELEASE:-}" ]] && selector="${selector},release=${JUMP_POD_RELEASE}"
  until [[ -n "$pod" ]]; do
    # Only Running pods: an evicted pod lingers in Error state and sorts first.
    pods="$(kubectl get pods -n "$NAMESPACE" -l "$selector" --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
    n="$(printf '%s\n' "$pods" | grep -c . || true)"
    if (( n > 1 )); then
      echo "Multiple running jump pods match '${selector}':" >&2
      printf '%s\n' "$pods" | sed 's/^/  /' >&2
      echo "Set JUMP_POD_RELEASE=<helm release> to disambiguate." >&2
      return 0
    fi
    pod="$(printf '%s' "$pods" | head -1)"
    [[ -n "$pod" ]] && break
    if (( attempt >= MAX_RETRIES )); then
      break
    fi
    echo "  (attempt ${attempt} failed to look up jump-pod, retrying in ${delay}s)" >&2
    sleep "$delay"
    attempt=$(( attempt + 1 ))
    delay=$(( delay * 2 ))
  done
  echo "$pod"
}
POD="$(get_jump_pod)"
if [[ -z "$POD" ]]; then
  echo "No running jump-pod found in namespace '${NAMESPACE}'." >&2
  echo "Enable it first: helm upgrade openstudio-server ./openstudio-server --set jump_pod.enabled=true ..." >&2
  exit 1
fi
echo "=== Using jump pod: ${POD} ==="

# Preflight: a stale NFS mount on web-background/rserve (e.g. after the NFS pod was
# preempted/restarted) makes every analysis complete with 0 datapoints, silently.
echo "=== Preflight: PriorityClasses and NFS clients ==="
# shellcheck source=lib/nfs_health.sh
source "$(dirname "$0")/lib/nfs_health.sh"
check_priority_classes || { echo "Recreate the PriorityClasses (helm upgrade) and rerun." >&2; exit 1; }
ensure_nfs_clients_healthy || { echo "Fix the NFS clients above before submitting." >&2; exit 1; }
nfs_ok_jump=0
kubectl exec -n "$NAMESPACE" "$POD" -- ls /mnt/openstudio >/dev/null 2>&1 && nfs_ok_jump=1
if [[ "$nfs_ok_jump" != 1 ]]; then
  echo "ERROR: jump pod ${POD} cannot access /mnt/openstudio (stale NFS?). Delete the pod to remount, then rerun." >&2
  exit 1
fi

# Preflight: confirm jump-pod can actually reach the web service over the
# cluster pod network *before* spending minutes packing/copying/bundling.
# On this infrastructure, pod-to-pod overlay connectivity between specific
# node pairs has been observed to silently black-hole (TCP connect times
# out, no error) even though the Service/Endpoints/DNS all look healthy and
# kubectl exec/cp into the pod works fine -- so a submission can run for
# hours writing "started" without a single analysis ever reaching the
# server. Fail fast and loud here instead of discovering that after the
# fact by noticing no new analyses in the web UI.
# Preflight: confirm jump-pod can actually reach the web service over the
# cluster pod network *before* spending minutes packing/copying/bundling.
# NOTE: extensive live testing (see docs/port-forward-and-jump-pod-troubleshooting.md) confirmed
# in-cluster pod-to-pod networking is consistently healthy -- the real
# risk here is the *local* kubectl exec call itself failing to establish
# through the cluster's known intermittent external API gateway. That
# gateway has been observed to be *bursty*: stretches of ~75-80% failure
# lasting roughly a minute or two, alternating with stretches back down
# to the ~15-25% baseline. A backoff that grows unbounded (e.g. up to
# 160s) samples too infrequently to reliably catch the end of a bad
# burst -- capping the delay and using more attempts instead gives more
# samples across the same wall-clock time, which matters more here than a
# long final wait.
echo "=== Preflight: checking jump-pod -> ${IN_CLUSTER_SERVER_URI} connectivity ==="
PREFLIGHT_OK=0
PREFLIGHT_DELAY=5
PREFLIGHT_MAX_DELAY=15
PREFLIGHT_MAX_ATTEMPTS=$(( MAX_RETRIES * 2 ))
for attempt in $(seq 1 "$PREFLIGHT_MAX_ATTEMPTS"); do
  # Guard against `set -e`: kubectl exec propagates curl's own exit code
  # (e.g. 28 on connection timeout) into this assignment, which would
  # otherwise abort the whole script on the very first failed attempt
  # instead of actually retrying -- "|| true" keeps that from happening.
  # Test a lightweight JSON API endpoint (/projects.json), NOT the root
  # path ("/"). The root path renders a full dashboard page and can take
  # 8+ seconds under load, far exceeding what looked like a generous
  # timeout and producing false "unreachable" failures even while the
  # server was actively, successfully serving other clients the entire
  # time (confirmed live: /projects.json succeeded in ~8s while "/" kept
  # timing out at both 5s and 10s). --max-time is generous (20s) since the
  # app can be genuinely this slow under real load, not just unreachable.
  CODE="$(kubectl exec -n "$NAMESPACE" "$POD" -- curl -s -o /dev/null --max-time 20 -w "%{http_code}" "${IN_CLUSTER_SERVER_URI}/projects.json" 2>/dev/null || true)"
  # curl prints "000" (not a real status line) when the connection itself
  # times out/refuses/fails -- that must NOT count as success, even though
  # it's numeric. Any genuine HTTP response (even a 4xx/5xx from the app)
  # proves the pod network path is open, which is all this check verifies.
  if [[ "$CODE" =~ ^[0-9]{3}$ ]] && [[ "$CODE" != "000" ]]; then
    PREFLIGHT_OK=1
    break
  fi
  if (( attempt >= PREFLIGHT_MAX_ATTEMPTS )); then
    break
  fi
  echo "  (attempt ${attempt}/${PREFLIGHT_MAX_ATTEMPTS} could not reach ${IN_CLUSTER_SERVER_URI} from ${POD}, got '${CODE:-<no response>}', retrying in ${PREFLIGHT_DELAY}s)" >&2
  sleep "$PREFLIGHT_DELAY"
  if (( PREFLIGHT_DELAY * 2 <= PREFLIGHT_MAX_DELAY )); then
    PREFLIGHT_DELAY=$(( PREFLIGHT_DELAY * 2 ))
  else
    PREFLIGHT_DELAY=$PREFLIGHT_MAX_DELAY
  fi
done
if [[ "$PREFLIGHT_OK" != "1" ]]; then
  cat >&2 <<EOF
FATAL: jump-pod (${POD}) could not reach ${IN_CLUSTER_SERVER_URI} in
${PREFLIGHT_MAX_ATTEMPTS} attempts. In-cluster pod-to-pod networking has
been confirmed reliable (see docs/port-forward-and-jump-pod-troubleshooting.md) -- this most likely
means the cluster's known intermittent external API gateway (the same
issue behind occasional kubectl/helm 502s) had an unusually long bad
streak covering every attempt above, not that the pod network is down.
That gateway has been observed to be bursty (stretches of ~75-80% failure
lasting roughly a minute or two, alternating with much better stretches).

Just try again -- a second run succeeding is expected and does not mean
anything was "fixed"; it just means this run's attempts didn't all land
in a bad window. If it fails this way many times in a row, that's worth
re-reporting, since it would suggest a longer/broader gateway outage than
previously observed.
EOF
  exit 1
fi
echo "  OK: jump-pod can reach ${IN_CLUSTER_SERVER_URI}"

RECONCILE_RB="$(dirname "$0")/jump_pod_reconcile.rb"
run_reconcile() {
  kubectl exec -i -n "$NAMESPACE" "$POD" -- ruby - "$1" "$IN_CLUSTER_SERVER_URI" "${REMOTE_ROOT}/outputs/${PROJECT_NAME}" "$PROJECT_NAME" < "$RECONCILE_RB"
}
if [[ "$CHECK_ONLY" == "1" ]]; then
  echo "=== CHECK_ONLY=1: expected vs created batches (read-only, using staged project) ==="
  retry_kubectl kubectl exec -n "$NAMESPACE" "$POD" -- test -d "${REMOTE_ROOT}/outputs/${PROJECT_NAME}" \
    || { echo "No staged project at ${REMOTE_ROOT}; run without CHECK_ONLY first" >&2; exit 1; }
  run_reconcile check
  exit $?
fi

LOCK_FILE="${REMOTE_ROOT}/${RAKE_TASK}.log.pid"
if [[ "$SKIP_COPY" == "1" ]]; then
  echo "=== SKIP_COPY=1: reusing project already staged at ${REMOTE_ROOT} ==="
  retry_kubectl kubectl exec -n "$NAMESPACE" "$POD" -- test -f "${REMOTE_ROOT}/Rakefile" \
    || { echo "No staged project at ${REMOTE_ROOT}; rerun without SKIP_COPY=1" >&2; exit 1; }
else

# Restaging wipes REMOTE_ROOT (including the running task's log and lock), so refuse
# if the rake task is still alive.
if [[ "$FORCE_RESTAGE" != "1" ]]; then
  LIVE_PID="$(retry_kubectl kubectl exec -n "$NAMESPACE" "$POD" -- bash -c '
    PID=$(cat "$1" 2>/dev/null); [ -n "$PID" ] && ps -p "$PID" -o pid= 2>/dev/null | grep -q . && echo "$PID"; true' _ "$LOCK_FILE" | tr -d ' \r')"
  if [[ -n "$LIVE_PID" ]]; then
    echo "rake ${RAKE_TASK} is still running in the pod (PID ${LIVE_PID}); restaging would wipe ${REMOTE_ROOT}." >&2
    echo "Use CHECK_ONLY=1 to inspect, SKIP_COPY=1 to reuse the stage, or FORCE_RESTAGE=1 to override." >&2
    exit 1
  fi
fi

REMOTE_TMP="/tmp/bem_to_surrogate_chunks"
echo "=== Preparing remote directories ==="
# Keep the submit manifest and already-submitted batch files across a re-stage
# so a rerun after eviction resumes instead of starting from zero. Merge-copy
# (never delete saved state first) and fail hard: the wipe below must not run
# unless the state is safely saved.
retry_kubectl kubectl exec -n "$NAMESPACE" "$POD" -- bash -c "
set -e
mkdir -p '${STATE_DIR}'
P='${REMOTE_ROOT}/outputs/${PROJECT_NAME}'
if [ -f \"\$P/osa_submit_manifest.jsonl\" ]; then
  cp -f \"\$P/osa_submit_manifest.jsonl\" '${STATE_DIR}/osa_submit_manifest.jsonl.tmp'
  mv -f '${STATE_DIR}/osa_submit_manifest.jsonl.tmp' '${STATE_DIR}/osa_submit_manifest.jsonl'
fi
if [ -d \"\$P/submitted\" ]; then
  mkdir -p '${STATE_DIR}/submitted'
  cp -a \"\$P/submitted/.\" '${STATE_DIR}/submitted/'
fi
" || { echo "Failed to save submit state to ${STATE_DIR}; not wiping ${REMOTE_ROOT}" >&2; exit 1; }
# rm can fail on NFS ".nfsXXXX" files held open by a still-running process from an
# interrupted earlier run; stop those first, then wipe.
kubectl exec -n "$NAMESPACE" "$POD" -- bash -c 'pkill -f "tar -xzf /tmp/bem_to_surrogate_chunks" 2>/dev/null; pkill -f "cat /tmp/bem_to_surrogate_chunks" 2>/dev/null; sleep 1; true' || true
retry_kubectl kubectl exec -n "$NAMESPACE" "$POD" -- rm -rf "$REMOTE_ROOT" "$REMOTE_TMP"
retry_kubectl kubectl exec -n "$NAMESPACE" "$POD" -- mkdir -p "$REMOTE_ROOT" "$REMOTE_TMP"

# Split a tarball into chunks and copy each with retry, so one dropped
# websocket only costs that chunk instead of the whole multi-GB transfer.
copy_tarball_to_pod() {
  local tarball="$1" label="$2"
  local chunk_dir num_chunks
  chunk_dir="$(mktemp -d -t bem_to_surrogate_chunks_XXXX)"
  split -b "$CHUNK_SIZE" "$tarball" "${chunk_dir}/${label}_"
  rm -f "$tarball"
  num_chunks="$(ls -1 "$chunk_dir" | wc -l | tr -d ' ')"
  echo "  -> ${label}: ${num_chunks} chunk(s)"
  local chunk name
  for chunk in "${chunk_dir}"/${label}_*; do
    name="$(basename "$chunk")"
    echo "     ${name}"
    retry_kubectl kubectl cp "$chunk" "${NAMESPACE}/${POD}:${REMOTE_TMP}/${name}"
  done
  rm -rf "$chunk_dir"
  retry_kubectl kubectl exec -n "$NAMESPACE" "$POD" -- bash -c \
    "cat ${REMOTE_TMP}/${label}_* > ${REMOTE_TMP}/${label}.tar.gz && tar -xzf ${REMOTE_TMP}/${label}.tar.gz -C '${REMOTE_ROOT}' && rm -f ${REMOTE_TMP}/${label}_* ${REMOTE_TMP}/${label}.tar.gz"
}

echo "=== Packing repo (excluding .bundle, outputs, spec/integration, tmp, sweep_results, SR1, notebook, .git) ==="
# COPYFILE_DISABLE stops macOS tar from emitting AppleDouble "._*" resource
# files, which otherwise litter the pod and confuse Dir globs.
REPO_TARBALL="$(mktemp -t bem_to_surrogate_XXXX).tar.gz"
COPYFILE_DISABLE=1 tar --no-xattrs -czf "$REPO_TARBALL" -C "$GEM_DIR" \
  --exclude='.bundle' --exclude='outputs' --exclude='spec/integration' \
  --exclude='.venv' --exclude='venv' --exclude='__pycache__' --exclude='*.pyc' \
  --exclude='*/tests/output' --exclude='*/tests/run' --exclude='node_modules' \
  --exclude='tmp' --exclude='sweep_results' --exclude='SR1' --exclude='notebook' \
  --exclude='.git' --exclude='.DS_Store' .
copy_tarball_to_pod "$REPO_TARBALL" repo

echo "=== Packing project dir outputs/${PROJECT_NAME} (${BATCH_COUNT} batch files) ==="
# Stale osa_workflow* artifacts from earlier runs are excluded; sequential mode
# regenerates each batch's OSA immediately before submitting it.
PROJ_TARBALL="$(mktemp -t bem_to_surrogate_proj_XXXX).tar.gz"
COPYFILE_DISABLE=1 tar --no-xattrs -czf "$PROJ_TARBALL" -C "$GEM_DIR" \
  --exclude='.DS_Store' --exclude='osa_workflow*' --exclude='osa_submit_manifest.jsonl' \
  "outputs/${PROJECT_NAME}"
copy_tarball_to_pod "$PROJ_TARBALL" proj

retry_kubectl kubectl exec -n "$NAMESPACE" "$POD" -- rm -rf "$REMOTE_TMP"
# Restore saved state into the fresh stage.
retry_kubectl kubectl exec -n "$NAMESPACE" "$POD" -- bash -c "
set -e
P='${REMOTE_ROOT}/outputs/${PROJECT_NAME}'
mkdir -p \"\$P\"
if [ -f '${STATE_DIR}/osa_submit_manifest.jsonl' ]; then
  cp -f '${STATE_DIR}/osa_submit_manifest.jsonl' \"\$P/\"
fi
if [ -d '${STATE_DIR}/submitted' ]; then
  mkdir -p \"\$P/submitted\"
  cp -a '${STATE_DIR}/submitted/.' \"\$P/submitted/\"
fi
"
fi

echo "=== Preparing project in pod (strip macOS cruft, git init, outputs dir) ==="
# The gemspec calls `git ls-files`, so a git repo must exist or the Rakefile
# load emits fatal errors. outputs/ is excluded from the tarball but required.
retry_kubectl kubectl exec -n "$NAMESPACE" "$POD" -- bash -lc "
set -e
cd '${REMOTE_ROOT}'
find . -name '._*' -delete 2>/dev/null || true
find . -name '.DS_Store' -delete 2>/dev/null || true
mkdir -p outputs
git config --global --add safe.directory '${REMOTE_ROOT}' 2>/dev/null || true
if [ ! -d .git ]; then git init -q && git add -A >/dev/null 2>&1 || true; fi
"

echo "=== Rewriting configs for the pod (server URI, paths, batch discovery) ==="
# Two configs matter:
#   1. the root configs.yml
#   2. outputs/<project>/configs.yml, the per-project config, which on a normal
#      macOS run holds absolute /Users/... paths and the localhost tunnel URL.
# The project config also needs measure_space_from_existing_project_folder=true
# so _read_parametric_spaces globs the project folder for all batch files
# instead of silently falling back to the single default parametric_space.json.
retry_kubectl kubectl exec -n "$NAMESPACE" "$POD" -- ruby -e "
require 'yaml'
root = '${REMOTE_ROOT}'
[
  File.join(root, 'configs.yml'),
  File.join(root, 'outputs', '${PROJECT_NAME}', 'configs.yml'),
].each do |path|
  next unless File.file?(path)
  cfg = YAML.load_file(path)
  et = cfg['external_tools'] ||= {}
  et['server_uri']   = '${IN_CLUSTER_SERVER_URI}'
  et['os_meta_path'] = '${OS_META_PATH}'
  et['ruby_path']    = nil
  if (ps = cfg['project_structure'])
    ps['dir_output']   = File.join(root, 'outputs')
    ps['dir_measures'] = File.join(root, 'lib', 'measures')
    ps['dir_weather']  = File.join(root, 'spec', 'files', 'weather')
    ps['dir_models']   = File.join(root, 'spec', 'files', 'models')
  end
  cfg['measure_space_from_existing_project_folder'] = true
  File.write(path, cfg.to_yaml)
  puts \"rewrote #{path}\"
end
"

echo "=== Verifying batch files landed in the pod ==="
POD_BATCHES="$(retry_kubectl kubectl exec -n "$NAMESPACE" "$POD" -- bash -c \
  "ls '${REMOTE_ROOT}/outputs/${PROJECT_NAME}'/parametric_space*.json 2>/dev/null | wc -l" | tr -d ' \r')"
echo "  -> ${POD_BATCHES} batch file(s) in pod (expected ${BATCH_COUNT})"
if [[ "$POD_BATCHES" != "$BATCH_COUNT" ]]; then
  echo "Batch file count mismatch; aborting rather than submitting a partial run." >&2
  exit 1
fi

# The pod image ships some of these gems at the wrong versions and is missing
# openstudio-extension entirely, so resolve the real Gemfile.lock instead.
if [[ "$SKIP_BUNDLE" == "1" ]]; then
  echo "=== SKIP_BUNDLE=1: skipping bundle install ==="
else
  # The copied Gemfile.lock is gitignored and generated on macOS, so it can be
  # stale or inconsistent for the pod (e.g. `reline (0.6.3)` listed without its
  # `io-console` dep -> exit 34 "revealed dependencies not in the API or the
  # lockfile"; or a locked version since yanked from rubygems). Retrying the
  # same install can never fix those, so inside the pod we loop: on failure,
  # pull the gem names bundler itself flags (`Running \`bundle update X\``,
  # "locked to X (ver)"), unlock only those with `bundle lock --update`, and
  # try again. All other locked versions stay pinned. RELOCK_ON_FAILURE=1
  # additionally allows a last-resort full re-resolve from the Gemfile.
  # A deterministic bundler failure exits ${BUNDLE_FATAL_RC} so retry_kubectl
  # doesn't waste retries on it; other failures (dropped exec) are retried.
  echo "=== bundle install in jump pod (this can take several minutes) ==="
  RETRY_STOP_RC="$BUNDLE_FATAL_RC" retry_kubectl kubectl exec -n "$NAMESPACE" "$POD" -- bash -lc "
cd '${REMOTE_ROOT}' || exit ${BUNDLE_FATAL_RC}
export BUNDLE_PATH='${REMOTE_ROOT}/.bundle' BUNDLE_WITHOUT=native_ext
log=\$(mktemp)
relocked_all=0
for pass in 1 2 3 4 5 6; do
  bundle install 2>&1 | tee \"\$log\"
  [ \"\${PIPESTATUS[0]}\" -eq 0 ] && { rm -f \"\$log\"; exit 0; }
  gems=\$( { grep -oE 'bundle update [A-Za-z0-9_.-]+' \"\$log\" | awk '{print \$3}'
             grep -oE 'locked to [A-Za-z0-9_.-]+ \\(' \"\$log\" | awk '{print \$3}'; } | sort -u | tr '\n' ' ')
  if [ -n \"\${gems// }\" ]; then
    echo \"=== bundler flagged stale lock entries: \${gems}-> bundle lock --update \${gems}===\"
    bundle lock --update \${gems} && continue
  fi
  if [ '${RELOCK_ON_FAILURE}' = 1 ] && [ \"\$relocked_all\" = 0 ] && [ -f Gemfile.lock ]; then
    echo '=== RELOCK_ON_FAILURE=1: re-resolving Gemfile.lock from scratch ==='
    mv Gemfile.lock Gemfile.lock.orig && relocked_all=1 && continue
  fi
  break
done
rm -f \"\$log\"
exit ${BUNDLE_FATAL_RC}
" || { echo "bundle install failed (see bundler output above; try RELOCK_ON_FAILURE=1)" >&2; exit 1; }

  # openstudio_meta hardcodes ENV['GEM_HOME'] = /opt/openstudio/gems (line 13),
  # which ships EMPTY in the server image, so its `require 'zip'` /
  # 'openstudio-analysis' / 'openstudio-aws' all fail. These must be installed
  # into that exact dir -- BUNDLE_PATH and GEM_HOME overrides cannot help.
  # openstudio-aws is pinned to 0.4.1 (not the gemspec's 0.7.1) because 0.7.1
  # pulls aws-sdk-core 2.2.37, which is broken on Ruby 3.2
  # ("tried to create Proc object without a block"). 0.4.1 pulls 2.11.632,
  # matching a known-working local PAT install.
  echo "=== Installing openstudio_meta CLI gems into /opt/openstudio/gems ==="
  retry_kubectl kubectl exec -n "$NAMESPACE" "$POD" -- bash -c "
set -e
export GEM_HOME=${META_GEM_HOME} GEM_PATH=${META_GEM_HOME}
install_if_missing() {
  if ! ruby -e \"gem '\$1', '\$2'\" >/dev/null 2>&1; then
    echo \"  installing \$1 \$2\"
    gem install \"\$1\" -v \"\$2\" --no-document --install-dir ${META_GEM_HOME} >/dev/null
  else
    echo \"  \$1 \$2 already present\"
  fi
}
install_if_missing rubyzip 2.3.2
install_if_missing openstudio-analysis 1.5.2
install_if_missing openstudio-aws 0.4.1
"

  echo "=== Verifying openstudio_meta can load its gems ==="
  retry_kubectl kubectl exec -n "$NAMESPACE" "$POD" -- bash -c \
    "GEM_HOME=${META_GEM_HOME} GEM_PATH=${META_GEM_HOME} ruby -e \"require 'zip'; require 'openstudio-analysis'; require 'openstudio-aws'; puts 'openstudio_meta gems OK'\"" \
    || { echo "openstudio_meta gem prerequisites are still broken" >&2; exit 1; }
fi

echo "=== Verifying Rakefile + configs load under bundler ==="
retry_kubectl kubectl exec -n "$NAMESPACE" "$POD" -- bash -lc \
  "cd '${REMOTE_ROOT}' && export BUNDLE_PATH='${REMOTE_ROOT}/.bundle' BUNDLE_WITHOUT=native_ext && bundle exec rake -T > /dev/null" \
  || { echo "Rakefile failed to load in pod" >&2; exit 1; }

# Optional: exclude batch ranges (e.g. SKIP_BATCH_RANGES="6785-6912 7000-7010") by
# moving their definitions to skipped/ so neither reconcile nor rake sees them.
if [[ -n "${SKIP_BATCH_RANGES:-}" ]]; then
  echo "=== Skipping batch ranges: ${SKIP_BATCH_RANGES} ==="
  [[ "$SKIP_BATCH_RANGES" =~ ^[0-9[:space:]-]+$ ]] || { echo "SKIP_BATCH_RANGES must look like '6785-6912 7000-7010'" >&2; exit 1; }
  kubectl exec -n "$NAMESPACE" "$POD" -- ruby -e '
    require "fileutils"; dir = ARGV.shift; ranges = ARGV.map { |r| a, b = r.split("-").map(&:to_i); (a..(b || a)) }
    FileUtils.mkdir_p(File.join(dir, "skipped"))
    n = 0
    Dir.glob(File.join(dir, "{parametric_space,measure_space}*Batch*.json")).each do |f|
      b = File.basename(f)[/Batch_?(\d+)/i, 1].to_i
      next unless ranges.any? { |r| r.cover?(b) }
      FileUtils.mv(f, File.join(dir, "skipped", File.basename(f))); n += 1
    end
    puts "moved #{n} batch definition files to skipped/"
  ' "${REMOTE_ROOT}/outputs/${PROJECT_NAME}" $SKIP_BATCH_RANGES
fi

# Resume support: delete empty stub analyses and hide batches the server already
# has, so the rake task only submits what is missing (no duplicates).
echo "=== Reconciling with server (skip completed batches, remove empty stubs) ==="
run_reconcile reconcile || { echo "FATAL: reconcile failed; refusing to submit (would risk duplicates)" >&2; exit 1; }

# Completion is decided by the server (reconcile above), not the manifest line count.
REMAINING="$(kubectl exec -n "$NAMESPACE" "$POD" -- bash -c 'ls "$1"/parametric_space*Batch*.json 2>/dev/null | wc -l' _ "${REMOTE_ROOT}/outputs/${PROJECT_NAME}" | tr -d ' \r')"
if [[ "$REMAINING" == "0" ]]; then
  echo "=== All ${BATCH_COUNT} batches already on the server — nothing to submit ==="
  exit 0
fi

LOG_FILE="${REMOTE_ROOT}/${RAKE_TASK}.log"
echo "=== Launching 'bundle exec rake ${RAKE_TASK}' detached in jump pod ==="
# NOTE: this step is deliberately NOT just `retry_kubectl kubectl exec ...`.
# Observed live: the remote command can genuinely succeed (it echoes
# "started" after backgrounding the rake process) but the *exec session
# itself* then dies on close with "websocket: close 1006 (abnormal
# closure)" -- a transport-layer failure on the way OUT, after the launch
# already happened. A naive retry_kubectl sees only the non-zero exit
# code and retries the whole launch command, which actually spawned a
# SECOND, duplicate `rake execute_sequential` process writing to the same
# log file (reproduced live in this session). Before every launch
# attempt -- including the first retry after a reported failure -- check
# whether the task is already running remotely, and skip launching again
# if so, so a false-failure retry can never create a duplicate.
LAUNCHED=0
LAUNCH_DELAY=5
for attempt in $(seq 1 "$MAX_RETRIES"); do
  # Measure 1 + 7: Check remote PID lock file (not just pgrep) and clean stale locks.
  LOCK_FILE="${LOG_FILE}.pid"
  LOCK_STATUS="$(kubectl exec -n "$NAMESPACE" "$POD" -- bash -c '
    LOCK="'"'${LOCK_FILE}'"'"
    if [ -f "$LOCK" ]; then
      PID=$(cat "$LOCK" 2>/dev/null)
      if [ -n "$PID" ] && ps -p "$PID" -o pid= 2>/dev/null | grep -q .; then
        echo "alive:$PID"
      else
        echo "stale:$PID"
        rm -f "$LOCK" 2>/dev/null || true
      fi
    else
      echo "none"
    fi
  ' 2>/dev/null || echo "none")"
  ALREADY_RUNNING=""
  if echo "$LOCK_STATUS" | grep -q '^alive:'; then
    ALREADY_RUNNING="$(echo "$LOCK_STATUS" | cut -d: -f2)"
    echo "  (rake ${RAKE_TASK} already running remotely (PID ${ALREADY_RUNNING}) -- not re-launching)"
    LAUNCHED=1
    break
  elif echo "$LOCK_STATUS" | grep -q '^stale:'; then
    echo "  (stale PID lock ${LOCK_FILE} cleaned; archiving old log and trying launch)"
    kubectl exec -n "$NAMESPACE" "$POD" -- bash -c 'mv -f "$1" "$1.$(date +%s).old" 2>/dev/null || true' _ "$LOG_FILE" || true
  fi
  if with_timeout 30 kubectl exec -n "$NAMESPACE" "$POD" -- bash -lc \
    "cd '${REMOTE_ROOT}' && export BUNDLE_PATH='${REMOTE_ROOT}/.bundle' BUNDLE_WITHOUT=native_ext OSA_SUBMIT_CONCURRENCY='${OSA_SUBMIT_CONCURRENCY}' OSA_CANARY='${OSA_CANARY}' OSA_CANARY_MIN_COMPLETED='${OSA_CANARY_MIN_COMPLETED}' OSA_CANARY_MAX_FAILURE_FRACTION='${OSA_CANARY_MAX_FAILURE_FRACTION}' OSA_CANARY_TIMEOUT_SECONDS='${OSA_CANARY_TIMEOUT_SECONDS}' && (setsid nohup bundle exec rake ${RAKE_TASK} > '${LOG_FILE}' 2>&1 < /dev/null & echo \$! > '${LOCK_FILE}') ; echo started" \
    2>&1 | tee /dev/stderr | grep -q "^started$"; then
    LAUNCHED=1
    break
  fi
  if (( attempt >= MAX_RETRIES )); then
    break
  fi
  # Measure 2: Log-evidence check — only retry if no submission keywords found.
  SUBMIT_IN_LOG="$(kubectl exec -n "$NAMESPACE" "$POD" -- bash -c 'grep -qEi \"analysis|osa|submit|project\" \"'"'${LOG_FILE}'"'\" 2>/dev/null && echo yes || echo no' 2>/dev/null || echo "no")"
  if [[ -z "$ALREADY_RUNNING" && "$SUBMIT_IN_LOG" == "yes" ]]; then
    echo "  (log shows prior submission activity for ${LOG_FILE}; not relaunching -- submissions already in flight)"
    LAUNCHED=1
    break
  fi
  # Measure 5: Faster capped retry sampling (not unbounded exponential).
  echo "  (attempt ${attempt}/${MAX_RETRIES} did not confirm launch, retrying in ${LAUNCH_DELAY}s -- will check for an already-running process first)" >&2
  sleep "$LAUNCH_DELAY"
  # Cap delay at 15s instead of unbounded growth, matching PREFLIGHT_MAX_DELAY.
  if (( LAUNCH_DELAY < 15 )); then
    LAUNCH_DELAY=$(( LAUNCH_DELAY + 5 ))
  fi
done
if [[ "$LAUNCHED" != "1" ]]; then
  echo "FATAL: could not confirm the rake task launched after ${MAX_RETRIES} attempts." >&2
  exit 1
fi

echo "=== Confirming the process is alive ==="
sleep 15
if retry_kubectl kubectl exec -n "$NAMESPACE" "$POD" -- pgrep -f "rake ${RAKE_TASK}" > /dev/null 2>&1; then
  # Measure 3 + 6: Count processes; kill duplicates if more than one.
  PROCESS_COUNT="$(kubectl exec -n "$NAMESPACE" "$POD" -- bash -c 'echo $(pgrep -f "rake '${RAKE_TASK}'" | wc -l | tr -d " ")' 2>/dev/null || echo "0")"
  if [[ -n "$PROCESS_COUNT" && "$PROCESS_COUNT" != "0" && "$PROCESS_COUNT" -gt 1 ]]; then
    echo "WARNING: ${PROCESS_COUNT} rake ${RAKE_TASK} processes detected. Removing duplicates (Measure 3 + 6)."
    # Kill all except the most recent (highest PID) or the one in the lock file.
    PRIMARY_PID="$(kubectl exec -n "$NAMESPACE" "$POD" -- bash -c 'cat "'"'${LOCK_FILE}'"'" 2>/dev/null | head -1' 2>/dev/null || echo "")"
    kubectl exec -n "$NAMESPACE" "$POD" -- bash -c '
      for pid in $(pgrep -f "rake '"'${RAKE_TASK}'"'"); do
        if [ -n "'"'${PRIMARY_PID}'"'" ] && [ "$pid" = "'"'${PRIMARY_PID}'"'" ]; then
          echo "keeping primary: $pid"
        else
          echo "killing duplicate: $pid"
          kill -TERM "$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
        fi
      done
    ' 2>/dev/null || true
  fi
  echo "OK: rake ${RAKE_TASK} is running in ${POD}."
else
  echo "WARNING: no rake process detected. It either finished instantly or crashed." >&2
  echo "--- last 40 log lines ---" >&2
  retry_kubectl kubectl exec -n "$NAMESPACE" "$POD" -- tail -40 "$LOG_FILE" >&2 || true
fi

# Second-layer verification: the rake process being alive only proves the
# ruby process started -- not that any batch has actually reached the
# server (see the preflight check above for why that distinction matters
# on this cluster). Poll the log for the first sign of an actual HTTP
# submission attempt so a completely-stuck run is caught within a couple
# of minutes instead of being discovered hours later via the empty web UI.
echo "=== Watching for first submission activity (up to 2 min) ==="
SUBMIT_SEEN=0
for i in $(seq 1 12); do
  sleep 10
  if retry_kubectl kubectl exec -n "$NAMESPACE" "$POD" -- bash -c \
    "grep -qEi 'analysis|osa|submit|project' '${LOG_FILE}' 2>/dev/null"; then
    SUBMIT_SEEN=1
    break
  fi
done
if [[ "$SUBMIT_SEEN" == "1" ]]; then
  echo "OK: log shows submission-related activity."
else
  echo "WARNING: no submission-related activity seen in ${LOG_FILE} after 2 min." >&2
  echo "The rake process may be alive but stuck before its first HTTP call" >&2
  echo "(e.g. still loading measures/weather files). Check manually:" >&2
  echo "  kubectl exec -n ${NAMESPACE} ${POD} -- tail -60 ${LOG_FILE}" >&2
fi

cat <<EOF

Submitted. The task keeps running detached inside pod '${POD}' even if this
shell, kubectl exec, or the port-forward tunnel disconnects.

Tail progress:
  kubectl exec -n ${NAMESPACE} ${POD} -- tail -f ${LOG_FILE}

Check if it's still running:
  kubectl exec -n ${NAMESPACE} ${POD} -- pgrep -fal rake

Verify expected vs created batches (non-zero exit + missing list if incomplete);
safe to rerun this script after a pod eviction -- it resumes where it stopped:
  CHECK_ONLY=1 $0 ${GEM_DIR} ${RAKE_TASK}

Pull results back to your machine when done:
  kubectl cp ${NAMESPACE}/${POD}:${REMOTE_ROOT}/outputs ${GEM_DIR}/outputs_from_jump_pod
EOF
