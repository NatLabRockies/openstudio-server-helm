# Runbook: Force-Cleaning a Half-Uninstalled OpenStudio Server Release

Applies when `helm uninstall openstudio-server -n openstudio-server` leaves artifacts
behind: `Terminating` pods, a `Terminating` PVC, a leftover PV, or a stuck namespace.
Companion writeup: `helm-uninstall-nfs-cleanup-hook-incident.md` (the 2026-08-14 incident).

## Why uninstall can leave things behind

1. **Dead-NFS D-state hang (most common).** If the `nfs-server-provisioner` subchart is
   deleted while client pods (rserve/web/web-background) are still mounted on `nfs-pvc`,
   client processes stuck in I/O go into D-state (uninterruptible sleep). kubelet cannot
   kill them: `describe pod` shows `FailedKillPod ... DeadlineExceeded ... context
   deadline exceeded` retried forever. The pod stays `Terminating` indefinitely.
2. **Hook masked the wait.** The pre-delete hook used to swallow `kubectl wait` failures
   with `|| true`, so helm proceeded while pods were still `Terminating`.
3. **Failed hook Job blocks the next uninstall.** With only `hook-succeeded` in
   `hook-delete-policy`, a failed hook Job lingers and every subsequent `helm uninstall`
   fails until it is deleted by hand. (Fixed: policy now includes `hook-failed`.)
4. **PVC/PV protection finalizers.** `nfs-pvc` carries `kubernetes.io/pvc-protection`
   until no pod references it; the PV (reclaim `Delete`) cannot finalize while the PVC is
   pinned. After the PVC goes, the PV deletion needs the NFS provisioner — which helm
   already deleted — so the PV object can remain `Released`/`Terminating`.
5. **Hook RBAC deleted by the first uninstall (2026-08-15 Bug A).** The hook's
   SA/Role/RoleBinding used to be *regular* release resources. The first uninstall
   deletes them, so a second `helm uninstall` against a stuck release re-renders the
   hook Job but its pod can't start (`serviceaccount "<release>-nfs-disconnect"
   not found`) → Job Failed → helm waits the full timeout. (Fixed: SA/Role/RoleBinding
   + ClusterRole/ClusterRoleBinding are now `pre-delete` hook resources with
   `before-hook-creation`, so every uninstall recreates them fresh.)
6. **Cluster-scoped resources survive helm's delete (2026-08-15 Bug B).** The chart's
   PriorityClasses (`high-priority`, `low-priority` — the latter is `globalDefault`)
   and the `ssd` StorageClass could survive uninstall when the apiserver's watch
   streams hiccup (repeated `unable to decode an event from the watch stream ...
   INTERNAL_ERROR`), leaving the release stuck `uninstalling` with only those
   remaining. (Fixed: the hook now deletes them explicitly with `--ignore-not-found`.)

## Step 0 — Confirm the release state

```bash
helm status openstudio-server -n openstudio-server          # "release: not found" = helm finished, leftovers remain
kubectl get pods,pvc -n openstudio-server -o wide
kubectl get job -n openstudio-server                        # lingering Failed hook Job?
kubectl get ns openstudio-server -o jsonpath='{.status.phase}'
kubectl get events -n openstudio-server --sort-by=.lastTimestamp | tail -30   # FailedKillPod = D-state
```

## Step 1 — Delete any lingering failed hook Job

```bash
kubectl delete job nfs-client-cleanup -n openstudio-server --ignore-not-found=true
```

A Failed hook Job from a previous attempt blocks every subsequent `helm uninstall`
("a required hook is pending/failed"). Removing it unblocks retries.

## Step 2 — Force-delete stuck pods

For pods stuck in `Terminating` (check `kubectl get pod -n openstudio-server`):

```bash
kubectl delete pod -n openstudio-server <pod-a> <pod-b> <pod-c> --force --grace-period=0
```

Or by label (dangerous — also matches anything else with the release label):

```bash
kubectl delete pod -n openstudio-server -l release=openstudio-server --force --grace-period=0
```

> **Note — leaked sandbox:** if the container process is in D-state on a dead NFS mount,
> force-delete removes the API object (which unblocks the PVC/PV chain) but the container
> sandbox stays on the node until containerd/kubelet recover. A node reboot (or containerd
> restart + NFS unmount) is the only way to fully reclaim the leaked resources. Schedule
> it outside the maintenance window if the node hosts nothing else.

## Step 3 — Let the PVC/PV chain finalize

After the pods are gone, `nfs-pvc` should drop its `kubernetes.io/pvc-protection`
finalizer and be deleted; the PV (reclaim `Delete`) then releases. Watch it:

```bash
kubectl get pvc -n openstudio-server
kubectl get pv | grep -E "openstudio|nfs"
```

If the PVC is still `Terminating` with the finalizer (rare — means something still
references it):

```bash
kubectl patch pvc nfs-pvc -n openstudio-server -p '{"metadata":{"finalizers":[]}}' --type=merge
```

If the PV is `Released`/`Terminating` and never disappears (the NFS provisioner that
deletes the backing store was deleted by the same uninstall), delete the PV object.
**Confirm with the user first** — this is the chart's NFS data volume:

```bash
kubectl delete pv pvc-e22e16f7-15a0-4742-afac-77f00e9d3618 --ignore-not-found=true
# if it refuses (finalizer), force:
kubectl patch pv pvc-e22e16f7-15a0-4742-afac-77f00e9d3618 -p '{"metadata":{"finalizers":[]}}' --type=merge
kubectl delete pv pvc-e22e16f7-15a0-4742-afac-77f00e9d3618
```

## Step 4 — Namespace stuck in Terminating

If the namespace itself is stuck (its finalizers can't run because objects inside can't
finalize), finish Steps 2-3 first; the namespace usually completes on its own. Only if it
stays stuck:

```bash
kubectl get ns openstudio-server -o json | grep -A5 finalizers
kubectl patch ns openstudio-server -p '{"metadata":{"finalizers":[]}}' --type=merge   # last resort — confirm with user
```

## Step 5 — Verify clean

```bash
kubectl get all,pods,pvc,pv,jobs -n openstudio-server
kubectl get ns openstudio-server
```

Expected: no pods/PVCs; PV either gone or a single documented leftover removed in Step 3;
namespace `Active` and ready for a fresh `helm install`.

## Preventive behavior (current chart)

Since commit `49ce802` + the pre-delete hook rework + the 2026-08-15 hook-resource
fixes, the hook:

- selects every workload by `release=<release>` metadata label (the label is set on
  all Deployments/StatefulSets/HPAs/Jobs the chart creates — a prerequisite for
  reliable selection, missing in the first iteration)
- deletes HPAs first (so no autoscaler races the drain), then client
  Deployments/StatefulSets/Jobs (excluding the NFS provisioner)
- retries each required delete with backoff (transient API 502s), force-deletes
  remaining pods immediately, and fails the hook if workloads could not be deleted
  after retries. It does **not** block on `kubectl wait` for pod termination (that wait
  hung on pods stuck `Terminating` in D-state). The NFS provisioner stays up until the
  hook returns, so client mounts never hit a dead server
- deletes the chart's PriorityClasses and `ssd` StorageClass deterministically
  (helm's own cluster-scoped delete can leave them behind on a watch-stream hiccup)
- runs under hook-resource RBAC (SA/Role/RoleBinding + ClusterRole/ClusterRoleBinding
  are `pre-delete` hooks recreated before every run — so a second uninstall works even
  after a first one already deleted them)
- cleans up its own Job on success or failure (`hook-succeeded,hook-failed`)

Known residual: the NFS PV object can still linger after a clean uninstall because the
provisioner that deletes the backing store is removed by the same release. The PV is a
pure API object at that point (backing data is deleted with the provisioner's own
volume) — delete it with Step 3. Flagged as a tracked future fix (delete `nfs-pvc` from
the hook while the provisioner is still up).
