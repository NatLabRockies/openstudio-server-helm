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

The script copies a minimal project to `/mnt/openstudio/bem-to-surrogate` (the NFS PVC,
so the staged repo, log, PID lock and `osa_submit_manifest.jsonl` survive pod eviction;
override with `REMOTE_ROOT`), points the config at the in-cluster URL,
installs missing gems, preflights connectivity to `web`, and launches the rake task
detached (with a PID lock to avoid duplicate launches). It needs `kubectl`; on macOS
install `coreutils` for `gtimeout` (optional).

## Gems

The stock image ships an empty `GEM_HOME=/opt/openstudio/gems`. The submit script
installs `rubyzip`, `openstudio-analysis` and `openstudio-aws` there; to do it by hand,
copy `scripts/install_jump_pod_gems.sh` into the pod and run it. Installed gems do not
survive pod recreation; use a prebuilt image to avoid reinstalling.

## Resilience to pod eviction

- State lives on the PVC, not the `/outputs` emptyDir (now capped by
  `jump_pod.outputsSizeLimit`). `jump_pod.resources` sets `ephemeral-storage`
  requests/limits so the pod fails predictably instead of being the first eviction candidate.
- Re-running `submit_from_jump_pod.sh` after an eviction is safe: it preserves the manifest,
  deletes empty stub analyses (0 data points), and moves batches the server already has
  (matched by `Batch<N>` in the analysis name) into `outputs/<project>/submitted/`, so only
  missing batches are submitted.
- `CHECK_ONLY=1 scripts/submit_from_jump_pod.sh <gem> [task]` prints expected vs created batch
  counts and exits non-zero with `MISSING_BATCHES: ...` if any are missing or empty.
- Per-batch rescue and write-before/after manifest entries belong in the gem (`create_osa.rb`) and are not handled here.
