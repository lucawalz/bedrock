output "server_ipv4" {
  value = hcloud_server.burst_node.ipv4_address
}

output "server_id" {
  value = hcloud_server.burst_node.id
}

output "server_hostname" {
  value = hcloud_server.burst_node.name
}
