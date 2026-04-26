terraform {
  required_providers {
    minio = {
      source  = "aminueza/minio"
      version = "~> 3.3"
    }
  }
}

provider "minio" {
  minio_server   = "${var.location}.your-objectstorage.com"
  minio_user     = var.access_key
  minio_password = var.secret_key
  minio_region   = var.location
  minio_ssl      = true
}

resource "minio_s3_bucket" "velero" {
  bucket = var.bucket_name
  acl    = "private"
}
