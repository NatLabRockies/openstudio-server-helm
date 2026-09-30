# Port-forward and jump pod troubleshooting

Lessons learned from diagnosing flaky `kubectl port-forward` sessions and a jump pod that silently submitted nothing.

## Stale port-forward holding the local port

Lens starts `kubectl --kubeconfig <tmp> port-forward ...`, so the literal string `kubectl port-forward` never appears in its command line. A stale Lens tunnel can look `Active` while forwarding nothing (`curl` returns `HTTP 000`) and cause `address already in use`.

- Check first: `lsof -i :61570`
- `scripts/port_forward_kubectl.sh` clears leftovers with `pkill -f "kubectl.*port-forward.*PORT:PORT"`, which matches Lens-launched processes too.

## Intermittent 502 (Bad Gateway) from the Kubernetes API endpoint

If the API endpoint is fronted by a proxy (e.g. Azimuth/OpenStack), it may return 502 for roughly 20-25% of calls, including plain `kubectl get pods`.

- It is not a missing WebSocket/SPDY `Upgrade` header: if it were, every port-forward would fail. `kubectl port-forward` starts with ordinary REST calls that hit the same 502s.
- Nothing in this chart can fix it; ask the cluster operator to check the apiserver replicas, the proxy's upstream pool, and its `proxy_*_timeout` / `proxy_next_upstream` settings.
- Mitigation: retry. Scripts use `scripts/lib/retry_cmd.sh`, and the pre-delete hook retries with exponential backoff. Long `helm upgrade` runs make many API calls, so they fail more often; `scripts/upgrade.sh` is the retry-aware path.
- Do not bypass the pre-delete hook with `--no-hooks` long term: it force-deletes pods stuck on a dead NFS mount and removes PriorityClasses/StorageClass that Helm leaves behind.

## Jump pod cannot reach `web`

`jump-pod` can be `Running` and accept `kubectl exec` while pod-to-pod traffic to `web` times out, for example when overlay networking between specific nodes is broken. Other pods (workers) can show the same symptom.

- Verify from inside the pod: `kubectl exec deploy/jump-pod -- curl -m 5 -s -o /dev/null -w '%{http_code}' http://web/`
- Also test `web`'s pod IP directly. If that fails too, suspect the node's CNI (calico) and not the Service.
- `scripts/submit_from_jump_pod.sh` runs this connectivity preflight so it fails fast and does not report success just because the `rake` process is alive.
- The jump pod uses the same node-group affinity as the other web-tier workloads.
