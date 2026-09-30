# OpenStack proxy VM Terraform example

This example provisions a tiny Rocky Linux VM in the portal-internal network, attaches a floating IP, and installs nginx as a reverse proxy to the OpenStudio web service.

It avoids hard-coding the unstable Octavia service VIP. Instead, it targets the `web` Service's stable NodePort endpoints directly, which are reachable from the internal network and avoid the broken OVN-backed floating-IP path.

## Why this design

The root cause in this environment is that the Octavia/OVN load balancer VIP path is not usable externally: the VIP ports remain unbound (`binding_host_id: null`, `status: DOWN`) and floating IP DNAT traffic never reaches the back end. The internal Service VIP can work from the portal-internal network, but it is still too fragile for a durable static config.

The proxy VM therefore uses a NodePort-based upstream, which is much less dependent on the LB provisioning lifecycle and survives Service recreation much better.

## Inputs

- `network_name`: internal network the proxy VM attaches to
- `keypair_name`: OpenStack keypair to inject
- `floating_ip_pool`: the external floating IP pool, e.g. `public`
- `nodeport_upstream_hosts` (required): Kubernetes node IPs behind the `web` Service `NodePort`; get them with `kubectl get nodes -o wide`
- `nodeport_port`: the NodePort value, `32105` by default

## Prerequisites

- An OpenStack `clouds.yaml` entry (set `cloud_name`) with permission to create security groups, ports, floating IPs and instances.
- The web Service must be a NodePort on the same port. In the OpenStack values file set:

  ```yaml
  web_svc:
    type: NodePort
    nodePorts:
      http: 32105
  ```

- The security group allows inbound 22/80/443 and all egress (needed for the package install and to reach the node ports). Restrict `ssh_cidr`.
- Destroy with `terraform destroy -var-file=terraform.tfvars`.

## Example

```bash
cd openstack/terraform-proxy-vm
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars to match your environment
terraform init
terraform plan -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
```

## Notes

- This is a good foundation for IaC, but the real long-term fix is still to resolve the Octavia/Azimuth LB problem at the platform level.
- If the cluster node IPs change, update `nodeport_upstream_hosts` and rerun `terraform apply` or make the config self-healing with a cron/systemd timer on the VM.
- The proxy VM still needs `setsebool -P httpd_can_network_connect 1` in the startup script; it is included here to prevent the SELinux 13-permission-denied failure that broke the original manual setup.
