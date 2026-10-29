# Stroom-Proxy on AWS EKS

Terraform that builds an EKS cluster and runs Stroom-Proxy 7.14 on it,
receiving data over HTTPS on port 443. The design is in
[`design/proxy-eks-terraform-design.md`](../../design/proxy-eks-terraform-design.md).

**Status:** phases 1 and 2 (the `10-infra` and `20-platform` stacks) are
written. The proxy stack (`30-stroom-proxy`) and the `stroom-proxy` Helm chart
come in later phases.

## Layout

```
terraform/aws-eks-proxy/
├── modules/
│   ├── network/          # VPC, subnets, NAT gateways, optional VPC endpoints (or an existing VPC)
│   ├── eks/              # EKS cluster, system and proxy node groups, add-ons
│   └── platform/         # LB controller, gp3 StorageClass, CloudWatch, External Secrets
├── stacks/
│   ├── 10-infra/         # network + eks
│   └── 20-platform/      # platform, reading 10-infra's outputs from its state
└── envs/
    └── example/          # backend config and tfvars for one environment
```

Each stack has its own state, so a cluster rebuild doesn't force workload
changes and the Kubernetes providers in later stacks can be configured from
a cluster that already exists.

## What `10-infra` creates

* A VPC across 3 AZs with three tiers of subnets:
  * private (nodes and pods);
  * public (NAT gateways, internet-facing NLBs);
  * lb: a /26 per AZ with no NAT route, used only by the ALB and the internal
    NLBs. Proxy pods will accept traffic only from these ranges
    (`lb_subnet_cidrs` output), so nothing else should run in them.

  NAT gateways are `one_per_az` by default, or `single`. Set `existing_vpc_id`,
  `existing_private_subnet_ids` and `existing_lb_subnet_ids` to use an existing
  VPC.
* An EKS cluster:
  * access entries (`API` auth mode): the identity running Terraform plus
    `admin_principal_arns` get cluster-admin;
  * a private API endpoint, plus a public one only if `api_allowed_cidrs` is set
    (`0.0.0.0/0` is rejected);
  * Kubernetes Secrets encrypted with a KMS key;
  * optional control plane logging (`cluster_log_types`).
* Two managed node groups (AL2023, IMDSv2 required with hop limit 1, encrypted
  gp3 root volumes):
  * `system`: untainted, labelled `workload=system`, for CoreDNS, controllers
    and operators. Default 2 × `t3.medium`.
  * proxy node groups, one per AZ for each **colour** in `proxy_node_colours`
    (normally just `blue`; a second colour exists only during a blue/green
    upgrade). Named `proxy-<colour>-az<n>`, labelled `workload=stroom-proxy`
    and `stroom-proxy/colour=<colour>`, and tainted
    `workload=stroom-proxy:NoSchedule`, so only proxy pods run there. Default
    one `m6i.xlarge` on-demand node per AZ. Graviton (arm64) types are rejected
    because the `gchq/stroom-proxy` image is amd64-only.

    A colour's nodes never change after creation: its Kubernetes version is
    explicit and its AMI release is fixed (the latest when the colour is
    created, unless `ami_release_version` pins one). Node upgrades come from a
    new colour, not from in-place rolling updates.
* EKS add-ons: `vpc-cni` (network policy enforcement on), `coredns`,
  `kube-proxy`, `eks-pod-identity-agent`, and `aws-ebs-csi-driver` with a Pod
  Identity role and its node DaemonSet tolerating the proxy taint.

## What `20-platform` creates

Everything runs on the system nodes.

* **AWS Load Balancer Controller** (Helm chart 3.6.2, Pod Identity role with
  the controller's published IAM policy). Used only for `TargetGroupBinding`,
  which registers proxy pods in the ALB target groups that `30-stroom-proxy`
  creates, and for injecting pod readiness gates. Its ingress class and Service
  mutator are turned off. Its pod webhook is set to fail closed, so a proxy
  pod is never created without its readiness gate; two replicas with a
  PodDisruptionBudget keep the webhook available.
* **gp3 StorageClass**, the cluster default: encrypted, `WaitForFirstConsumer`
  (so each volume is created in its pod's AZ), expandable, with `gp3_iops` and
  `gp3_throughput`.
* **CloudWatch Observability add-on** (Container Insights metrics, Fluent Bit
  container logs) with a Pod Identity role. Its pods tolerate all taints (add-on
  1.7.0 and later, enforced), so logs are collected from the proxy nodes too. Terraform creates its four log
  groups (`/aws/containerinsights/<cluster>/{application,dataplane,host,performance}`)
  first, with `log_retention_days`; otherwise logs would be kept forever.
* **External Secrets Operator** (Helm chart 2.14.0, with its CRDs) and a Pod
  Identity role that can read only Secrets Manager secrets named
  `secrets_name_prefix*` (default `stroom-proxy/<name>/`). The `SecretStore`
  that uses it is created by `30-stroom-proxy`, in the proxy namespace:
  Terraform can't plan a custom resource in the same apply that installs its
  CRD.

The controllers are given the region and VPC ID explicitly, because the IMDS
hop limit of 1 stops pods reading them from instance metadata.

## Prerequisites

* Terraform 1.10 or later.
* AWS credentials for the target account, with rights to create VPC, EKS, IAM,
  KMS and EC2 resources.
* An S3 bucket for Terraform state (versioned, encrypted, access-restricted).
  State locking uses S3 itself (`use_lockfile`), so no DynamoDB table is needed.
* The AWS CLI and `kubectl`, to check the cluster afterwards.

## Usage

Copy `envs/example` to `envs/<env>`, then edit the backend files (state bucket
and key) and the tfvars. Apply the stacks in order.

### 10-infra

```sh
cd stacks/10-infra
terraform init -backend-config=../../envs/<env>/backend-10-infra.hcl
terraform plan  -var-file=../../envs/<env>/10-infra.tfvars -out=10-infra.tfplan
terraform apply 10-infra.tfplan
```

Creating the cluster and node groups takes about 15–20 minutes. Then:

```sh
$(terraform output -raw kubeconfig_command)
kubectl get nodes -L topology.kubernetes.io/zone,workload
kubectl get pods -n kube-system -o wide
```

You should see the system nodes and one proxy node per AZ for each colour,
with CoreDNS and the EBS CSI controller running on the system nodes.

If `api_allowed_cidrs` is empty, the Kubernetes API is reachable only from
inside the VPC (for example over a VPN, Direct Connect or a bastion). The same
applies to the later stacks, which use the Kubernetes and Helm providers.

### 20-platform

Set `infra_state` in `20-platform.tfvars` to the bucket, key and region of the
`10-infra` state. The machine running Terraform needs read access to that
state and must be able to reach the Kubernetes API. No AWS CLI is needed:
the providers authenticate with a token from `aws_eks_cluster_auth`.

```sh
cd stacks/20-platform
terraform init -backend-config=../../envs/<env>/backend-20-platform.hcl
terraform plan  -var-file=../../envs/<env>/20-platform.tfvars -out=20-platform.tfplan
terraform apply 20-platform.tfplan
```

Then:

```sh
kubectl get deploy -n kube-system aws-load-balancer-controller
kubectl get pods -n external-secrets
kubectl get pods -n amazon-cloudwatch -o wide   # fluent-bit on every node, proxy nodes included
kubectl get storageclass                        # gp3 (default)
```

## Main inputs (10-infra)

| Variable | Default | Notes |
|---|---|---|
| `aws_region`, `name` | (required) | `name` is also the cluster name: 3-29 characters, because it prefixes IAM role names. |
| `vpc_cidr`, `az_count`, `nat_gateway_mode` | `10.40.0.0/16`, `3`, `one_per_az` | New VPC only. |
| `existing_vpc_id`, `existing_private_subnet_ids`, `existing_lb_subnet_ids`, `existing_public_subnet_ids` | `null`, `[]`, `[]`, `[]` | Use an existing VPC. lb subnets (ALB and NLBs only, /27 or larger) are required; public subnets only for internet-facing NLBs. |
| `enable_vpc_endpoints` | `false` | S3, ECR, STS and CloudWatch Logs endpoints (new VPC only). |
| `cluster_version` | `1.37` | Upgrade one minor version at a time. |
| `admin_principal_arns` | `[]` | Extra cluster admins. Don't include the identity running Terraform: it is already an admin, and EKS rejects a second access entry for it. |
| `api_allowed_cidrs` | `[]` | Empty = private API endpoint only. |
| `system_node_instance_type`, `system_node_count` | `t3.medium`, `2` | |
| `proxy_node_colours` | `{ blue = { instance_types = ["m6i.xlarge"], kubernetes_version = "1.37" } }` | One or two colours. Per colour: `instance_types` (x86_64 only), `capacity_type` (`ON_DEMAND`, or `SPOT` with a warning), `nodes_per_az` (default 1), `kubernetes_version` (the cluster's or up to three minor versions older), `ami_release_version` (default: latest at creation, then fixed), `root_volume_gb` (default 50). |

See `stacks/10-infra/variables.tf` for the full list.

## Main inputs (20-platform)

| Variable | Default | Notes |
|---|---|---|
| `infra_state` | (required) | `{ bucket, key, region }` of the `10-infra` state. |
| `lb_controller_chart_version` | `3.6.2` | When changing it, update `modules/platform/lb-controller-iam-policy.json` to the same release's `docs/install/iam_policy.json`, and apply the release's CRDs first: Helm doesn't upgrade the CRDs in the chart's `crds/` directory. |
| `gp3_iops`, `gp3_throughput` | `3000`, `250` | Also the proxy data volumes' performance. Throughput is at most IOPS / 4. |
| `ebs_kms_key_arn`, `log_kms_key_arn` | `null` | Customer-managed keys for volumes and log groups; default AWS-managed encryption. |
| `cloudwatch_addon_version` | `null` | The cluster's default version when first created. If set, v1.7.0 or later. |
| `log_retention_days` | `90` | Container Insights log groups. |
| `external_secrets_chart_version` | `2.14.0` | |
| `secrets_name_prefix` | `stroom-proxy/<name>/` | Secrets Manager prefix the operator may read. |

See `stacks/20-platform/variables.tf` for the full list.

## Tests

Both stacks have plan-only tests that use mocked providers, so they need no
credentials or cluster:

```sh
cd stacks/10-infra    # or stacks/20-platform
terraform init -backend=false
terraform test
```

`10-infra`'s tests check that the default, /20-VPC, blue/green and existing-VPC
configurations plan (including the lb subnet ranges), and that invalid inputs
are rejected:

* an existing VPC without lb subnets, with subnets sharing an AZ, or with lb
  subnets smaller than /27;
* a `name` longer than 29 characters, and duplicate admin ARNs;
* Graviton types, more than two colours, bad colour names, zero nodes per AZ;
* node versions newer than the cluster or more than three minor versions older,
  and an AMI release for another version;
* an open API endpoint and a bad NAT mode.

Spot capacity gives a warning.

`20-platform`'s tests check the controllers' Helm values (region and VPC ID
set, system node selector, ingress class and Service mutator off, pod webhook
failing closed), the gp3 parameters, the log groups' retention and the Pod
Identity associations. They also check that a throughput above IOPS / 4, a
retention value CloudWatch doesn't support, a secrets prefix without a
trailing `/` and a CloudWatch add-on older than 1.7.0 are rejected.

## Upgrades

* **Control plane**: change `cluster_version` by one minor version and apply.
  The control plane, add-ons and system nodes are upgraded in place; system
  nodes are replaced one at a time (`max_unavailable = 1`).
* **System node AMIs** follow the latest EKS AMI release for the cluster
  version, so any `apply` after a new release also rolls the system nodes, one
  at a time. They run only stateless cluster services.
* **Proxy nodes** are never upgraded in place. Add a second colour to
  `proxy_node_colours` with the new `kubernetes_version`, AMI or instance type,
  apply, move the proxy to it (blue/green, in `30-stroom-proxy` once it
  exists), and remove the old colour once its proxies have drained. Proxy nodes
  may lag the control plane by up to three minor versions, so they can catch up
  at the next blue/green. See section 9 of the design.

## Destroy

Destroy the stacks in reverse order: `30-stroom-proxy` (once it exists), then
`20-platform`, then `10-infra`, which removes the cluster and the VPC. EBS volumes holding proxy data are kept
when the proxy is removed (by design), so look for them afterwards. The EBS
CSI driver tags them with their PVC name (`kubernetes.io/created-for/pvc/name`).
