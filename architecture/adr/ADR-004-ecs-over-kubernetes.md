# ADR-004: ECS Over Kubernetes for Container Orchestration

**Status:** Accepted
**Date:** 2026-04-01
**Deciders:** Platform Team
**Category:** Infrastructure

---

## Context

All platform services run as Docker containers. We need a container orchestration layer to manage deployment, scaling, health checks, and service discovery. The two primary options on AWS are ECS (Elastic Container Service) with Fargate and EKS (Elastic Kubernetes Service).

The platform team is led by a Product Manager with moderate technical knowledge. The team does not have dedicated DevOps/SRE engineers with Kubernetes expertise. Operational simplicity is a priority.

## Decision

**We use AWS ECS with Fargate launch type** for all containerized services. Fargate eliminates the need to manage EC2 instances — AWS handles the underlying infrastructure.

## Rationale

| Factor | ECS + Fargate | EKS (Kubernetes) |
|---|---|---|
| Operational complexity | Low — AWS manages everything below the task level | High — cluster upgrades, node groups, RBAC, networking plugins |
| Learning curve | Minimal — task definitions, services, ALB integration | Steep — manifests, Helm charts, operators, CRDs |
| Cost (at our scale) | Moderate — Fargate premium vs EC2 | Higher — EKS control plane fee + node costs + tooling |
| Scaling | Built-in auto-scaling on CPU/memory/request count | Requires Horizontal Pod Autoscaler + Cluster Autoscaler |
| Service mesh | Not needed at our scale | Tempting to adopt, adds massive complexity |
| Deployment | Rolling update built-in, blue/green via CodeDeploy | Requires tooling (ArgoCD, Flux, or manual kubectl) |
| Portability | AWS-locked | Portable (but we're fully committed to AWS) |

At our scale (5 services, 10–40 tasks total), Kubernetes is over-engineered. The operational overhead of maintaining an EKS cluster, managing node group upgrades, configuring networking (VPC CNI, Calico), and training the team on Kubernetes concepts significantly outweighs any benefit.

## Consequences

**Positive:**
- Near-zero operational overhead for container management
- Built-in integration with ALB, CloudWatch, IAM, Secrets Manager
- Simple deployment model (update task definition → rolling update)
- Team can focus on application logic, not infrastructure

**Negative:**
- Vendor lock-in to AWS (migration to another cloud would require rewriting deployment)
- Fargate pricing is ~30% higher than equivalent EC2 for sustained workloads
- Less ecosystem tooling compared to Kubernetes (no Helm, no ArgoCD)
- No service mesh capabilities (not needed for Phase 1)

**Mitigations:**
- Vendor lock-in is acceptable — MOFSL is committed to AWS, and the application layer (Node.js Docker containers) is portable
- Fargate cost premium is acceptable for the operational simplicity gained
- If scale grows dramatically (100+ services), we can evaluate migration to EKS

## Alternatives Considered

1. **EKS (Kubernetes):** Full-featured, portable, massive ecosystem. Rejected because operational overhead is too high for current team profile and scale.

2. **EC2 with Docker Compose:** Cheapest option, but no auto-scaling, no health checks, no rolling deployments. Rejected as not production-grade.

3. **ECS with EC2 launch type:** Cheaper than Fargate for steady-state workloads, but requires managing EC2 instances, AMI updates, capacity planning. Rejected for operational simplicity.
