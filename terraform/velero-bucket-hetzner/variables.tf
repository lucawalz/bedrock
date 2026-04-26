variable "bucket_name" {
  description = "Hetzner Object Storage bucket name for Velero backups"
  type        = string
  default     = "horizon-velero-backups"
}

variable "location" {
  description = "Hetzner Object Storage location (fsn1, nbg1, hel1)"
  type        = string
  default     = "fsn1"
}

variable "access_key" {
  description = "Hetzner Object Storage access key ID"
  type        = string
  sensitive   = true
}

variable "secret_key" {
  description = "Hetzner Object Storage secret access key"
  type        = string
  sensitive   = true
}
