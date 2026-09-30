# OpenStudio Server

[OpenStudio Server](https://github.com/NREL/OpenStudio-server) is a Kubernetes deployable instance using helm charts which allows for large-scale parametric analyses of building energy models using the OpenStudio SDK in the form of OpenStudio measures.

## Introduction

This helm chart installs a OpenStudio-server instance (https://github.com/NREL/OpenStudio-server/) deployment on a [Kubernetes](http://kubernetes.io) cluster using the [Helm](https://helm.sh) package manager.
You can interface with the OpenStudio-server cluster using the [Parametric Analysis Tool](https://github.com/NREL/OpenStudio-PAT), which is part of the OpenStudio collection of software tools.

Note that this repository has both information for small and large workloads in the cloud. Refer to the Large Workload section below and in the [aws README](/aws/README.md).

## Prerequisites

- Kubernetes 1.27+ cluster. Please refer to cluster setup instructions for [google](/google/README.md) or [aws](/aws/README.md) for information on how to provision a cluster.
- [helm client](https://helm.sh/docs/intro/install/) (v3.12.0 or higher)
- [kubectl client](https://kubernetes.io/docs/tasks/tools/install-kubectl/) (v1.27.0 or higher)

## Installing the Chart

To install the helm chart with the chart name `openstudio-server`, you can run the following command in the root directory of this repo. This assumes you already have a Kubernetes cluster up and running. If you do not, please refer to [google](/google/README.md) or [aws](/aws/README.md) in this repo.

### For Google

```bash
helm install openstudio-server ./openstudio-server --set provider.name=google
```

### For Amazon

```bash
helm install openstudio-server ./openstudio-server --set provider.name=aws
```

### For Azure

```bash
helm install openstudio-server ./openstudio-server --set provider.name=azure
```

## Uninstalling the Chart

To uninstall/delete the `openstudio-server` helm chart:

```bash
helm uninstall openstudio-server
```

The command removes all the Kubernetes components associated with the chart and deletes the release _including_ persistent volumes. See more about persistent volumes below.

## Configuration

The following table lists the configurable parameters of the OpenStudio-server chart and their default values. You can override any of these values by specifying each parameter using the `--set key=value[,key=value]` argument to `helm install`. For example, to change the data storage for NFS which stores the data points to 300GB you would run this install command:

### For Google

```bash
helm install openstudio-server ./openstudio-server --set provider.name=google --set nfs-server-provisioner.persistence.size=300Gi
```

### For Amazon

```bash
helm install openstudio-server ./openstudio-server --set provider.name=aws --set nfs-server-provisioner.persistence.size=300Gi
```

### For Azure

```bash
helm install openstudio-server ./openstudio-server --set provider.name=azure --set nfs-server-provisioner.persistence.size=300Gi
```

Parameter | Description | Default
--------- | ----------- | -------
nfs-server-provisioner.persistence.size | Size of the volume for storing the data point results | 550Gi |
db.persistence.size | Size of the volume for MongoDB | 200Gi |
cluster.name | Kubernetes AWS or Google cluster name. If you change the default name you need to set this name here otherwise AWS auto-scaling will not work correctly | openstudio-server |
worker_hpa.minReplicas | Worker pods that run the simulations | 2 |
worker_hpa.maxReplicas | Maximum Worker pods that run the simulations | 20 |
worker_hpa.targetCPUUtilizationPercentage | When aggregate CPU % of worker pods exceed threshold begin scaling. | 50 |
web_background.replicas  | Number of projects/analyses to run in parallel. __*Note__ Algorithmic runs are currently not supported to run in parallel. Keep default value of 1 for these types of analyses.  | 1 |
web_background.container.image  | Container to run the web background. Can use a custom image to override default | nrel/openstudio-server:3.7.0 |
web.container.image   | Container to run the web front-end. Can use a custom image to override default | nrel/openstudio-server:3.7.0 |
worker.container.image   | Container to run the worker. Can use a custom image to override default | nrel/openstudio-server:3.7.0 |
rserve.container.image   | Container to run r server. Can use a custom image to override default | nrel/openstudio-rserve:3.7.0 |

#### For Large Workloads
Copy the text from inside the [large template values file](/openstudio-server/values_large.templateyaml)] and paste it inside of the [values file](/openstudio-server/values.yaml). Do this before using the `helm install ...` command.

Additionally, note that with large workloads you may have issues with downloading container images from Docker Hub if you have a lot of worker nodes. Therefore, you may want to upload the container images into the cloud's container registry and then update the container image path in the [values file](/openstudio-server/values.yaml). This [article](https://docs.aws.amazon.com/AmazonECR/latest/userguide/docker-push-ecr-image.html#:~:text=Identify%20the%20local%20image%20to,container%20images%20on%20your%20system.&text=You%20can%20identify%20an%20image,tag%20name%20combination%20to%20use.) has instructions on how to do this for aws' Elastic Container Registry (ECR).

## Accessing OpenStudio Server

First make sure all the Kubernetes pods are up in running. You can confirm this by running:

```bash
kubectl get pods
```

example output of all pods running:

```bash
NAME                                                       READY   STATUS    RESTARTS   AGE
db-5ff59c484-hl468                                         1/1     Running   0          4m22s
openstudio-server-nfs-server-provisioner-884774d4f-8pm4d   1/1     Running   0          4m22s
redis-687fc94686-tkb9l                                     1/1     Running   0          4m22s
rserve-67cb86849b-jph25                                    1/1     Running   0          4m22s
web-694557fcc7-cd5q8                                       1/1     Running   0          4m22s
web-background-6968ff9cd5-58hbn                            1/1     Running   0          4m22s
worker-5cf4db9bbd-2pld8                                    1/1     Running   0          2m52s
worker-5cf4db9bbd-6n4pz                                    1/1     Running   0          4m7s
worker-5cf4db9bbd-bvv5z                                    1/1     Running   0          2m52s
worker-5cf4db9bbd-sm9s7                                    1/1     Running   0          4m22s
worker-5cf4db9bbd-z92xx                                    1/1     Running   0          2m52s
```
You can see CPU and memory utilization by running:

```bash
kubectl top pods
```

example output of all pods running:

```bash
NAME                                                       CPU(cores)   MEMORY(bytes)
db-5ff59c484-hl468                                         4m           171Mi
openstudio-server-nfs-server-provisioner-884774d4f-8pm4d   2m           110Mi
redis-687fc94686-tkb9l                                     2m           2Mi
rserve-67cb86849b-jph25                                    1m           78Mi
web-694557fcc7-cd5q8                                       2m           421Mi
web-background-6968ff9cd5-58hbn                            1m           182Mi
worker-5cf4db9bbd-2pld8                                    1m           172Mi
worker-5cf4db9bbd-6n4pz                                    1m           178Mi
worker-5cf4db9bbd-bvv5z                                    1m           172Mi
worker-5cf4db9bbd-sm9s7                                    1m           176Mi
worker-5cf4db9bbd-z92xx                                    1m           172Mi
```
Note that 1000m means one virtual CPU core.

You can also add `watch` to the beginning of the command to see the output change over time.

Once the cluster is up and running, you can use `kubectl` to determine the external IP or DN to access OpenStudio server and use this in PAT to connect to. For example, on AWS, a0a4014d98f0211ea91cb06528280f48-1900622776.us-west-2.elb.amazonaws.com is the external name. See the examples below for each cloud provider.

AWS is the long domain (a0a4014d98f0211ea91cb06528280f48-1900622776.us-west-2.elb.amazonaws.com)

```bash
kubectl get svc ingress-load-balancer
```

example output:

```bash
NAME                    TYPE           CLUSTER-IP      EXTERNAL-IP                                                               PORT(S)                      AGE
ingress-load-balancer   LoadBalancer   10.100.246.21   a52e7c2e22f3940a8aa9d80b5220d468-1479205808.us-east-1.elb.amazonaws.com   80:32739/TCP,443:31344/TCP   5m56s
```

Google is 35.247.75.9

```bash
kubectl get svc ingress-load-balancer
```

example output:

```bash
NAME                    TYPE           CLUSTER-IP      EXTERNAL-IP   PORT(S)                      AGE
ingress-load-balancer   LoadBalancer   10.55.246.197   35.247.75.9   80:32613/TCP,443:31562/TCP   35m
```

Azure is 20.190.10.17

```bash
kubectl get svc ingress-load-balancer
```

example output:

```bash
NAME                                       TYPE           CLUSTER-IP    EXTERNAL-IP    PORT(S)  AGE
ingress-load-balancer                      LoadBalancer   10.0.248.18   20.190.10.17   80:31879/TCP 443:30780/TCP 3m53s
```

You will then use this EXTERNAL-IP to use with PAT to connect to an existing cloud server. In the AWS example, you would enter http://a0a4014d98f0211ea91cb06528280f48-1900622776.us-west-2.elb.amazonaws.com in PAT under Existing Server URL in PAT. For Google, http://35.247.75.9. For Azure, http://20.190.10.17

## Persistent Volumes

This helm chart provisions persistent storage for the Database (MongoDB) and the NFS server (storage for data results). These will persist throughout the life of the helm chart while it's running. It will **NOT** persist if you delete the helm chart. The volumes will be deleted along with it.

While it's possible to change the storage to use `Retain` vs `Delete`, the helm chart will need to be reconfigured to allow to attach to existing volumes. This will be worked on as an enhancement for a future release.

## Local Image Registry (Optional)

The chart can deploy an in-cluster Docker registry (using `distribution/registry:2`) and rewrite all workload images to pull from it. This is useful for:

- Air-gapped environments without internet access
- Avoiding Docker Hub rate limits
- Caching images locally for faster pulls
- Security/compliance requirements

### Enabling the Local Registry

```bash
helm install openstudio-server ./openstudio-server \
  --set localRegistry.enabled=true \
  --set localRegistry.rewriteImages=true \
  --set localRegistry.persistence.storageClass=ssd \
  --set localRegistry.persistence.size=20Gi
```

Or via values file:

```yaml
localRegistry:
  enabled: true
  rewriteImages: true
  persistence:
    storageClass: "ssd"
    size: 20Gi
```

### How It Works

When `localRegistry.enabled=true` and `localRegistry.rewriteImages=true`:

1. The `local-registry` subchart deploys a single-replica registry Deployment with PVC
2. All workload images (web, web-background, worker, db, redis, rserve, cluster-autoscaler, pre-delete hook) are rewritten:
   - `nrel/openstudio-server:3.8.0-1` → `<release-name>-local-registry:5000/nrel/openstudio-server:3.8.0-1`
   - `mongo:6.0.7` → `<release-name>-local-registry:5000/mongo:6.0.7`
   - etc.
3. The cluster-autoscaler gets an initContainer that waits for the registry to be ready before starting

### Pushing Images to the Local Registry

After deploying with the local registry enabled, you must push all required images to it:

```bash
# Get the registry service name
REGISTRY=$(kubectl get svc -n <namespace> -l app.kubernetes.io/name=local-registry -o jsonpath='{.items[0].metadata.name}')

# Port-forward to access locally
kubectl port-forward -n <namespace> svc/$REGISTRY 5000:5000

# In another terminal, tag and push images
docker pull nrel/openstudio-server:3.8.0-1
docker tag nrel/openstudio-server:3.8.0-1 localhost:5000/nrel/openstudio-server:3.8.0-1
docker push localhost:5000/nrel/openstudio-server:3.8.0-1

# Repeat for all required images:
# - nrel/openstudio-server:3.8.0-1
# - nrel/openstudio-rserve:3.8.0-1
# - mongo:6.0.7
# - redis:6.0.9
# - bitnami/kubectl:latest (for pre-delete hook)
# - registry.k8s.io/autoscaling/cluster-autoscaler:v1.26.6
```

### Using an External Registry Instead

If you already have a registry deployed elsewhere, you can use it instead of the subchart:

```yaml
localRegistry:
  enabled: false        # Don't deploy the subchart
  hostname: "my-registry.internal"
  port: 5000
  rewriteImages: true   # Still rewrite image references
```

### Configuration Reference

| Parameter | Description | Default |
|-----------|-------------|---------|
| `localRegistry.enabled` | Deploy the local registry subchart | `false` |
| `localRegistry.rewriteImages` | Rewrite all workload image references | `true` |
| `localRegistry.image` | Registry container image | `registry:2` |
| `localRegistry.persistence.enabled` | Enable PVC for registry storage | `true` |
| `localRegistry.persistence.storageClass` | Storage class for PVC | `ssd` |
| `localRegistry.persistence.size` | PVC size | `10Gi` |
| `localRegistry.hostname` | External registry hostname (if not using subchart) | `""` |
| `localRegistry.port` | Registry port | `5000` |

### Troubleshooting

- **ImagePullBackOff**: Images haven't been pushed to the local registry yet
- **PVC Pending**: Check storage class availability and permissions. If the
  PVC's `storageClassName` doesn't exist on the cluster at all (`storageclass
  ... not found`), verify `localRegistry.persistence.storageClass` matches a
  real StorageClass name — e.g. on OpenStack/Azimuth clusters the chart's own
  provisioned class is named `ssd`, not `cinder-csi` ([#107](https://github.com/NatLabRockies/openstudio-server-helm/issues/107)).
  If it previously existed and is now `not found`, see the note below on
  `lookup`-created StorageClasses not self-healing
  ([#108](https://github.com/NatLabRockies/openstudio-server-helm/issues/108)).
- **`container has runAsNonRoot and image will run as root`**: fixed as of
  this chart version — the local-registry container now applies
  `localRegistry.securityContext` (`runAsUser`/`runAsGroup`) in addition to
  the pod-level `podSecurityContext`. If you see this on an older release,
  `helm upgrade` to pick up the fix ([#109](https://github.com/NatLabRockies/openstudio-server-helm/issues/109)).
- **Cluster-autoscaler stuck in Init**: The initContainer is waiting for the registry; check registry pod logs
- **Registry not accessible**: Verify service exists and port-forward works
- **`helm upgrade` fails with `conflict occurred while applying object ...
  with subresource "scale"`**: unrelated to the local registry itself, but
  commonly hit right after enabling it if `web`/`worker` HPAs have already
  scaled at least once — pass `--force-conflicts` to `helm upgrade`
  ([#110](https://github.com/NatLabRockies/openstudio-server-helm/issues/110), see also
  [openstack/README.md](./openstack/README.md#troubleshooting)).

## Port-Forward Tunnel Reliability (Lens vs. kubectl)

When connecting from a local client (e.g., `openstudio-bem-to-surrogate-gem`) to the server via `localhost:61570`, Lens application port-forwards can become unstable under long-running sequential analysis submissions (`rake execute_sequential`). If you observe `Connection refused - connect(2) for "localhost" port 61570` errors after a period of successful submits, the Lens tunnel may have dropped while its UI still reports `Active`.

**Recommended workaround:** Bypass Lens with a dedicated `kubectl port-forward` process that is independent of the Lens application lifecycle:

```bash
# From openstudio-bem-to-surrogate-gem
bash scripts/port_forward_kubectl.sh
```

This script creates a persistent `kubectl port-forward -n openstudio-server service/web 61570:80` tunnel. It also kills leftover Lens-managed `kubectl` processes that can conflict on the same port. The tunnel remains alive as long as the `kubectl` process runs, making it more reliable for multi-hour sequential analysis runs.

See [docs/port-forward-and-jump-pod-troubleshooting.md](./docs/port-forward-and-jump-pod-troubleshooting.md) for 502s and stale-tunnel diagnosis, and [docs/jump-pod.md](./docs/jump-pod.md) for submitting from inside the cluster instead.

Note: Reducing `passenger_memory_per_process` (and thus `max_pool`) was tested (`250` -> `333` MiB) but did **not** resolve the connection failures; the root cause was tunnel instability, not server overload.

## Helper Scripts

All scripts in `scripts/` retry transient API gateway errors (502/503/504) via `scripts/lib/retry_cmd.sh`. Extra Helm arguments can follow an optional `--`.

| Script | Purpose |
| --- | --- |
| `install.sh`, `upgrade.sh` (`--force-conflicts` for HPA-scaled releases), `uninstall.sh`, `*-dry-run.sh` | Helm wrappers with retries, e.g. `scripts/upgrade.sh -f openstack/values-openstack.yaml` |
| `apply_single_template.sh` | Apply one rendered template with `kubectl` (leaves Helm release state out of sync) |
| `pre-install-cleanup.sh` | **Destructive**: removes leftover pods, NFS PVCs and PVs before a reinstall (asks for confirmation) |
| `clean-operational.sh` | **Destructive**: clears NFS, MongoDB and Redis contents while keeping volumes (asks for confirmation) |
| `port_forward_kubectl.sh` | Stable `kubectl port-forward` to `web` on `localhost:61570` |
| `submit_from_jump_pod.sh`, `install_jump_pod_gems.sh` | In-cluster submission, see [docs/jump-pod.md](./docs/jump-pod.md) |
| `pulp_login.py` | Log in to a Pulp registry via Keycloak device flow; pass `--registry`, `--client-id`, `--keycloak-url` (or `PULP_*` env vars); requires `requests` |

## Auto Scaling

The worker pods are configured to auto-scale based on CPU threshold (default 12%). Once the aggregate CPU for all worker pods exceed the defined threshold (in this case 12%), the Kubernetes engine will start adding additional worker pods up to the maximum specified. This is also dependent on how the Kuebernetes cluster was configured as additional VM node instances will also be added. Please refer to the notes on [aws](/aws/README.md) and [google](/google/README.md) when setting up the cluster and note the instance type and maximum nodes specified.

Once the aggregate CPU of the workers drop below 12%, the Kubernetes engine will start removing worker pod instances. There is a [prestop hook](https://kubernetes.io/docs/concepts/containers/container-lifecycle-hooks/) configured in the worker pod to ensure that if a openstudio job is still active it will not terminate the pod until it is finished.
