---
status: superseded by 0049
date: 2026-06-18
---

# 0036. Run AWS through the managed EKS control plane

## Context

bedrock was gaining a second cloud provider. Hetzner had carried every cluster so far on self-hosted k3s, and AWS joined it, so this record settles how AWS clusters take their control plane. The answer follows from the principle firming up across the surrounding records: the cluster and its GitOps are the durable source of truth, and horizon is a convenience tool that may not be maintained, so everything that keeps a cluster alive must work without it. Under that principle the largest standing risk on an unattended cluster is the self-hosted control plane, where etcd has to be backed up and restored, certificates rotate, and minor upgrades have to be driven on a schedule. Hetzner sells no managed Kubernetes, so k3s is the only option there. AWS offers a managed control plane through EKS, which the Cluster API provider exposes as a first-class resource, and handing etcd, certificates, and upgrades to AWS removes exactly the part of an unattended cluster that is hardest to keep healthy. The objections that would normally push back on EKS are all horizon-shaped: it does not fit horizon's ClusterClass topology, it has no control-plane machines to count, its workers come from MachinePools rather than the MachineDeployments horizon scales, and an upstream provider issue blocked EKS workers inside a ClusterClass topology. Every one of those assumes AWS is authored through horizon's provider-agnostic create path, and they dissolve once AWS is authored directly as plain CAPI manifests.

## Decision

Author AWS clusters directly in bedrock as plain CAPI manifests built on the provider's managed EKS control-plane resource. AWS clusters do not go through horizon's ClusterClass create path. The control plane is EKS, owned by AWS; the manifests live in the repository and reconcile through the same Flux and CAPI controllers that own every other object here. This makes the managed-versus-self-hosted split explicit rather than accidental: where a cloud offers a managed control plane bedrock takes it, and where it does not bedrock self-hosts. The asymmetry is the point, since each provider takes the most durable control plane it can offer and the repository absorbs the difference in how the two are authored.

## Options considered

- Self-managed k3s on EC2, rejected. It would give AWS the same uniform substrate horizon already drives on Hetzner, but it self-hosts a control plane on a cloud that sells a managed one and keeps the etcd, certificate, and upgrade burden the durability principle exists to shed. Uniformity through horizon is not worth that burden when horizon is optional.
- kubeadm on EC2, rejected. It is the canonical upstream way to stand up a cluster and the provider supports it well, but it still self-hosts the control plane and adds a second bootstrapper to the repository, so it trades nothing for the operational weight it adds.
- The managed EKS control plane, chosen. AWS owns etcd, certificates, and control-plane upgrades, which removes the heaviest unattended-cluster risk, and the cluster is authored directly in bedrock as plain manifests, so it does not depend on horizon to exist or to recover.

## Consequences

horizon's ClusterClass create path is unchanged and stays Hetzner and k3s; AWS simply does not travel that road, so the horizon-shaped objections, including the ClusterClass topology issue and the MachinePool mismatch, fall away. AWS credentials are a dedicated scoped identity rather than the account root, bootstrapped through the provider's admin tool, and that identity's access key, encrypted with SOPS, is the only credential the repository holds. The first cluster is authored as plain manifests with a single managed node group on a small instance, and its IAM roles bound by name to the ones the bootstrap created. The EKS control plane bills for as long as the cluster exists, so a cluster is brought up for use and torn down when idle, which [0042](0042-ephemeral-eks-autoscaling-and-s3-foothold.md) turns into an explicit ephemerality rule before [0049](0049-remove-aws-multicloud-build.md) removes the AWS build entirely.

This sits alongside [0034](0034-standalone-cluster-node-snapshot.md), which gives Hetzner its provider-agnostic ClusterClass and standalone node image, and [0035](0035-standalone-gitops-managed-cloud-cluster.md), which makes any cloud peer self-bootstrap its GitOps from a label. An EKS cluster labelled as a GitOps peer reconciles the shared cloud-safe overlay the same way a Hetzner peer does, so the asymmetry in control planes does not extend to how the two are managed once they are running.
