#!/usr/bin/env bash
# Shared retry helper for helm/kubectl commands, for use while the cluster's
# external API-facing gateway has intermittent 502s (see
# docs/port-forward-and-jump-pod-troubleshooting.md). Retries a command a few times with backoff when
# its output shows the known transient-failure signature, instead of
# treating the first 502 as fatal.
#
# Usage: source this file, then:
#   retry_cmd <command> [args...]

RETRY_MAX_ATTEMPTS="${RETRY_MAX_ATTEMPTS:-6}"
RETRY_BASE_DELAY="${RETRY_BASE_DELAY:-5}"

retry_cmd() {
  local attempt=1
  local delay="$RETRY_BASE_DELAY"
  local out status
  while true; do
    # NOTE: must NOT write straight to `out=$(... )` here. Under `set -e`
    # (as used by callers like scripts/upgrade.sh), a plain assignment's
    # exit status equals the wrapped command's exit status, and since this
    # statement isn't part of an if/while test or a &&/|| list, a nonzero
    # status trips `set -e` immediately -- before `status=$?` or any of the
    # retry/backoff logic below ever runs. The `|| status=$?` form keeps the
    # assignment itself always succeeding so -e doesn't fire here.
    out="$("$@" 2>&1)" && status=0 || status=$?
    echo "$out"
    if [[ $status -eq 0 ]] && ! echo "$out" | grep -q "502 Bad Gateway"; then
      return 0
    fi
    # Only transient gateway/transport errors are retried; anything else
    # (bad flags, RBAC, chart errors) fails immediately.
    if ! echo "$out" | grep -qE "502 Bad Gateway|503 Service Unavailable|504 Gateway Time-?out|connection reset by peer|TLS handshake timeout|unexpected EOF"; then
      return "$status"
    fi
    if (( attempt >= RETRY_MAX_ATTEMPTS )); then
      echo "FAILED after ${attempt} attempts (giving up): $*" >&2
      return 1
    fi
    echo "  (attempt ${attempt}/${RETRY_MAX_ATTEMPTS} hit a transient failure -- likely the known intermittent external API 502, see docs/port-forward-and-jump-pod-troubleshooting.md -- retrying in ${delay}s)" >&2
    sleep "$delay"
    attempt=$(( attempt + 1 ))
    delay=$(( delay * 2 ))
  done
}
