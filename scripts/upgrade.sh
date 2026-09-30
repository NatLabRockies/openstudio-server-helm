#!/usr/bin/env bash
# Upgrades (or installs, if not already present) the openstudio-server release.
#
# NOTE: while the cluster's external API-facing gateway has intermittent
# 502s (see docs/port-forward-and-jump-pod-troubleshooting.md), `helm upgrade` is the single most
# exposed command to that flakiness -- it makes many sequential API calls
# (diffing every manifest against live state, reading release history from
# Secrets, etc.), and only one of those calls needs to land in a bad
# window for the whole command to fail. This wraps it in retries instead
# of treating the first 502 as fatal.
#
# --force-conflicts is included per openstack/README.md's troubleshooting
# guidance: once the web/worker HPAs have scaled at least once, Helm v4's
# server-side apply will otherwise fail with "conflict occurred while
# applying object ... with subresource \"scale\"" on essentially every
# routine upgrade against a live release, not just as a failure-recovery
# edge case.
#
# Usage:
#   scripts/upgrade.sh [-- <extra helm args>]
# Example (values file + local registry):
#   scripts/upgrade.sh -- -f openstack/values-openstack.yaml --set localRegistry.enabled=true

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib/retry_cmd.sh

# Optional leading "--" separates extra helm args; drop it before forwarding.
if [[ "${1:-}" == "--" ]]; then shift; fi

retry_cmd helm upgrade --install openstudio-server ./openstudio-server --force-conflicts --debug "$@"
