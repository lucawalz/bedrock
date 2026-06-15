# Object storage bucket bootstrap

Velero stores its backups in an S3-compatible object storage bucket. Creating that bucket is a one-time bootstrap step performed out-of-band, in the same spirit as the cluster age key: a single manual action whose result is recorded in GitOps rather than reproduced by destroy-capable automation.

## Why this is manual

No Terraform or other destroy-capable tooling runs against the object-storage provider from this repository. The provider account is shared with the separate vigil project, so a misapplied `terraform destroy` or a drifted state file could remove resources that belong to another estate. Bucket creation happens once and changes rarely, which does not justify carrying that blast radius. A bucket that already exists is simply reused.

## Creating the bucket

Any S3-compatible provider works, because Velero is configured with `provider: aws` and `s3ForcePathStyle: "true"` and talks to a custom endpoint. Create a single private bucket using the provider's console or its S3 CLI, for example:

```
aws --endpoint-url https://<endpoint> s3 mb s3://<bucket-name>
```

Record three coordinates from the result:

- the bucket name
- the endpoint URL
- the region

## Wiring it into the cluster

The three coordinates live in one place each:

- `kubernetes/clusters/home/infrastructure/storage/velero/helmrelease.yaml`, under the `objectStorage` values group (`bucket`, `region`, `s3Url`)
- `kubernetes/clusters/home/secrets/velero-s3-credentials.sops.yaml`, the SOPS-encrypted access key and secret key in the AWS INI `cloud` block

Editing the `objectStorage` group repoints Velero at a different bucket or provider; rotating the keys means re-encrypting the SOPS secret. Both are owned by Flux, so the change is reviewed and applied through GitOps.
