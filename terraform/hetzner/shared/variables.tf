variable "ssh_public_key" {
  description = "Operator SSH public key for burst nodes"
  type        = string
  sensitive   = true
}
