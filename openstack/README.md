# OpenStack

Minimal notes for installing this chart on an already-existing OpenStack
Kubernetes cluster (e.g. one provisioned by [Azimuth](https://github.com/stackhpc/azimuth)).
This directory intentionally does not contain any tooling to create the
Kubernetes cluster itself (no Terraform/Kubespray/etc.) — use Azimuth (or
your own provisioning method) for that, then point `helm install` at the
resulting cluster.

## Prerequisites

- An existing Kubernetes cluster on OpenStack with the
  [Cinder CSI driver](https://github.com/kubernetes/cloud-provider-openstack/blob/master/docs/cinder-csi-plugin/using-cinder-csi-plugin.md)
  installed (this is what Azimuth-provisioned clusters ship by default).
- Node scheduling: `values-openstack.yaml` sets `node_group.label_key` to
  Azimuth's native Cluster API node-group label
  (`capi.stackhpc.com/node-group: web|worker`), so no manual node labeling
  is needed on Azimuth. On a different OpenStack cluster without that
  label, either label nodes `nodegroup=web-group` / `nodegroup=worker-group`
  yourself, or override `node_group.*` to match your cluster's own scheme
  (see `openstudio-server/values.yaml` for the full set of options).
- **The `nfs-server-provisioner` subchart is a separate vendored
  dependency and does NOT read `node_group.*`** — it has its own hardcoded
  default affinity. `values-openstack.yaml` overrides
  `nfs-server-provisioner.affinity` directly; if you change your node-group
  label scheme, update that override too or this pod will never schedule.

## Install

```bash
helm install openstudio-server ./openstudio-server -f openstack/values-openstack.yaml -n openstudio-server
```

See [`values-openstack.yaml`](./values-openstack.yaml) for the values this
sets, and the top-level [README](../README.md) for general chart install
instructions.

## Terraform proxy VM workaround

For the Azimuth/OpenStack environment described in the handoff, the chart's
`load_balancer` path is not reliable. A working Terraform-based workaround is
provided in [`terraform-proxy-vm/`](./terraform-proxy-vm/README.md): it
creates the proxy VM, security group, floating IP, and nginx config while
routing to the stable Kubernetes `NodePort` upstream rather than the unstable
Octavia VIP path. This is the recommended path until the platform-level
Octavia/LB issue is fixed.

The proxy VM's nginx upstream is the `web` Service NodePort on the node IPs
(default `32105`, see `nodeport_port` in `terraform-proxy-vm`), so your values
file **must** set `web_svc.type: NodePort` and `web_svc.nodePorts.http: 32105`
(already in `values-openstack.yaml.template`). The chart's default Service type
is ClusterIP; if a values file lacks this, an upgrade silently drops the
NodePort and the proxy returns `502 Bad Gateway`.

## Troubleshooting

- **Proxy VM returns `504 Gateway Time-out`**: nginx's default
  `proxy_read_timeout` is 60s. Under heavy load (thousands of workers hitting
  the single web pod) pages like `/` and `/projects.json` can take >60s. The
  proxy template now sets 600s timeouts; on an existing VM add
  `proxy_read_timeout 600s; proxy_send_timeout 600s;` to the `location /`
  block in `/etc/nginx/conf.d/proxy.conf` and `sudo systemctl reload nginx`
  (this patch only addresses the 504s; the template also sets
  `client_max_body_size 0` so large analysis uploads aren't rejected — add it
  too if you need that, and monitor the proxy VM's disk since nginx buffers
  request bodies there).
  SSH in as `cloud@<floating-ip>` (the default user on the Aurora Rocky image,
  not `rocky`) with the private key for the VM's `keypair_name`.
  If it is still slow, reduce load: raise the web pod's CPU/memory requests
  in `values-openstack.yaml` (or lower `worker-hpa` maxReplicas).
- **Proxy VM returns `502 Bad Gateway` after a `helm upgrade`, but the web pod
  is Running**: check `kubectl get svc web -n openstudio-server`. If it is
  `ClusterIP`, your values file is missing `web_svc.type: NodePort` and
  `web_svc.nodePorts.http` (match the proxy's `nodeport_port`, default `32105`).
  Add them (copy from `values-openstack.yaml.template`) and re-run the upgrade
  with `-n openstudio-server`.
- **`StorageClass "ssd" ... exists and cannot be imported into the current
  release: invalid ownership metadata`**: a `ssd` StorageClass from a
  previous/different release or namespace is still on the cluster. If
  nothing currently uses it (`kubectl get pvc -A -o
  jsonpath='{range .items[?(@.spec.storageClassName=="ssd")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}'`),
  delete it (`kubectl delete storageclass ssd`) and re-run install — Helm
  will recreate it with the correct ownership.
- **`StorageClass ... reclaimPolicy: Forbidden` / `volumeBindingMode:
  ... field is immutable`**: same root cause as above — `reclaimPolicy`
  and `volumeBindingMode` can't be changed on an existing StorageClass.
  Delete and let Helm recreate it (same fix as above).
- **`ssd` StorageClass missing (`storageclass.storage.k8s.io "ssd" not
  found`) and `helm upgrade`/`helm install` does *not* recreate it**: the
  chart only renders the `ssd` StorageClass when a `lookup` at render time
  doesn't find one already on the cluster
  (`templates/storageclass/storageclass.yaml`), so Helm never actually
  tracks/owns that object in the release manifest. If it's deleted
  out-of-band afterward — e.g. by an interrupted `helm uninstall` whose
  pre-delete hook ran `kubectl delete storageclass ssd` before the hook
  itself failed to complete — no subsequent `helm upgrade` will bring it
  back, since Helm has no record it needs to. Recreate it manually:
  ```bash
  kubectl apply -f - <<'YAML'
  apiVersion: storage.k8s.io/v1
  kind: StorageClass
  metadata:
    name: ssd
  provisioner: cinder.csi.openstack.org
  reclaimPolicy: Delete
  allowVolumeExpansion: true
  volumeBindingMode: WaitForFirstConsumer
  YAML
  ```
  Tracked as [#108](https://github.com/NatLabRockies/openstudio-server-helm/issues/108) (needs a design decision on whether to stop using `lookup` here).
- **Helm v4 `conflict occurred while applying object ... with subresource
  "scale"`**: Helm v4 uses server-side apply by default. If a Deployment's
  `.spec.replicas` is currently owned by `kube-controller-manager` (via an
  active HPA, e.g. from a previous partially-failed install), Helm won't
  overwrite it without `--force-conflicts` on `helm upgrade --install`.
  This is expected on essentially every routine upgrade once the `web`/
  `worker` HPAs have scaled at least once — not just a failure-recovery
  edge case — so **always include `--force-conflicts` on `helm upgrade`**
  against a live release:
  ```bash
  helm upgrade --install openstudio-server ./openstudio-server \
    -f openstack/values-openstack.yaml -n openstudio-server --force-conflicts
  ```
  Tracked as [#110](https://github.com/NatLabRockies/openstudio-server-helm/issues/110) (proper fix is to stop hardcoding `replicas:` under active HPA control).
- If a previous `helm install`/`uninstall` didn't complete cleanly (e.g.
  pods stuck `Terminating` due to a container runtime issue), don't retry
  with a fresh `helm install` into the same failed release — use
  `helm upgrade --install ... --force-conflicts` to move it forward
  instead, after clearing any stuck pods
  (`kubectl delete pods --all -n <namespace> --grace-period=0 --force`).

- **Resque UI looks frozen / simulations appear stalled**: check for all three
  causes before assuming the cluster is wedged — throughput is usually
  non-zero but degraded.
  1. **Zombie Resque workers** (registered in Redis, pod no longer exists) hold
     jobs that will never run. Compare `SMEMBERS resque:workers` against live
     pods; snapshot Redis *first*, then `kubectl`, to avoid race false-positives.
  2. **Unschedulable/unpullable worker pods** pin `worker-hpa` at
     `maxReplicas` so it can't react. See the `worker_hpa.maxReplicas` notes in
     `values-openstack.yaml.template`.
  3. **Slow-by-design simulations.** Wall-clock is dominated by the analysis's
     building type (~15x spread; `SecondarySchool` averages 159 min vs
     `SmallOffice` at 9 min) against a uniform client-submitted 4h
     `run_workflow_timeout`. Full write-up:
     [`docs/simulation-timeout-building-type-incident.md`](../docs/simulation-timeout-building-type-incident.md).

  Note the Mongo database is `os_docker` (not `os_server`), and the
  `containerd-registry-config` DaemonSet adds ~9,000 pods to every
  `kubectl get pods` listing — filter it out.
