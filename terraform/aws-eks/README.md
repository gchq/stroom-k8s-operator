# Stroom and Stroom-Proxy on AWS EKS

Terraform that builds an EKS cluster and runs Stroom 7.14, Stroom-Proxy 7.14,
or both on it. The proxy receives data over HTTPS on port 443 and writes it to
an S3 bucket; Stroom ingests from that bucket and serves its UI and API behind
an internal ALB. The designs are in
[`design/proxy-eks-terraform-design.md`](../../design/proxy-eks-terraform-design.md)
and
[`design/stroom-eks-terraform-design.md`](../../design/stroom-eks-terraform-design.md).

The same stacks build three deployment shapes (Stroom design section 4.4):

| Shape | Stacks | Settings |
|---|---|---|
| Proxy only | `10-infra`, `20-platform`, `30-stroom-proxy` | `stroom_node_sets = {}` in `10-infra` (the default). |
| Stroom only | `10-infra`, `20-platform`, `40-stroom` | `proxy_node_colours = {}` in `10-infra`; `40-stroom` ingests from a bucket managed elsewhere (`ingest`). |
| Both | all four | Both node maps set in `10-infra`; `40-stroom` ingests from the proxy's bucket (`proxy_state`). |

The Stroom parts of `10-infra` and `20-platform` are created only when
`stroom_node_sets` is set, so a proxy-only cluster is unchanged by them.

**Status:**

* **Stroom-Proxy** (`30-stroom-proxy`, with the
  [`stroom-proxy` Helm chart](../../charts/stroom-proxy)): applied and tested
  in a dev account (`envs/dev`). Two colours can run side by side, with test
  listeners for the inactive one; canary weights, the queue status script and
  the blue/green runbooks are still to come.
* **Stroom** (`40-stroom`, the Stroom parts of `10-infra` and `20-platform`,
  and the operator changes in this repository): written and tested with
  plans, a local kind cluster and Stroom's own config check only. **Not yet
  applied to AWS.**

## Layout

```
terraform/aws-eks/
├── modules/
│   ├── network/          # VPC, subnets, NAT gateways, optional VPC endpoints (or an existing VPC)
│   ├── eks/              # EKS cluster, system, proxy and Stroom node groups, add-ons
│   ├── platform/         # LB controller, gp3 StorageClass, CloudWatch, External Secrets;
│   │                     # with Stroom: cert-manager, trust-manager, in-cluster CA, operator
│   ├── stroom-proxy/     # buckets, ALB, NLBs, PrivateLink, IAM, Kubernetes objects, Helm releases
│   ├── stroom-db/        # RDS for MySQL 8.4 for Stroom
│   └── stroom/           # Stroom: EFS, ALB, IAM, secrets, StroomCluster, init and bootstrap Jobs
├── stacks/
│   ├── 10-infra/         # network + eks
│   ├── 20-platform/      # platform, reading 10-infra's outputs from its state
│   ├── 30-stroom-proxy/  # the proxy, reading both earlier stacks' outputs
│   └── 40-stroom/        # Stroom, reading 10, 20 and (with the proxy) 30
├── envs/
│   ├── example/          # backend config and tfvars for all four stacks
│   └── dev/              # a small proxy-only test environment, with an apply and test checklist
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
  * lb: a /26 per AZ with no NAT route, used only by the ALBs and the
    internal NLBs. The proxy's and Stroom's NetworkPolicies admit load balancer
    traffic from these ranges (`lb_subnet_cidrs` output), so nothing else
    should run in them.

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
* Managed node groups (AL2023, IMDSv2 required with hop limit 1, encrypted
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

    `proxy_node_colours = {}` gives a cluster without Stroom-Proxy.
  * Stroom node groups, only when `stroom_node_sets` is set (for the
    `40-stroom` stack, design
    [`stroom-eks-terraform-design.md`](../../design/stroom-eks-terraform-design.md)
    section 11.2). Each Stroom node set's `node_count` nodes are spread over the
    AZs in order, with a node group for each AZ that gets any
    (`stroom-<set>-az<n>`): 2 nodes in 3 AZs go to az1 and az2. Labelled
    `workload=stroom` and `stroom/node-set=<set>`, tainted
    `workload=stroom:NoSchedule`, on-demand only. Instance types must be x86_64
    with instance-store NVMe (`r6id`, `m6id`, `c6id`, `i4i`, ...): `nodeadm`
    builds a RAID0 array from the NVMe disks for kubelet and containerd, so
    Stroom's `emptyDir` directories land on NVMe. As for proxy colours, the
    Kubernetes version is explicit and the AMI fixed at creation; changing
    `ami_release_version` replaces a group's nodes one at a time, and each
    Stroom pod moves to the new node in its AZ with its EBS volume. Stroom nodes
    own their index shards, so only ever raise `node_count`.
* EKS add-ons: `vpc-cni` (network policy enforcement on), `coredns`,
  `kube-proxy`, `eks-pod-identity-agent`, and `aws-ebs-csi-driver` with a Pod
  Identity role and its node DaemonSet tolerating all taints. With Stroom
  node sets, also `aws-efs-csi-driver` (Stroom's shared stream volume) with a
  Pod Identity role; its node DaemonSet tolerates all taints by default.

At least one of `proxy_node_colours` and `stroom_node_sets` must be set.

## What `20-platform` creates

The cluster services both workloads share, and Stroom's prerequisites. Everything
runs on the system nodes.

* **AWS Load Balancer Controller** (Helm chart 3.6.2, Pod Identity role with
  the controller's published IAM policy). Used only for `TargetGroupBinding`,
  which registers proxy and Stroom pods in the ALB target groups that
  `30-stroom-proxy` and `40-stroom` create, and for injecting pod readiness
  gates. Its ingress class and Service mutator are turned off. Its pod webhook
  is set to fail closed, so a pod is never created without its readiness gate;
  two replicas with a PodDisruptionBudget keep the webhook available.
* **gp3 StorageClass**, the cluster default: encrypted, `WaitForFirstConsumer`
  (so each volume is created in its pod's AZ), expandable, with `gp3_iops` and
  `gp3_throughput`.
* **CloudWatch Observability add-on** (Container Insights metrics, Fluent Bit
  container logs) with a Pod Identity role. Its pods tolerate all taints (add-on
  1.7.0 and later, enforced), so logs are collected from the proxy and Stroom
  nodes too. Terraform creates its four log
  groups (`/aws/containerinsights/<cluster>/{application,dataplane,host,performance}`)
  first, with `log_retention_days`; otherwise logs would be kept forever.
* **External Secrets Operator** (Helm chart 2.14.0, with its CRDs) and a Pod
  Identity role that reads no secrets itself: it may only assume roles named
  `<name>-*`. Each workload stack creates its own role (`<name>-pxeso-*` for
  the proxy, `<name>-steso-*` for Stroom) that reads only that workload's own
  secrets, and a `SecretStore` in its namespace that assumes it. Secrets you
  create yourself (client secrets, the proxy's downstream key) go under
  `secrets_name_prefix`, default `stroom-proxy/<name>/` for both workloads.
  Those stacks create the SecretStores because Terraform can't plan a custom
  resource in the same apply that installs its CRD.

The controllers are given the region and VPC ID explicitly, because the IMDS
hop limit of 1 stops pods reading them from instance metadata.

Only when `10-infra` has Stroom node sets, for `40-stroom`:

* **cert-manager** (chart v1.21.3, with its CRDs, two replicas) and
  **trust-manager** (chart v0.26.0).
* **An in-cluster CA**, from the local chart
  `modules/platform/charts/stroom-internal-ca`: a self-signed root that
  cert-manager keeps in its namespace, the `stroom-internal-ca` ClusterIssuer
  that signs with it, and a trust-manager `Bundle` that writes the CA
  certificate as the ConfigMap `stroom-internal-ca` (key `ca.crt`) into every
  namespace labelled `stroom.gchq.github.io/internal-ca=true`. Stroom's nodes
  serve HTTPS with certificates from it, and Stroom and the proxy trust it. A
  chart, because Terraform can't plan custom resources whose CRDs it installs
  in the same apply.
* **metrics-server** (chart 3.14.0), for the Stroom operator's task
  autoscaler.
* **The Stroom operator** and its CRDs, as two Helm releases. By default from
  this repository's `charts/` directory, as the operator changes the Stroom
  design needs aren't released yet; `stroom_operator` sets a chart repository
  and version instead, and an image (for example a build of this branch in
  ECR).

A proxy-only cluster gets none of these.

## What `30-stroom-proxy` creates

Stroom-Proxy and everything in front of and behind it (proxy design sections 5
to 9). Leave this stack out for a Stroom-only cluster.

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

## What `40-stroom` creates

Stroom on the cluster's Stroom node groups, deployed by the Stroom operator
(design [`stroom-eks-terraform-design.md`](../../design/stroom-eks-terraform-design.md)).
It needs `10-infra` with `stroom_node_sets` and `20-platform` applied after
it. With the proxy in the cluster, it ingests from the proxy's data bucket;
without, from the bucket named in `ingest`. **Written and tested with plans
only; not yet applied.**

* **Database** (`modules/stroom-db`): RDS for MySQL 8.4, Multi-AZ, encrypted
  with its own KMS key, private, TLS required, automated backups, a final
  snapshot and deletion protection. RDS manages the master password in Secrets
  Manager. The Stroom user's password is generated as an ephemeral value and
  written with a write-only argument, so neither password is in Terraform
  state. A database init Job (MySQL client, verified TLS) creates the `stroom`
  and `stats` schemas and the user.
* **Stream volume**: an EFS file system (elastic throughput, KMS, AWS Backup)
  with a mount target per AZ and a uid/gid 1000 access point, bound by a static
  PersistentVolume and mounted on every node at `/stroom/stream`.
* **Namespace** `stroom` with the `restricted` Pod Security level, ALB
  readiness gates and the in-cluster CA's ConfigMap; a NetworkPolicy allowing
  only the ALB, the other Stroom nodes and (with the proxy) the proxy
  namespace to reach 8443, and the ALB and the nodes to reach 8081.
* **Secrets** through External Secrets: the database user's password (in the
  form the operator expects), the RDS master credentials (for the init Job:
  this stack lets the External Secrets role read that one secret), the OIDC
  client secret, and a keystore password generated in the cluster once. The
  nodes' certificate comes from the in-cluster CA (cert-manager), covering
  every node set's Services and pods.
* **IAM** (Pod Identity): Stroom's role reads the data bucket and consumes its
  queue (send to the DLQ, decrypt with its key); the bootstrap Job's role can
  only write the proxy's API key secret.
* **ALB**: internal, HTTPS with an ACM certificate (the same four sources as
  the proxy), HTTP redirected, sticky sessions (`STROOM_SESSION_ID`), HTTPS to
  the Frontend node set's pods with health checks on 8081, and cluster calls
  and `/datafeed` refused with 403. Optional Route 53 alias.
* **The StroomCluster**: node names `<node_name_prefix>-<node set>-<n>`, the
  removal guard on, each node set on its own nodes (one pod per node, spread
  over the AZs, PodDisruptionBudget), uid 1000, temp, reference data and
  search results on NVMe, index volumes on the gp3 data volume, the heap as a
  percentage of the memory limit, verified TLS to RDS, HTTPS between nodes,
  and `EXTERNAL_IDP` with the `entra`, `keycloak` or `cognito` preset.
  Stroom's `config.yml` is rendered from the operator's, adding S3 event
  ingest, the identity provider, HTTPS node URIs and the volume settings; its
  keys are checked with Stroom 7.14's own config check.
* **Bootstrap Job**, once the nodes are up, idempotent: the first
  administrator (by IdP subject), the `stroom-proxy` user and its API key
  (written to Secrets Manager, with the proxy), the `S3_V1_READ_ONLY` volume
  for the data bucket, and the S3 event poll job. Stroom creates the stream and
  index volumes itself, from `config.yml`.

Plan-time checks refuse: raw data retention longer than the bucket's expiry, a
node set without node groups in `10-infra` or with more pods than nodes, a
cluster without Stroom's platform components, and a Stroom-only cluster
without an `ingest` bucket.

With the proxy, the first build applies `30-stroom-proxy` twice (see
[Usage](#40-stroom)).

## Prerequisites

* Terraform 1.10 or later.
* AWS credentials for the target account, with rights to create VPC, EKS, IAM,
  KMS and EC2 resources.
* An S3 bucket for Terraform state (versioned, encrypted, access-restricted).
  State locking uses S3 itself (`use_lockfile`), so no DynamoDB table is needed.
* The AWS CLI v2: `20-platform`, `30-stroom-proxy` and `40-stroom` use
  `aws eks get-token` to authenticate to the cluster, and `10-infra` uses
  `aws eks update-nodegroup-config` to resize node groups. `30-stroom-proxy`
  also needs `python3` at plan time if `data_bucket_name` names an existing
  bucket (to check its Object Lock settings).
* `kubectl`, to check the cluster afterwards.
* For Stroom: an app registration in the identity provider (Entra ID,
  Keycloak or Cognito), with its client secret in Secrets Manager under
  `20-platform`'s `secrets_name_prefix`, and the Stroom operator's image (until
  the operator changes here are released, a build of this branch, for example
  in ECR).

## Usage

Copy `envs/example` to `envs/<env>`, drop the files for any stack your shape
leaves out, then edit the backend files (state bucket and key) and the tfvars.
Apply the stacks in order: `10-infra`, `20-platform`, then `30-stroom-proxy`
and/or `40-stroom`. For a first proxy test deployment, `envs/dev/README.md`
has the steps and a test checklist.

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

You should see the system nodes, one proxy node per AZ for each colour and
each Stroom node set's nodes (`kubectl get nodes -L stroom/node-set`), with
CoreDNS and the EBS CSI controller running on the system nodes.

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
kubectl get pods -n amazon-cloudwatch -o wide   # fluent-bit on every node, proxy and Stroom nodes included
kubectl get storageclass                        # gp3 (default)
```

With Stroom node sets, also:

```sh
kubectl get pods -n cert-manager                # cert-manager, trust-manager
kubectl get clusterissuer stroom-internal-ca    # Ready
kubectl get deploy -A | grep -E 'metrics-server|stroom-operator'
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

### 40-stroom

Not yet applied to AWS: expect to find problems on the first real apply.

Register the redirect URI `https://<hostname>/api/auth/flow/v1/signin-oidc`
with the identity provider, and put its client secret in Secrets Manager under
`20-platform`'s `secrets_name_prefix`. Then set, in `40-stroom.tfvars`:
`infra_state`, `platform_state`, and `proxy_state` (with the proxy) or
`ingest` (without); `node_name_prefix`, `stroom_image` and `node_sets`
(matching `10-infra`'s `stroom_node_sets`); `database`; `idp`, including the
first administrator's subject; `raw_data_retention_days`; and the host name,
certificate source and `allowed_ingress_cidrs`.

```sh
cd stacks/40-stroom
terraform init -backend-config=../../envs/<env>/backend-40-stroom.hcl
terraform plan  -var-file=../../envs/<env>/40-stroom.tfvars -out=40-stroom.tfplan
terraform apply 40-stroom.tfplan
```

The first apply takes longest: RDS, then the database init Job, then the
nodes' first start (database migrations; the apply waits up to an hour), then
the bootstrap Job (first administrator, the proxy's user and API key, the S3
volume and the S3 event poll job). If `route53_zone_id` isn't set, point the
host name at the ALB (`alb_dns_name` output).

```sh
kubectl -n stroom get stroomcluster,pods -o wide
kubectl -n stroom get jobs                     # database init and bootstrap: Complete
```

Then sign in at the `url` output as the first administrator.

With the proxy, apply `30-stroom-proxy` again (design 4.3): set its
`downstream` from this stack's `proxy_downstream` output and
`receipt.check_mode = "RECEIPT_POLICY"`. The proxy must also trust the
in-cluster CA, which needs a proxy chart change (not done yet).

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
| `proxy_node_colours` | `{ blue = { instance_types = ["m6i.xlarge"], kubernetes_version = "1.37" } }` | None (no proxy), one, or two colours. Per colour: `instance_types` (x86_64 only), `capacity_type` (`ON_DEMAND`, or `SPOT` with a warning), `nodes_per_az` (default 1), `kubernetes_version` (the cluster's or up to three minor versions older), `ami_release_version` (default: latest at creation, then fixed), `root_volume_gb` (default 50). |
| `stroom_node_sets` | `{}` | Stroom node groups, keyed by Stroom node set (`proc`, `ui`). Per set: `instance_types` (x86_64 with instance-store NVMe), `node_count` (spread over the AZs; only raise it), `kubernetes_version`, `ami_release_version`, `root_volume_gb` (default 50). |

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
| `cert_manager_chart_version`, `trust_manager_chart_version`, `metrics_server_chart_version` | `v1.21.3`, `v0.26.0`, `3.14.0` | Installed only with Stroom node sets. |
| `stroom_operator` | this repository's charts, `gchq/stroom-k8s-operator` | `{ chart_repository, chart_version, image_repository, image_tag }`. Installed only with Stroom node sets. |

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

## Main inputs (40-stroom)

| Variable | Default | Notes |
|---|---|---|
| `infra_state`, `platform_state` | (required) | Where the earlier stacks' state is. |
| `proxy_state`, `ingest` | `null`, `{}` | With the proxy, its state (Stroom ingests from its bucket). Without, `ingest`: the bucket, its queue and DLQ, KMS key and expiry, managed elsewhere (design 4.4). |
| `node_name_prefix` | (required) | Node names are `<prefix>-<node set>-<n>`. Permanent, as are node set names. |
| `stroom_image` | (required) | `{ repository, tag, digest }`; the digest is recommended. |
| `node_sets` | (required) | Keyed as `10-infra`'s `stroom_node_sets`, one pod per node. Per set: `count`, `role` (`Processing`, `Frontend`, ...), `cpu`, `memory_gib`, `heap_gib`, `data_volume_gb` (gp3, index shards), `nvme` sizes. Counts only go up. |
| `stopped` | `false` | Stops every node, keeping the counts, for a version upgrade (design section 12). |
| `database` | Multi-AZ `db.r6g.large`, 200 GB | RDS for MySQL 8.4. `app_user_password_version` rotates the Stroom user's password. |
| `stream_volume` | EFS, elastic, backed up | The shared stream volume. |
| `idp` | (required) | `type` (`entra`, `keycloak`, `cognito`), `tenant_id` or `discovery_url`, `client_id`, `client_secret_name`, `first_admin`. |
| `raw_data_retention_days` | (required) | Must be less than the data bucket's expiry. |
| `proxy_api_key_secret_name` | `stroom-proxy-api-key` | Where the bootstrap Job writes the proxy's API key. With the proxy only. |
| `hostname`, `allowed_ingress_cidrs` | (required) | The UI and API's host name, and who may reach its ALB. |
| `tls_certificate_source` | `acm_private_ca` | As for the proxy. |

See `stacks/40-stroom/variables.tf`, `modules/stroom/variables.tf` and
`modules/stroom-db/variables.tf`.

## Tests

The stacks have plan-only tests that use mocked providers, so they need no
credentials or cluster:

```sh
cd stacks/10-infra    # or 20-platform, 30-stroom-proxy, 40-stroom
terraform init -backend=false
terraform test
```

If the stack's `.terraform` was initialised with the real backend, run the
tests with another data directory (`TF_DATA_DIR=/tmp/tf-test terraform init
-backend=false && TF_DATA_DIR=/tmp/tf-test terraform test`): `init
-backend=false` still reads the saved backend and needs credentials.

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

Its Stroom tests (`tests/stroom.tftest.hcl`) plan the three deployment shapes
(proxy only, Stroom only, both), check how a node set's nodes are spread over
the AZs and that the EFS CSI driver comes only with Stroom, and reject a
cluster with neither, instance types without instance-store NVMe, Graviton
types, bad node set names, zero nodes and node versions newer than the
cluster.

`20-platform`'s tests check the controllers' Helm values (region and VPC ID
set, system node selector, ingress class and Service mutator off, pod webhook
failing closed), the gp3 parameters, the log groups' retention and the Pod
Identity associations. They also check that a throughput above IOPS / 4, a
retention value CloudWatch doesn't support, a secrets prefix without a
trailing `/` and a CloudWatch add-on older than 1.7.0 are rejected. Its Stroom
tests check that a proxy-only cluster (including a `10-infra` state from
before Stroom) gets none of Stroom's components, and a cluster with Stroom
node sets gets them all, on the system nodes, with the operator from this
repository's charts or from a given repository and image.

`40-stroom`'s tests check the stack's wiring (with the proxy, Stroom only
with and without an `ingest` bucket, a cluster without Stroom's components),
and in the modules: the rendered `config.yml` (S3 ingest, the Entra and
Keycloak presets, HTTPS cluster calls trusting the in-cluster CA for that
client only, volume paths, Stroom's own placeholders kept), the StroomCluster
(node sets, heap percentages, placement, image digest, database TLS, HTTPS,
volumes), the ALB's stickiness and refusals, the database settings, and every
plan-time check. `stroom_cluster_manifest` (a module output) can be checked
against the operator's CRDs with `kubectl apply --dry-run=server
--validate=strict`.

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
  apply, move the proxy to it (blue/green, `active_colour` in
  `30-stroom-proxy`), and remove the old colour once its proxies have drained.
  Proxy nodes may lag the control plane by up to three minor versions, so they
  can catch up at the next blue/green. See section 9 of the proxy design.
* **Stroom nodes** keep their index shards, so they are replaced one AZ group
  at a time with `stroom_node_sets.<set>.az_overrides`, each Stroom pod moving
  to the new node in its AZ with its EBS volume (Stroom design section 18).
  They may also lag the control plane by up to three minor versions.
* **Stroom version**: set `stopped = true` in `40-stroom` and apply, change
  `stroom_image`, then set `stopped = false` and apply (Stroom design section
  12).

### After the 2026-10-30 audit

* **External Secrets isolation, one-time order:** apply `20-platform` first
  (its External Secrets controller then reads no secrets itself and may only
  assume roles named `<cluster>-*`), then `30-stroom-proxy` and `40-stroom`
  straight after, which create their own roles (`<name>-pxeso-*`,
  `<name>-steso-*`) and point their SecretStores at them. In between, synced
  Secrets keep working but refreshes fail with AccessDenied. `20-platform`
  needs `terraform init` first, for the new `hashicorp/time` provider.
* **Lock admins:** list every identity that will run `30-stroom-proxy` (CI,
  break-glass) in `admin_principal_arns`. Only they can now change the data
  key's and bucket's policies; KMS has no root override.
* **Node counts** (`nodes_per_az`, `system_node_count`, Stroom `node_count`)
  change in one apply: Terraform gives the node group module each group's
  current size and then runs `aws eks update-nodegroup-config` (min = max =
  desired), so the machine running Terraform needs the AWS CLI v2 with the same
  credentials. A failed resize is retried on the next apply. Proxy counts may
  go down; Stroom counts only up.
* **AZs and subnets:** node groups are keyed by subnet position. After the
  first apply, set `azs` to the `availability_zones` output, and never reorder
  or remove entries (only append). The plan refuses a node group moving subnet,
  a Stroom group shrinking, or a Stroom set losing an AZ group.
* **Stroom node AMI, version or instance type:** one AZ group at a time with
  `stroom_node_sets.<set>.az_overrides` (design section 18), never the
  set-level value directly on a running cluster.
* **Stroom operator image:** with this repository's operator charts (the
  default), `20-platform` requires `stroom_operator.image_repository` and
  `image_tag`, an image built from the same commit.
* **In-cluster CA rotation, Stroom certificate renewal, database password and
  proxy key rotation:** runbooks in the Stroom design, section 18.

## Destroy

Destroy the stacks in reverse order, skipping any your shape doesn't have:
`40-stroom`, then `30-stroom-proxy`, then `20-platform`, then `10-infra`,
which removes the cluster and the VPC.
`40-stroom` must go before `20-platform`: the StroomCluster has a finalizer
that only the operator (installed by `20-platform`) removes, after draining
the nodes, so destroying the operator first leaves `40-stroom`'s destroy
waiting forever.

`40-stroom` keeps some things, deliberately:

* The EFS file system (Stroom's written streams) is protected
  (`prevent_destroy`). Remove it from the state first, as for the data bucket
  below, and delete it yourself once its data isn't needed:
  `terraform state rm module.stroom.aws_efs_file_system.stream`.
* The database has deletion protection and takes a final snapshot. Set
  `database.deletion_protection = false` and apply before destroying; the
  final snapshot (`<name>-stroom-final`) stays until you delete it.
* The nodes' EBS data volumes (index shards) belong to PersistentVolumeClaims
  the operator keeps (`volumeClaimDeletePolicy` isn't set). Delete the PVCs in the
  `stroom` namespace if the data isn't needed, before destroying `10-infra`.

The data bucket and its KMS key are protected (`prevent_destroy`), and AWS
won't delete a bucket that holds locked objects anyway. To destroy
`30-stroom-proxy`, first remove the bucket, its settings and its key from the
state, so Terraform leaves them in place:

```sh
terraform state list \
  | grep -E '^module\.stroom_proxy\.(aws_s3_bucket[a-z_]*\.data|aws_kms_(key|alias)\.data)\[' \
  | xargs terraform state rm
```

The bucket keeps its event notification, which then points at the deleted
SQS queue. That does no harm once nothing writes to the bucket.

The receipt config bucket isn't protected, but it is versioned and Terraform
won't delete it while it holds objects: delete every object version and
delete marker first (the S3 console's **Empty** does this).

Once the last object's retention has passed, empty and delete the data bucket
yourself (the console's **Empty**, then **Delete**), then schedule its KMS
key's deletion (7 days at the least):

```sh
aws kms schedule-key-deletion --key-id <data bucket key id> --pending-window-in-days 7
```

Proxy data volumes: removing a colour keeps its PVCs and EBS volumes (by
design, section 9.2 of the design); destroying `30-stroom-proxy` deletes the
namespace, and with it the remaining PVCs and their volumes. To check for
leftovers, the EBS CSI driver tags volumes with their PVC name
(`kubernetes.io/created-for/pvc/name`).
