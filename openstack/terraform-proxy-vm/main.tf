terraform {
  required_version = ">= 1.5.0"

  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 2.0"
    }
  }
}

provider "openstack" {
  cloud = var.cloud_name
}

data "openstack_networking_network_v2" "portal_internal" {
  name = var.network_name
}

resource "openstack_networking_secgroup_v2" "proxy" {
  name        = "${var.name}-sg"
  description = "Security group for the OpenStudio proxy VM"
}

resource "openstack_networking_secgroup_rule_v2" "egress" {
  direction         = "egress"
  ethertype         = "IPv4"
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.proxy.id
}

resource "openstack_networking_secgroup_rule_v2" "ssh" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = var.ssh_cidr
  security_group_id = openstack_networking_secgroup_v2.proxy.id
}

resource "openstack_networking_secgroup_rule_v2" "http" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 80
  port_range_max    = 80
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.proxy.id
}

resource "openstack_networking_secgroup_rule_v2" "https" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 443
  port_range_max    = 443
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.proxy.id
}

resource "openstack_networking_port_v2" "proxy" {
  name               = "${var.name}-port"
  network_id         = data.openstack_networking_network_v2.portal_internal.id
  admin_state_up     = true
  security_group_ids = [openstack_networking_secgroup_v2.proxy.id]

  fixed_ip {
    subnet_id = var.subnet_id != "" ? var.subnet_id : data.openstack_networking_network_v2.portal_internal.subnets[0]
  }
}

resource "openstack_networking_floatingip_v2" "proxy" {
  pool    = var.floating_ip_pool
  port_id = openstack_networking_port_v2.proxy.id
}

locals {
  upstream_servers = join("\n", [for host in var.nodeport_upstream_hosts : "  server ${host}:${var.nodeport_port};"])
}

resource "openstack_compute_instance_v2" "proxy" {
  name            = var.name
  image_name      = var.image_name
  flavor_name     = var.flavor_name
  key_pair        = var.keypair_name
  security_groups = [openstack_networking_secgroup_v2.proxy.name]
  user_data = templatefile("${path.module}/cloud-init.tpl", {
    upstream_servers = local.upstream_servers
    nodeport_port    = var.nodeport_port
  })

  network {
    port = openstack_networking_port_v2.proxy.id
  }
}
