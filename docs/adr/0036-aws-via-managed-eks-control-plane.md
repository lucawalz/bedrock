---
status: accepted
date: 2026-06-18
---

# 0036. Run AWS through the managed EKS control plane

## Context

bedrock is gaining a second cloud provider. Hetzner has carried every cluster so far, on self-hosted k3s, and AWS now joins it. The question this record settles is how AWS clusters take their control plane, and the answer follows from a principle that has been firming up across the recent records: the cluster and its GitOps, the bedrock repository plus the in-cluster CAPI controllers, are the durable source of truth. horizon is a convenience tool for on-demand nodes, clusters, and backups, and it may not be maintained indefinitely. Everything that keeps a cluster alive must work without it.

Under that principle the largest standing risk on an unattended cluster is the self-hosted control plane. etcd has to be backed up and restored, certificates rotate, and Kubernetes minor upgrades have to be driven on a schedule. On Hetzner there is no choice: Hetzner sells no managed Kubernetes, so k3s is the only option, and horizon's operator-pivot decision already made it a thin operator over a CAPI substrate that lives in bedrock, so the Hetzner control plane is already as durable as it can be made. AWS is different. It offers a managed control plane through EKS, and the Cluster API Provider AWS exposes it as `AWSManagedControlPlane`. Handing etcd, certificates, and control-plane upgrades to AWS removes exactly the part of an unattended cluster that is hardest to keep healthy without bespoke tooling.

The objections that would normally push back on EKS here are all horizon-shaped. EKS does not fit horizon's ClusterClass topology, it cannot be driven by `--cp-replicas` because there are no control-plane machines to count, its workers come from MachinePools rather than the worker MachineDeployments horizon scales, and CAPA issue #4658 blocks EKS workers inside a ClusterClass topology. Every one of those objections assumes AWS is authored through horizon's provider-agnostic create path. They dissolve once AWS is authored directly as plain CAPI manifests in bedrock, which is the posture the durability principle calls for anyway.

## Decision

Author AWS clusters directly in bedrock as plain CAPI manifests built on CAPA's `AWSManagedControlPlane`, the managed EKS control plane. AWS clusters do not go through horizon's ClusterClass create path. The control plane is EKS, owned by AWS; the manifests live in the repository and reconcile through the same Flux and CAPI controllers that own every other object here.

This makes the managed-versus-self-hosted split explicit and intentional rather than accidental. Where a cloud offers a managed control plane, bedrock takes it, so AWS runs EKS. Where a cloud does not, bedrock self-hosts, so Hetzner runs k3s. The asymmetry is the point: each provider takes the most durable control plane it can offer, and the repository absorbs the difference in how the two are authored.

## Options considered

- Self-managed k3s on EC2, rejected. It would give AWS the same uniform substrate horizon already drives on Hetzner, one bootstrapper and one mental model across both clouds. But it self-hosts a control plane on a cloud that sells a managed one, which reads as carrying a homelab pattern onto AWS for the sake of uniformity, and it keeps the etcd, certificate, and upgrade burden that the durability principle exists to shed. Uniformity through horizon is not worth that burden when horizon is optional.
- kubeadm on EC2, rejected. It is the canonical upstream way to stand up a cluster and CAPA supports it well, but it still self-hosts the control plane, so it carries the same etcd and upgrade burden as self-managed k3s while adding a second bootstrapper to the repository. It trades nothing for the operational weight it adds.
- The EKS managed control plane through `AWSManagedControlPlane`, chosen. AWS owns etcd, certificates, and control-plane upgrades, which removes the heaviest unattended-cluster risk, and the cluster is authored directly in bedrock as plain manifests, so it does not depend on horizon to exist or to recover.

## Consequences

horizon's ClusterClass create path is unchanged and stays Hetzner and k3s. horizon's provider-agnostic-create decision, which renders a topology Cluster against an operator-authored ClusterClass, and its operator-pivot decision, which put the CAPI substrate in bedrock, both still describe how a self-hosted cluster is created; AWS simply does not travel that road. There is no horizon change in this record.

EKS is authored directly in bedrock, so the horizon-shaped objections to it do not apply. In particular CAPA issue #4658, which prevents EKS worker templates from being used inside a ClusterClass topology, is irrelevant here because AWS is not authored through a ClusterClass at all. The MachinePool and `--cp-replicas` mismatches fall away for the same reason.

AWS credentials are placeholders for now. The CAPA provider and its credentials secret reconcile idle against dummy values, and an EKS cluster example is staged in the repository but not reconciled, so the provider wiring can be verified without standing up real infrastructure or incurring cost. Real credentials replace the placeholders when an EKS peer is actually brought up.

This sits alongside [0034](0034-standalone-cluster-node-snapshot.md), which gives Hetzner its provider-agnostic ClusterClass and standalone node image, and [0035](0035-standalone-gitops-managed-cloud-cluster.md), which makes any cloud peer self-bootstrap its GitOps from a label rather than from horizon. An EKS cluster labelled as a GitOps peer reconciles the shared cloud-safe overlay the same way a Hetzner peer does, so the asymmetry in control planes does not extend to how the two are managed once they are running.
