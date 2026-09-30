#!/usr/bin/env bash
# When you want to test the template rendering, but not actually install anything, you can use
#
# NOTE: dry-run still round-trips through the API server for validation, so
# it can also hit the intermittent external gateway 502s (see
# docs/port-forward-and-jump-pod-troubleshooting.md) -- retried the same way as install.sh.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib/retry_cmd.sh

# Optional leading "--" separates extra helm args; drop it before forwarding.
if [[ "${1:-}" == "--" ]]; then shift; fi

retry_cmd helm install openstudio-server --debug --dry-run ./openstudio-server "$@"
