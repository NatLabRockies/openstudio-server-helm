# Jump pod: in-cluster analysis submission

The optional jump pod runs the full OpenStudio Server image inside the cluster so
long analysis submissions (e.g. `rake execute_sequential` from
`openstudio-bem-to-surrogate-gem`) talk to `http://web` directly instead of over a
`kubectl port-forward` tunnel that can drop. It is disabled by default; no extra
resources are created unless enabled.

## Enable

```bash
scripts/upgrade.sh -f openstack/values-openstack.yaml --set jump_pod.enabled=true
```

Relevant values (`openstudio-server/values.yaml`, `jump_pod.*`): `image` (must match
the web/worker image), `resources`, `command`, and `colocateWithWeb`. Set
`colocateWithWeb: true` to pin the pod to the same node as `web` (required pod
affinity, so the pod stays Pending until a web pod exists); use it when cross-node
pod traffic is unreliable (see [port-forward-and-jump-pod-troubleshooting.md](./port-forward-and-jump-pod-troubleshooting.md)).

## Submit

```bash
scripts/submit_from_jump_pod.sh /path/to/openstudio-bem-to-surrogate-gem [rake_task]
```

The script copies a minimal project to `/outputs/bem-to-surrogate` (an `emptyDir`, so
it is lost when the pod is recreated), points the config at the in-cluster URL,
installs missing gems, preflights connectivity to `web`, and launches the rake task
detached (with a PID lock to avoid duplicate launches). It needs `kubectl`; on macOS
install `coreutils` for `gtimeout` (optional).

## Gems

The stock image ships an empty `GEM_HOME=/opt/openstudio/gems`. The submit script
installs `rubyzip`, `openstudio-analysis` and `openstudio-aws` there; to do it by hand,
copy `scripts/install_jump_pod_gems.sh` into the pod and run it. Installed gems do not
survive pod recreation; use a prebuilt image to avoid reinstalling.
