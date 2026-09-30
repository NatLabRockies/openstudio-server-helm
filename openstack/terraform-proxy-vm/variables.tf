variable "cloud_name" {
  description = "Optional OpenStack auth profile name from clouds.yaml. Leave blank to use the default profile."
  type        = string
  default     = ""
}

variable "name" {
  description = "Name of the proxy VM."
  type        = string
  default     = "openstudio-proxy-vm"
}

variable "network_name" {
  description = "Name of the internal OpenStack network that the proxy VM should attach to."
  type        = string
}

variable "subnet_id" {
  description = "Optional subnet UUID for the fixed IP. Leave blank to use the first subnet on the network."
  type        = string
  default     = ""
}

variable "floating_ip_pool" {
  description = "External floating IP pool name to attach to the proxy VM."
  type        = string
  default     = "public"
}

variable "image_name" {
  description = "Cloud image name for the Rocky Linux proxy VM."
  type        = string
  default     = "Rocky Linux 9.8"
}

variable "flavor_name" {
  description = "OpenStack flavor for the proxy VM."
  type        = string
  default     = "m1.small"
}

variable "keypair_name" {
  description = "OpenStack key pair name to inject into the proxy VM."
  type        = string
}

variable "ssh_cidr" {
  description = "CIDR allowed to reach SSH on the proxy VM."
  type        = string
  default     = "0.0.0.0/0"
}

variable "nodeport_upstream_hosts" {
  description = "List of Kubernetes node IPs behind the web Service's NodePort. Recommended for the OpenStack/OVN environment."
  type        = list(string)
  validation {
    condition     = length(var.nodeport_upstream_hosts) > 0
    error_message = "nodeport_upstream_hosts must contain at least one Kubernetes node address."
  }
}

variable "nodeport_port" {
  description = "NodePort exposed by the web Service."
  type        = number
  default     = 32105
}
