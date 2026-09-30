# Incident: `helm uninstall` blocked by failed `nfs-client-cleanup` pre-delete hook

**Date:** 2026-08-14
**Release:** `openstudio-server` (namespace `openstudio-server`), chart `openstudio-server-0.5.3`, revision 8
**Symptom:**

```
helm uninstall openstudio-server --namespace openstudio-server
...
Warning: watch ended with error ... stream ID 75; INTERNAL_ERROR ...
Error: resource Job/openstudio-server/openstudio-server-nfs-client-cleanup not ready. status: Failed, message: Job Failed. failed: 1/1
```

## Root cause

Two independent things were happening; only the second one actually blocked the uninstall.

1. **Cosmetic/noise:** the `stream ID 75; INTERNAL_ERROR` line is an HTTP/2 watch-stream
   warning between the Helm client and the apiserver (transient network/LB hiccup during a
   long-lived watch). It is not what failed the uninstall.
2. **Actual cause:** the `pre-delete` hook Job (`templates/hooks/pre-delete-hook.yaml`) had
   its image resolved, at install/upgrade time, to a broken, double-prefixed reference:

   ```
   pulp-dev.hpc.nlr.gov/pulp-container-aurora-179d/registry.k8s.io/kubectl:v1.34.9
   ```

   This came from the chart's `openstudio.imageWithRegistry` helper unconditionally
   prepending `global.images.registry`/`repositoryPrefix` (the openstack env's Pulp
   mirror) onto the template's hardcoded fallback default of
   `registry.k8s.io/kubectl:v1.34.9`, instead of recognizing that image was already
   fully-qualified with its own registry host. The mirror has no such nested path, so
   every pull attempt failed with `insufficient_scope` / `pull access denied`. With
   `backoffLimit: 1` and `activeDeadlineSeconds: 180`, the Job never got a container
   running, hit `DeadlineExceeded`, and was marked `Failed`. Helm refuses to proceed
   with an uninstall while a required hook Job is `Failed`.

   Confirmed via `kubectl describe`/events and `helm get values`:
   ```
   Failed to pull ... registry.k8s.io/kubectl:v1.34.9": pull access denied ... insufficient_scope
   Warning DeadlineExceeded job/openstudio-server-nfs-client-cleanup Job was active longer than specified deadline
   ```

3. **How it got baked into the release:** git history on `openstack_stable` shows this
   exact class of bug happened once already:
   - `6fd91c7` (Aug 10) switched the pre-delete/prepull utility image to
     `registry.k8s.io/kubectl:v1.34.9`, not realizing it's **distroless** (no `/bin/sh`)
     while the hook command is a `/bin/sh -c` wrapper.
   - `3386a2f` (same day, later) reverted the `values.yaml` **default** back to
     `bitnami/kubectl:latest` (shell-capable) after seeing this fail on the live prepull
     DaemonSet.
   - The currently-running release (installed 2026-08-13 23:58) was rendered at a point
     where `values.yaml`/overrides still resolved to the broken `registry.k8s.io` path,
     and using a version of `imageWithRegistry` that did not yet have the "skip
     already-qualified image" bypass added later in `831a8b8`. Fixes to templates/values
     on the branch do **not** retroactively fix an already-installed release's stored
     manifest — you have to `helm upgrade` for the fix to take effect.

## Short-term fix applied

See "Actions taken" section appended below by the follow-up work, or `helm history` /
`kubectl get events -n openstudio-server` for the live record.

## Future fixes (tracked, not yet implemented)

1. **Remove the hardcoded template-level fallback image** in
   `templates/hooks/pre-delete-hook.yaml` (and the prepull DaemonSet template). The
   template's `default "registry.k8s.io/kubectl:v1.34.9" (get $preDeleteHook "image")`
   duplicates and can drift from the `values.yaml` default (`bitnami/kubectl:latest`).
   There should be exactly one source of truth for this image; the template should just
   read `hooks.preDeleteCleanup.image` and fail render (or use the values.yaml default
   directly) rather than embed its own competing literal.
2. **Never reference `registry.k8s.io/kubectl` for hook/DaemonSet containers that use
   `/bin/sh -c` wrappers** — it's distroless and has no shell. Add a comment + chart
   lint rule enforcing "hook/prepull utility image must contain kubectl AND a shell."
   This mistake has now been made and fixed once already (`6fd91c7` → `3386a2f`); a
   stray hardcoded fallback let it resurface for any release rendered before the
   revert landed.
3. **Add a CI check** (extend `scripts/install-dry-run.sh`) that resolves every
   hardcoded utility image (`kubectl`, `busybox`, `pause`, etc.) through
   `openstudio.imageWithRegistry` for each provider profile (openstack, aws) and
   verifies the resulting reference is actually pullable (e.g. `skopeo inspect` or
   `crane manifest` against the target mirror) before merge — so a broken mirror path
   fails CI, not `helm uninstall` in production.
4. **Make hook Job failures fail fast and visible**, not silently blocking for the
   full deadline: consider a short `activeDeadlineSeconds` plus an image-pull
   pre-check/initContainer, and alerting on `ImagePullBackOff`/`DeadlineExceeded`
   events for hook Jobs so an operator notices before attempting `helm uninstall`.
5. **Add a chart golden-file/unit test** asserting the final resolved value of every
   hardcoded utility image for each provider profile, so a regression in
   `imageWithRegistry` (like the pre-`831a8b8` double-prefixing bug) is caught at
   render time via `helm template`, not discovered during a production uninstall.
6. **Document release/template drift explicitly** in the runbook: after any hook-image
   fix lands on a branch, run `helm upgrade` (even a no-op values bump) against
   long-lived environments before relying on `helm uninstall` working — "fixed on
   `openstack_stable`" does not mean "fixed in the currently running release."

---

## Follow-up (2026-08-15): two more uninstall bugs found in scratch testing

The 2026-08-14 fixes were verified on a scratch namespace (`oss-uninstall-test`) with
lean values; the test cycle surfaced two further bugs. Both are fixed and verified —
a full install → uninstall → uninstall cycle now exits 0 in ~1m36s with zero leftovers.

### Bug A — hook SA/Role/RoleBinding deleted by the first uninstall

**Symptom:** `helm uninstall` #2 (run against the release record left by a partially
failed uninstall #1) hung for the full 5m timeout:

```
hook Job re-created, but pod never ran:
  serviceaccount "oss-test-nfs-disconnect" not found
  Job Failed. failed: 0/1
```

**Root cause:** the hook's ServiceAccount/Role/RoleBinding were **regular** release
resources (no `helm.sh/hook` annotation). Uninstall #1 deleted them along with
everything else; uninstall #2 re-rendered the hook Job from the stored manifest but
the pod couldn't start without its SA → `Job Failed` → helm aborts ("a required hook
is pending/failed").

**Fix (`templates/service-account/nfs-disconnect-sa.yaml`):** annotated the SA, Role,
RoleBinding, and new ClusterRole/ClusterRoleBinding with:

```
helm.sh/hook: pre-delete
helm.sh/hook-weight: "1"
helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded,hook-failed
```

Hook resources are recreated fresh before every hook run (and the old ones deleted by
`before-hook-creation`), so even a re-uninstall against a half-deleted release gets a
valid identity. The Role also gained `jobs` and `horizontalpodautoscalers` verbs to
match what the hook now deletes.

### Bug B — chart PriorityClasses/StorageClass survived uninstall

**Symptom:** after a nominally successful uninstall (helm exit 0, all workloads gone),
`helm status` still showed `STATUS: uninstalling` / `Deletion in progress (or silently
failed)` and the release record lingered; the only resources left were the
PriorityClasses `high-priority` and `low-priority` (the latter is `globalDefault`).
Manual `kubectl delete priorityclass ...` succeeded instantly.

**Root cause:** helm deletes cluster-scoped resources by watching the apiserver and
relaying until the object is gone. The cluster's watch streams are flaky (repeated
`unable to decode an event from the watch stream ... INTERNAL_ERROR; received from
peer` during installs and uninstalls); when the watch drops, helm's relay never
completes and the object survives, leaving the release stuck.

**Fix (`templates/hooks/pre-delete-hook.yaml` + ClusterRole/ClusterRoleBinding in
`nfs-disconnect-sa.yaml`):** the hook now deletes these deterministically with one-shot
`kubectl delete ... --ignore-not-found=true` calls, backed by a hook-scoped
ClusterRole (`{{ .Release.Name }}-nfs-disconnect-cluster`) granting
`priorityclasses`/`storageclasses` delete/list/get. One-shot deletes don't depend on
watch-stream health.

### Verification (scratch release `oss-test`, ns `oss-uninstall-test`)

```
install:   helm install ... --wait            STATUS deployed (all pods Running)
uninstall: helm uninstall ... --debug         HELM EXIT=0, 1m35.82s
            - hook: HPAs → workloads → authoritative pod drain → force-delete →
              NFS settle → PriorityClasses/StorageClass deleted
            - helm delete phase: every resource "not found" (hook already removed)
            - release record finalized (status → "release: not found")
2nd run:    helm uninstall (same release)     exit 1 instantly: "release: not found"
Final:      no pods/PVCs/PVs/SC/PC/CRB/SVC; ns deleted; only expected residual was
            the NFS PV object (deleted per runbook Step 3)
```

The release-label prerequisite is also committed: every workload/HPA the chart creates
carries `release: {{ .Release.Name }}` in `metadata.labels`, which is how the hook
selects exactly this release's resources (and nothing else) during the drain.

## Revised approach (2026-08-28): eliminate blocking wait, unconditional exit

Changes:
- `pre-delete-hook.yaml`: removed `kubectl wait --for=delete` entirely; added `before-hook-creation` to delete-policy; required deletes are retried with backoff and the hook fails only if workloads could not be deleted after retries (no blocking wait on remaining pods).
- `worker-deploy.yaml`: eliminated `/opt/openstudio/server/bin/kill.worker` reference from `preStop`; all commands use `timeout` + `|| true` locally only.
- Rationale: the synchronous `wait` against pods in `Terminating` (D-state hang from dead NFS) was the deadlock; removing it prevents the hang. Force-delete runs immediately; hook completes quickly.

Tracked future fixes #1-#6 above remain open; item on deleting `nfs-pvc` from the hook
while the provisioner is still up is still the plan for eliminating the known NFS PV
residual.
