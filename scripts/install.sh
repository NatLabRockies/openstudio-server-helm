#!/usr/bin/env bash
# Installs the openstudio-server release.
#
# NOTE: while the cluster's external API-facing gateway has intermittent
# 502s (see docs/port-forward-and-jump-pod-troubleshooting.md), a plain `helm install` can fail
# outright even though the cluster itself is healthy -- it makes many
# sequential API calls, and only one needs to land in a bad window. This
# wraps the same helm command in a retry loop instead of treating the
# first 502 as fatal.
#
# Usage:
#   scripts/install.sh [-- <extra helm args>]
# Example (values file + local registry):
#   scripts/install.sh -- -f openstack/values-openstack.yaml --set localRegistry.enabled=true

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib/retry_cmd.sh

# Optional leading "--" separates extra helm args; drop it before forwarding.
if [[ "${1:-}" == "--" ]]; then shift; fi

retry_cmd helm install openstudio-server --debug ./openstudio-server "$@"
