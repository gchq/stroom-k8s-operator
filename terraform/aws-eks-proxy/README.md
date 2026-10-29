# Stroom-Proxy on AWS EKS

Terraform that builds an EKS cluster and runs Stroom-Proxy 7.14 on it,
receiving data over HTTPS on port 443. The design is in
[`design/proxy-eks-terraform-design.md`](../../design/proxy-eks-terraform-design.md).

**Status:** all three stacks are written, with the
[`stroom-proxy` Helm chart](../../charts/stroom-proxy). Nothing has been
applied to AWS yet. Two colours can already run side by side (with test
listeners for the inactive one); canary weights, the queue status script and
the runbooks come in the next phase.

## Layout

```
terraform/aws-eks-proxy/
├── modules/
│   ├── network/          # VPC, subnets, NAT gateways, optional VPC endpoints (or an existing VPC)
│   ├── eks/              # EKS cluster, system and proxy node groups, add-ons
│   ├── platform/         # LB controller, gp3 StorageClass, CloudWatch, External Secrets
│   └── stroom-proxy/     # buckets, ALB, NLBs, PrivateLink, IAM, Kubernetes objects, Helm releases
├── stacks/
│   ├── 10-infra/         # network + eks
│   ├── 20-platform/      # platform, reading 10-infra's outputs from its state
│   └── 30-stroom-proxy/  # the proxy, reading both earlier stacks' outputs
├── envs/
│   ├── example/          # backend config and tfvars for one environment
│   └── dev/              # a small test environment, with an apply and test checklist
└── scripts/
    └── make-test-certs.sh  # throwaway client and server CAs for dev
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

## What `30-stroom-proxy` creates

The proxy and everything in front of and behind it (design sections 5 to 9).

* **Two endpoints**, both HTTPS on 443:
  * `mtls_hostname`: an internal NLB forwarding to the ALB's mTLS listener
    (`:8443`). The ALB verifies client certificates against a trust store built
    from the client CA bundle in S3, and passes the subject DN to the proxy in
    `X-Stroom-Mtls-Subject`. Only created when certificate authentication is
    enabled.
  * `hostname`: an internal NLB forwarding to the ALB's plain listener
    (`:443`), for OIDC tokens and data feed keys. A rule rejects (403) any
    request carrying a DN header, so no one can claim a certificate identity
    here.
* **ALB** (internal, in the lb subnets): ACM certificate for both names,
  X-Forwarded-For removed (a client could otherwise forge its address in the
  receive log), optional WAF and access logs. One target group per colour;
  both listeners forward to the active colour's. While a second colour exists,
  test listeners (`:9443` mTLS, `:9444` plain, reachable from `admin_cidrs`)
  forward to it: without a listener its target group wouldn't health-check
  its pods, so they would never become Ready.
* **PrivateLink** (optional): one VPC endpoint service per NLB, with the
  endpoints' host names as private DNS names.
* **Data bucket**: versioning, Object Lock in COMPLIANCE mode with
  `data_retention_days`, SSE-KMS with its own key (only the lock admins can
  disable or delete it), a bucket policy denying the proxy anything but
  adding objects. New objects are announced on an SQS queue (with a
  dead-letter queue). Terraform never deletes it (`prevent_destroy`).
* **Receipt config bucket**: versioned, for the DFK files (`dfk/`) and the
  client CA bundle (`trust/client-ca.pem`, uploaded from
  `auth.client_ca_bundle_pem`). An existing bucket can be named instead.
* **IAM**: the proxy's Pod Identity role (add objects to the data bucket, read
  the DFK files) and one association per colour's service account.
* **Kubernetes**: the namespace (restricted Pod Security Standard, readiness
  gate injection), a NetworkPolicy allowing traffic to the proxies only from
  the lb subnets, a `SecretStore` and `ExternalSecret` for any secrets (the
  downstream API key, the OIDC client secret), a `TargetGroupBinding` per
  colour, and the `stroom-proxy` Helm release per colour.

Plan-time checks reject inconsistent inputs: token auth without an IdP or a
downstream, a receipt mode that needs a downstream without one, certificate
auth without a CA bundle, more replicas than the colour has nodes, a colour
without nodes, an S3 key template without `${uuid}` or `${receiptId}`, an
image without a digest, and more.

## Prerequisites

* Terraform 1.10 or later.
* AWS credentials for the target account, with rights to create VPC, EKS, IAM,
  KMS and EC2 resources.
* An S3 bucket for Terraform state (versioned, encrypted, access-restricted).
  State locking uses S3 itself (`use_lockfile`), so no DynamoDB table is needed.
* The AWS CLI: `20-platform` and `30-stroom-proxy` use `aws eks get-token`
  to authenticate to the cluster. `30-stroom-proxy` also needs `python3` at
  plan time if `data_bucket_name` names an existing bucket (to check its
  Object Lock settings).
* `kubectl`, to check the cluster afterwards.

## Usage

Copy `envs/example` to `envs/<env>`, then edit the backend files (state bucket
and key) and the tfvars. Apply the stacks in order. For a first test
deployment, `envs/dev/README.md` has the steps and a test checklist.

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
state and must be able to reach the Kubernetes API. The providers get a
fresh token from `aws eks get-token` whenever they connect, so a saved plan
can be applied any time later.

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

### 30-stroom-proxy

Set `infra_state` and `platform_state` in `30-stroom-proxy.tfvars`, the
deployment (image tag and digest from `scripts/latest-proxy-tag.sh` once it
exists), the host names, the certificate source, `allowed_ingress_cidrs`,
`auth` (including the client CA bundle) and `data_retention_days`.

```sh
cd stacks/30-stroom-proxy
terraform init -backend-config=../../envs/<env>/backend-30-stroom-proxy.hcl
terraform plan  -var-file=../../envs/<env>/30-stroom-proxy.tfvars -out=30-stroom-proxy.tfplan
terraform apply 30-stroom-proxy.tfplan
```

The apply waits until the proxies are healthy in their target group. Then
upload the senders' data feed key files to
`s3://<receipt_config_bucket>/dfk/`; each proxy picks them up within
`dfk_sync_interval_seconds`. If `route53_zone_id` isn't set, point the host
names at the NLBs (`endpoints` output). With PrivateLink, accept senders'
endpoint connections and add the private DNS verification TXT records
(`endpoints` output) unless `privatelink.verification_zone_id` does it.

```sh
kubectl -n stroom-proxy get pods -o wide
curl --cert client.pem --key client.key https://<mtls_hostname>/datafeed -H 'Feed: TEST' --data-binary @file
curl -H "Authorization: Bearer <token>" https://<hostname>/datafeed -H 'Feed: TEST' --data-binary @file
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

## Main inputs (30-stroom-proxy)

| Variable | Default | Notes |
|---|---|---|
| `infra_state`, `platform_state` | (required) | Where the earlier stacks' state is. |
| `proxy_deployments`, `active_colour` | (required) | `{ <colour> = { image_tag, image_digest, replicas } }`; the digest is required. |
| `allowed_ingress_cidrs` | (required) | Who may reach the NLBs directly. |
| `admin_cidrs` | `[]` | Who may reach the ALB's test listeners for the inactive colour. |
| `hostname`, `mtls_hostname` | (required) | Non-mTLS and mTLS endpoints. |
| `tls_certificate_source` | `acm_private_ca` | With `private_ca_arn`; or `acm_public` (with `route53_zone_id`), `acm_existing` (with `certificate_arn`) or `acm_imported` (with `imported_certificate`, or `imported_certificate_files` for paths; the key is kept in state, so dev only). |
| `auth` | cert + token + DFK | `types`, `client_ca_bundle_pem`, `dfk_s3_prefix`, `openid`, … (design section 6). `client_ca_bundle_pem_file` reads the bundle from a file. |
| `downstream`, `receipt` | `null`, `RECEIVE_ALL` | Optional downstream Stroom. |
| `privatelink` | off | `enabled`, `allowed_principals`, `acceptance_required`, `verification_zone_id`. |
| `data_retention_days` | (required) | COMPLIANCE retention: can't be shortened. |
| `data_bucket_name`, `receipt_config_bucket` | `null` | Use existing buckets instead of creating them. |
| `forward_s3` | `${type}/${year}/${month}/${day}/${feed}/${uuid}.zip`, multipart | The key template must contain `${uuid}` or `${receiptId}`. |
| `extra_proxy_config` | `{}` | Any other proxy settings, in the proxy's own keys, deep-merged. |

See `stacks/30-stroom-proxy/variables.tf` and `modules/stroom-proxy/variables.tf`.

## Tests

Both stacks have plan-only tests that use mocked providers, so they need no
credentials or cluster:

```sh
cd stacks/10-infra    # or stacks/20-platform, stacks/30-stroom-proxy
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

`30-stroom-proxy`'s tests check the stack's wiring, and, in the module: the
rendered proxy config and Helm values (types preserved, unique S3 keys, a
proxy ID per pod, the ALB's DN header, drain and health settings matching the
target group), the listeners and header-rejection rules, both endpoints or
only the plain one without certificate auth, PrivateLink, secrets, two
colours, an existing data bucket, and every plan-time check above.

The chart's own validation (`hack/validate-stroom-proxy-chart.sh`) also runs
the values this stack renders (`charts/stroom-proxy/ci/terraform-values.yaml`)
through the proxy image's config check.

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

Destroy the stacks in reverse order: `30-stroom-proxy`, then `20-platform`,
then `10-infra`, which removes the cluster and the VPC.

The data bucket and its KMS key are protected (`prevent_destroy`), and AWS
won't delete a bucket that holds locked objects anyway. To destroy
`30-stroom-proxy`, first remove the bucket, its settings and its key from the
state, so Terraform leaves them in place:

```sh
terraform state list \
  | grep -E '^module\.stroom_proxy\.(aws_s3_bucket[a-z_]*\.data|aws_kms_(key|alias)\.data)\[' \
  | xargs terraform state rm
``` EBS volumes holding proxy data are kept
when the proxy is removed (by design), so look for them afterwards. The EBS
CSI driver tags them with their PVC name (`kubernetes.io/created-for/pvc/name`).
