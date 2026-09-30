output "proxy_instance_id" {
  description = "OpenStack instance ID for the proxy VM."
  value       = openstack_compute_instance_v2.proxy.id
}

output "proxy_private_ip" {
  description = "Private IP address of the proxy VM on the portal-internal network."
  value       = openstack_networking_port_v2.proxy.all_fixed_ips[0]
}

output "proxy_floating_ip" {
  description = "Public floating IP bound to the proxy VM."
  value       = openstack_networking_floatingip_v2.proxy.address
}
