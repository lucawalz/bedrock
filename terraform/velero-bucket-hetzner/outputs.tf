output "bucket_name" {
  value = minio_s3_bucket.velero.bucket
}

output "endpoint_url" {
  value = "https://${var.location}.your-objectstorage.com"
}
