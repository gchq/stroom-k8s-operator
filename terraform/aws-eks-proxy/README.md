# Stroom-Proxy on AWS EKS

Terraform that builds an EKS cluster and runs Stroom-Proxy 7.14 on it,
receiving data over HTTPS on port 443. The design is in
[`design/proxy-eks-terraform-design.md`](../../design/proxy-eks-terraform-design.md).

**Status:** phase 1 (the `10-infra` stack) is written. The platform stack
(`20-platform`), the proxy stack (`30-stroom-proxy`) and the `stroom-proxy`
Helm chart come in later phases.

## Layout

```
terraform/aws-eks-proxy/
├── modules/
│   ├── network/          # VPC, subnets, NAT gateways, optional VPC endpoints (or an existing VPC)
│   └── eks/              # EKS cluster, system and proxy node groups, add-ons
├── stacks/
│   └── 10-infra/         # network + eks, with its own state
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

## Prerequisites

* Terraform 1.10 or later.
* AWS credentials for the target account, with rights to create VPC, EKS, IAM,
  KMS and EC2 resources.
* An S3 bucket for Terraform state (versioned, encrypted, access-restricted).
  State locking uses S3 itself (`use_lockfile`), so no DynamoDB table is needed.
* The AWS CLI and `kubectl`, to check the cluster afterwards.

## Usage

Copy `envs/example` to `envs/<env>`, then edit `backend-10-infra.hcl` (state
bucket and key) and `10-infra.tfvars`.

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

## Main inputs

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

## Tests

The stack has plan-only tests that use a mocked AWS provider, so they need no
credentials:

```sh
cd stacks/10-infra
terraform init -backend=false
terraform test
```

They check that the default, /20-VPC, blue/green and existing-VPC
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

`terraform destroy` in `10-infra` removes the cluster and the VPC. Destroy the
later stacks first, once they exist. EBS volumes holding proxy data are kept
when the proxy is removed (by design), so look for them afterwards. The EBS
CSI driver tags them with their PVC name (`kubernetes.io/created-for/pvc/name`).
