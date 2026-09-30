#!/usr/bin/env bash
# EMERGENCY, NARROW-USE workaround for a single template file, for when
# `helm upgrade` itself can't get through the cluster's intermittent
# external API gateway 502s (see docs/port-forward-and-jump-pod-troubleshooting.md) even with
# scripts/upgrade.sh's retries -- because `helm upgrade` diffs the ENTIRE
# release against live cluster state, so it makes many more sequential API
# calls than a single `kubectl apply`, and can fail nearly every time even
# though any individual call mostly succeeds.
#
# WHAT THIS DOES NOT DO, and why that matters:
#   - Does NOT update Helm's release history/state (no new revision is
#     recorded). `helm get values`/`helm diff`/`helm rollback` will not
#     know about this change until a REAL `helm upgrade` succeeds and
#     picks up the same template change.
#   - Does NOT run any Helm hooks (pre-install/pre-delete/etc). This
#     chart's pre-delete cleanup hook (templates/hooks/pre-delete-hook.yaml)
#     ONLY runs via `helm uninstall` -- bypassing Helm for day-to-day
#     install/upgrade is fine (this script only ever touches one
#     already-templated resource), but never use this pattern as a
#     substitute for `scripts/install.sh`/`scripts/uninstall.sh` for the
#     whole chart, or you lose that safety mechanism entirely.
#
# USE THIS FOR: a single, already-tested template file that needs to reach
# the cluster right now (e.g. a scheduling/affinity fix), when a full
# `helm upgrade` keeps failing outright due to the external gateway.
# FOLLOW UP: once the gateway is healthy again (or scripts/upgrade.sh's
# retries get through), run a real `scripts/upgrade.sh` with the same
# values so Helm's release history reflects reality.
#
# Usage:
#   scripts/apply_single_template.sh <template-path-relative-to-openstudio-server/> [-- <extra helm template args>]
# Example (the jump_pod affinity fix from this session):
#   scripts/apply_single_template.sh templates/jump_pod-deploy.yaml -- --set jump_pod.enabled=true -f openstack/values-openstack.yaml

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib/retry_cmd.sh

TEMPLATE_PATH="${1:?Usage: $0 <template-path> [-- <extra helm template args>]}"
shift
if [[ "${1:-}" == "--" ]]; then shift; fi

NAMESPACE="${NAMESPACE:-openstudio-server}"
RELEASE="${RELEASE:-openstudio-server}"

echo "=== Rendering ${TEMPLATE_PATH} only (release=${RELEASE}, namespace=${NAMESPACE}) ==="
RENDERED="$(mktemp -t apply_single_template_XXXX.yaml)"
helm template "$RELEASE" ./openstudio-server -n "$NAMESPACE" -s "$TEMPLATE_PATH" "$@" > "$RENDERED"
echo "--- rendered manifest ---"
cat "$RENDERED"
echo "-------------------------"

echo "=== Applying (retry-wrapped) ==="
retry_cmd kubectl apply -n "$NAMESPACE" -f "$RENDERED"
rm -f "$RENDERED"

cat <<EOF

REMINDER: this bypassed Helm's release tracking and hooks for this one
resource. Once scripts/upgrade.sh succeeds with the same values, Helm's
release history will reflect this change properly -- don't forget that
follow-up step.
EOF
