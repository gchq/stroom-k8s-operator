# Stroom-Proxy 7.14 on AWS EKS with Terraform: design

Status: design agreed 2026-10-29 and revised the same day after review comments (PrivateLink, authentication, immutable S3, blue/green upgrades, log sender). See section 15. Phase 1 (`10-infra`, with per-colour proxy node groups) is written but not yet applied to AWS. Later phases are not written.

## 1. Goal

Terraform that takes an empty AWS account (or an existing VPC) and produces:

* an EKS cluster whose proxy nodes' EC2 instance type and count are inputs;
* Stroom-Proxy 7.14 (image `gchq/stroom-proxy` from Docker Hub) with a configurable number of pods;
* an HTTPS endpoint on port 443 that accepts data (`/datafeed`, `/stroom/datafeed`), reachable directly (VPC, peering, VPN, Direct Connect) and through AWS PrivateLink;
* sender authentication by client certificate (mTLS), OpenID Connect token or data feed key (DFK), with the DFKs and the mTLS trust-store PEM pulled from S3;
* forwarding to an S3 bucket in which objects can't be changed or deleted once the proxy has written them;
* upgrades without downtime: blue/green for the proxy and its nodes, with proper draining whenever a receiving pod stops.

Out of scope for the first version: Stroom itself, multi-region, and autoscaling the pod count from load.

## 2. Findings that shape the design

These came from the 7.14 source, Docker Hub and the public Helm charts. Each one changes a decision below.

| # | Finding | Consequence |
|---|---------|-------------|
| F1 | There is no 7.14 GA release yet. The newest tag is `v7.14-beta.8` (16 Oct 2026). The floating tag `v7.14-LATEST` has the same digest as `v7.14-beta.8-parallel-pathways`, a branch build, not `v7.14-beta.8`. | Never deploy a floating tag. Terraform pins an explicit tag plus digest (`image_tag`, `image_digest`). A helper script finds the newest `v7.14.N` / `v7.14-beta.N` tag. |
| F2 | The `gchq/stroom-proxy` image is published for `amd64` only. | Graviton (`*g` families such as `m7g`, `c7g`) cannot be used. A variable validation rejects them. |
| F3 | The only existing stroom-proxy Helm chart is `gradata-systems/stroom-helm-charts` → `charts/stroom-proxy` (chart 1.2.13, appVersion `v7.10.5`, last pushed 31 Mar 2026; formerly `p-kimberley/stroom-kubernetes`). `gchq/stroom-k8s-operator` (a fork of `gradata-systems/stroom-k8s-operator`) has only the operator and CRD charts, and its custom resources cover Stroom clusters, databases, backups and task autoscaling, not Stroom-Proxy. There is no `gchq/stroom-k8s` repo. | The gradata chart (Apache 2.0) is copied into `gchq/stroom-k8s-operator` as `charts/stroom-proxy` and updated there for 7.14 (section 10). The Terraform lives in the same repo. |
| F4 | That chart does not boot 7.14 as written: it always renders `proxyConfig.feedStatus.enabled` and `.apiKey`, which no longer exist in 7.14 (`feedStatus` only has `url` and `feedStatusCache`; the API key moved to `downstreamHost.apiKey`). Proxy enables `FAIL_ON_UNKNOWN_PROPERTIES` (`App.java:147`), so unknown keys stop start-up. It also has no values for `enabledAuthenticationTypes`, `receiptCheckMode`, `downstreamHost`, data feed identities, OpenID or S3 forwarding. | The chart needs a 7.14 update (section 10). |
| F5 | The proxy reads `receive.x509CertificateHeader` as a servlet request attribute, not as a PEM string in an HTTP header (`CertificateExtractorImpl.extractCertificate`). Only the DN header (`x509CertificateDnHeader`) works when a load balancer ends TLS. | TLS must pass through the load balancer to the pod, so Jetty sees the real client certificate (section 5). |
| F6 | `allowedCertificateProviders` accepts IP addresses or host names, not CIDR ranges. ALB node IPs change. | Another reason not to end TLS at an ALB. |
| F7 | S3 forwarding and SQS ingest use the AWS SDK default credential chain (`AwsCredentialsHelper`). | EKS Pod Identity works with no proxy changes. |
| F8 | The gradata chart's log-sender sidecar runs as root with `privileged: true`. | Don't use it. A non-root log-sender already exists on a branch (section 17.2). |
| F9 | ingress-nginx, which the chart's Ingress template assumes, was retired by Kubernetes SIG Network in March 2026. | Don't use the chart's Ingress. |
| F10 | The proxy watches `receive.dataFeedIdentitiesDir` with a Java `WatchService` (`DataFeedIdentitiesDirWatcher`). It loads every `*.json` regular file at start, reloads a file when it is created or modified, and drops that file's keys when it is deleted. | DFKs synced from S3 into that directory take effect without a restart. Files must be written atomically (temporary name not ending `.json`, then rename) so a half-written file is never parsed (section 7.2). |
| F11 | The S3 forwarder (`ForwardS3DestinationImpl`, `S3ClientHelper`) only calls `PutObject`, with object tags (`Feed`, stream type) and optional multipart upload through the transfer manager. It never deletes or overwrites deliberately, and it doesn't send `If-None-Match`. It uses AWS SDK 2.54, which sends a checksum on every upload by default. | An Object Lock bucket works with it: Object Lock needs a checksum or `Content-MD5` on each put, and the SDK sends one. The proxy's IAM role needs only `s3:PutObject`, `s3:PutObjectTagging` and the multipart actions. A bucket policy can't require `If-None-Match`, so object keys must be unique (section 7.1). |
| F12 | Dropwizard 5 (`HttpConnectorFactory`) supports `useProxyProtocol` on a connector, using Jetty's `ProxyConnectionFactory`. | The NLB can send PROXY protocol v2, so the proxy logs the real sender address even for PrivateLink traffic, where the NLB can't preserve the client IP (section 5.2). |
| F13 | The proxy doesn't include Dropwizard's SSL reload bundle, so the trust store and server certificate are only read at start-up. | A trust-store PEM change needs a pod restart, done as a drained rolling restart (section 9.4). |

## 3. Architecture

```
  Senders on the private network         Senders in other VPCs / accounts
  (VPC, peering, VPN, Direct Connect)    (interface endpoint in their VPC)
                 │ TCP 443                              │ TCP 443
                 │                     ┌────────────────▼───────────────┐
                 │                     │ VPC endpoint service           │
                 │                     │ (PrivateLink, allowed          │
                 │                     │  principals, acceptance)       │
                 │                     └────────────────┬───────────────┘
           ┌─────▼──────────────────────────────────────▼──────┐
 Route 53 ►│ NLB (Terraform-owned, internal by default)        │
 proxy.…   │ :443  → target group of the ACTIVE colour         │
           │ :9443 → target group of the INACTIVE colour       │  test listener,
           │         (admin_cidrs only, during an upgrade)     │  admin only
           │ TCP passthrough, PROXY protocol v2 to the pods    │
           └────────┬──────────────────────────────┬───────────┘
                    │ TargetGroupBinding (blue)     │ TargetGroupBinding (green)
  ┌──── VPC (3 AZs, private subnets) ─────────────────────────────────────────────┐
  │  blue proxy nodes (1 group per AZ)  green nodes (during an upgrade)           │
  │  ┌───────────┐┌───────────┐┌───────────┐   ┌─────────┐┌─────────┐┌─────────┐  │
  │  │proxy-b-0  ││proxy-b-1  ││proxy-b-2  │   │proxy-g-0││proxy-g-1││proxy-g-2│  │
  │  │:8443 PROXY││  ...      ││  ...      │   │  ...    ││  ...    ││  ...    │  │
  │  │:8444 local││           ││           │   └─────────┘└─────────┘└─────────┘  │
  │  │:8090 admin││           ││           │                                      │
  │  │+ s3-sync  ││           ││           │   system nodes: CoreDNS, LB          │
  │  │+ log-sndr*││           ││           │   controller, cert-manager, ESO,     │
  │  │EBS gp3 PVC││EBS gp3 PVC││EBS gp3 PVC│   EBS CSI controller, CloudWatch     │
  │  └─────┬─────┘└─────┬─────┘└─────┬─────┘                                      │
  │        │ PutObject  │            ▲ GetObject (DFKs, trust-store PEM)          │
  │        └─────┬──────┘            │                                            │
  └──────────────┼───────────────────┼────────────────────────────────────────────┘
                 ▼                   │
   ┌────────────────────────────┐ ┌──┴──────────────────────────┐
   │ data bucket: versioning +  │ │ receipt config bucket:      │
   │ Object Lock COMPLIANCE     │ │ dfk/*.json                  │
   │ (→ optional SQS notifi-    │ │ trust/client-ca.pem         │
   │    cations for Stroom)     │ └─────────────────────────────┘
   └────────────────────────────┘

   * log-sender: wired in, disabled until a released image exists (section 17.2)
```

## 4. Terraform layout

There are **three root stacks with separate state**:

* The `helm` and `kubernetes` providers can't be configured from a cluster created in the same apply without fragile `depends_on` tricks, so the cluster has its own stack.
* `kubernetes_manifest` resources for custom resources (`Certificate`, `ExternalSecret`, `TargetGroupBinding`) fail at plan time if their CRDs aren't installed yet. So the operators that install the CRDs (`20-platform`) are applied before anything that uses them (`30-stroom-proxy`).
* A cluster rebuild shouldn't force workload churn, and the other way round.

```
stroom-k8s-operator/terraform/aws-eks-proxy/   # in gchq/stroom-k8s-operator, next to charts/stroom-proxy
├── README.md
├── scripts/
│   ├── latest-proxy-tag.sh            # finds newest v7.14 tag + digest on Docker Hub (F1)
│   └── proxy-queue-status.sh          # reports unsent data per pod of a colour (section 9.2)
├── modules/
│   ├── network/                       # wraps terraform-aws-modules/vpc
│   ├── eks/                           # wraps terraform-aws-modules/eks (cluster, node groups, add-ons, access entries)
│   ├── platform/                      # LB controller, gp3 StorageClass, cert-manager, external-secrets, CloudWatch
│   └── stroom-proxy/                  # buckets, NLB, PrivateLink, namespace, IAM pod identity, helm_release per colour
├── stacks/
│   ├── 10-infra/                      # network + eks   → outputs cluster name/endpoint/VPC ids/node colours
│   ├── 20-platform/                   # cluster operators and their CRDs (reads 10-infra outputs)
│   └── 30-stroom-proxy/               # the proxy and its AWS resources (reads 10-infra and 20-platform outputs)
├── envs/
│   └── example/                       # backend config and tfvars per stack
└── examples/
    ├── internal-default.tfvars        # cert + OIDC + DFK, S3 forwarding, PrivateLink off
    └── internal-privatelink.tfvars
```

* State: S3 backend with native S3 locking (`use_lockfile = true`), one state key per stack per environment. A small `bootstrap/` stack, or a manual step, creates the bucket.
* Providers: `aws` ~> 6.x, `helm` ~> 3.x, `kubernetes` ~> 2.x. Pin community modules to exact minor versions.
* Environments: a directory of tfvars per environment (`envs/dev`, `envs/prod`) rather than workspaces, so state keys and backends are explicit.

### 4.1 `10-infra`

* **network**: a new VPC across 3 AZs with public and private subnets. NAT gateways: `single` (cheap) or `one_per_az` (resilient). Optional VPC endpoints for S3, ECR, STS and CloudWatch Logs. Or set `existing_vpc_id` and subnet ids to skip VPC creation.
* **eks**: the cluster version is a variable (default: newest EKS standard-support version, 1.37 today). Use access entries (`API` auth mode) and give the cluster creator admin plus a list of `admin_principal_arns`. The API endpoint is private, plus a public endpoint only if `api_allowed_cidrs` is set. Logging control-plane events to CloudWatch is optional. KMS envelope encryption of Secrets is on.
* **Managed node groups** (AL2023 AMI, IMDSv2 required with hop limit 1):
  * **system**: untainted. It runs CoreDNS, the LB controller, cert-manager, External Secrets, the EBS CSI controller and the CloudWatch agent. `system_node_instance_type` (default `t3.medium`) and `system_node_count` (default 2). Updated in place by managed node group rolling updates, since nothing on it holds data.
  * **proxy, one set per colour**: `proxy_node_colours` is a map keyed by colour (`blue`, `green`). Each colour gets **one node group per AZ**, so every AZ that holds a proxy volume always has a node, and an upgrade never depends on the autoscaling group balancing AZs. Each colour sets:
    * `instance_types` (validated: no Graviton, F2), `capacity_type` (`ON_DEMAND` by default; `SPOT` allowed with a warning);
    * `nodes_per_az`;
    * `kubernetes_version` (explicit, the cluster's or up to three minor versions older, so a control-plane upgrade doesn't roll proxy nodes) and `ami_release_version` (the latest when the colour is created unless pinned, then never changed: the module's automatic latest-AMI updates are off for proxy nodes). Node upgrades come from a new colour (section 9);
    * `root_volume_gb`.

    Nodes are labelled `workload=stroom-proxy` and `stroom-proxy/colour=<colour>`, and tainted `workload=stroom-proxy:NoSchedule`.

  DaemonSets that must run on every node (VPC CNI, kube-proxy, EBS CSI node, Pod Identity agent, Fluent Bit) tolerate all taints by default or are configured to.
* **Add-ons** (EKS managed): `vpc-cni` (with `enableNetworkPolicy: true`, needed for the NetworkPolicy in section 14), `coredns`, `kube-proxy`, `aws-ebs-csi-driver` (with a Pod Identity role) and `eks-pod-identity-agent`.

### 4.2 `20-platform`

All of these run on the system node group:

* the AWS Load Balancer Controller (Helm chart, Pod Identity role). It is used only for its `TargetGroupBinding` resource, which registers proxy pod IPs in Terraform-owned target groups (section 5);
* a `gp3` StorageClass (`WaitForFirstConsumer`, encrypted, `iops` and `throughput` from variables, `allowVolumeExpansion: true`), set as the default;
* the `amazon-cloudwatch-observability` add-on (Fluent Bit container logs, Container Insights);
* External Secrets Operator, with a `ClusterSecretStore` for Secrets Manager (section 11);
* cert-manager with a `ClusterIssuer`, when `tls_certificate_source` is `cert_manager_acme` (Route 53 DNS-01) or `cert_manager_private_ca` (`aws-privateca-issuer`).

external-dns is no longer needed: Terraform owns the NLB, so it creates the Route 53 record directly.

### 4.3 `30-stroom-proxy`

* **S3**: the data bucket (versioning, Object Lock, SSE-KMS, bucket policy) and, unless an existing one is given, the receipt config bucket (section 7).
* **NLB**: the load balancer, its security group, a target group per colour, the `:443` listener pointing at the active colour, the `:9443` test listener pointing at the inactive colour, and the Route 53 alias record (section 5).
* **PrivateLink**: the VPC endpoint service on the NLB, when enabled (section 5.3).
* **Kubernetes**: the namespace (`restricted` Pod Security label, `elbv2.k8s.aws/pod-readiness-gate-inject: enabled`), `ExternalSecret` objects, the server `Certificate`, the NetworkPolicy, and a `TargetGroupBinding` per colour.
* **IAM**: the proxy's Pod Identity role and association.
* **Helm**: a `helm_release` per colour (`stroom-proxy-blue`, `stroom-proxy-green`), with values rendered from Terraform variables (section 13). There is no hand-edited values file.

## 5. Ingress on 443, TLS and PrivateLink

### 5.1 NLB with TLS passthrough

TLS ends in Jetty, in the pod, so the proxy sees the real client certificate (F5) and every authentication type works. An ALB can't do this, so ALB options (and with them AWS WAF and ACM certificates) are out (section 17.4).

**Terraform owns the NLB**, rather than the LB controller creating it from a `Service` of type `LoadBalancer`:

* blue/green needs two target groups and a listener that Terraform switches between them (section 9);
* the VPC endpoint service, the Route 53 record and the security groups need the NLB's ARN and DNS name at plan time;
* `terraform destroy` removes the NLB cleanly, with no controller-created resources left behind.

The LB controller's `TargetGroupBinding` keeps each colour's target group in step with that colour's pods (IP targets), and manages the node security group rules from the NLB's security group.

| Setting | Value |
|---|---|
| Scheme | `load_balancer_scheme`, default `internal`. `internet-facing` is opt-in and requires `allowed_ingress_cidrs` without `0.0.0.0/0`. |
| Subnets | Private subnets (internal) or public subnets (internet-facing), one per AZ. For an internal NLB, `subnet_mapping` pins its private IP in each subnet (a fixed host address per subnet CIDR). For an internet-facing NLB, its private IPs are read from its network interfaces. Either way, the NLB's private IPs are known to Terraform and used by the NetworkPolicy (section 5.2). |
| Security group | 443 from `allowed_ingress_cidrs`; 9443 from `admin_cidrs`. `enforce_security_group_inbound_rules_on_private_link_traffic = off`, because PrivateLink access is controlled by the endpoint service (section 5.3). |
| Listener `:443` | TCP, forwards to the active colour's target group. |
| Listener `:9443` | TCP, forwards to the inactive colour's target group. Only present while two colours exist. |
| Target groups | One per colour. TCP, `target_type = ip`, port 8443, PROXY protocol v2 on, client IP preservation off, `deregistration_delay` from a variable (default 120 s), cross-zone load balancing on. |
| Health check | HTTP on the admin port 8090, path `/proxyAdmin/filteredhealthcheck?deny=stroom.proxy.app.handler.RemoteFeedStatusService`. A TCP check on 8443 would pass while the proxy is unhealthy. |

**Server certificate sources** (`tls_certificate_source`):

* `cert_manager_private_ca`: AWS Private CA, for internal endpoints (the default).
* `cert_manager_acme`: Let's Encrypt through Route 53 DNS-01, for internet-facing endpoints.
* `existing_secret`: the name of a `kubernetes.io/tls` Secret supplied out of band.
* `secrets_manager`: a PEM certificate, key and chain in Secrets Manager, synced through External Secrets.

The certificate must cover `hostname`, which is also the PrivateLink private DNS name when that is used.

**DNS**: `hostname` is required. If `route53_zone_id` is set, Terraform creates an alias record to the NLB.

### 5.2 Sender addresses: PROXY protocol v2

PrivateLink traffic reaches the targets with the NLB's own address as the source, whatever the client IP preservation setting. So the target groups use **PROXY protocol v2** instead, and the proxy's 8443 connector sets `useProxyProtocol: true` (F12). Jetty then reports the sender's address as the remote address for direct and PrivateLink traffic alike, and the receive log records it. For PrivateLink, that is the sender's private address in its own VPC.

Consequences:

* Sender CIDR restrictions are enforced on the NLB security group, not on the pods.
* Anything that can reach 8443 directly could send a forged PROXY header and so a false sender address. The VPC CIDR is not narrow enough, because with the VPC CNI every pod and node has a VPC address. So the NetworkPolicy allows 8443 (and the 8090 health check) **only from the NLB's private IPs**, as /32s (section 14).
* In-pod callers that don't send a PROXY header, such as the log-sender, use a second connector, **8444**, with the same TLS and authentication but no PROXY protocol. It is not exposed through the Service or the NetworkPolicy.

### 5.3 PrivateLink

When `privatelink.enabled`, Terraform creates an `aws_vpc_endpoint_service` on the NLB:

* `allowed_principals`: account, role or organisation ARNs that may create endpoints;
* `acceptance_required` (default `true`): each new endpoint connection is accepted by an operator;
* `private_dns_name` (default `hostname`): senders use the same host name as everyone else, so the server certificate matches. AWS requires a TXT record in the domain's public DNS to verify ownership. Terraform outputs it, and creates it if `privatelink.verification_zone_id` names a public Route 53 zone.

Senders create an interface endpoint in their VPC, in subnets whose **AZ IDs** match the NLB's (AZ names differ between accounts). PrivateLink traffic goes through the same listeners and target groups, so blue/green switching applies to it too.

## 6. Authentication and receipt options

Default: **mTLS, OpenID Connect tokens and data feed keys are all enabled**, and a sender may use any one of them. `client_cert_mode = "want"`, so senders without a certificate can still complete the TLS handshake and authenticate with a token or a DFK.

The variables map onto 7.14 `proxyConfig.receive`, `downstreamHost` and `security`:

| Variable | Proxy config | Notes |
|---|---|---|
| `auth.required` (bool, default `true`) | `receive.authenticationRequired` | `false` = anonymous receipt. Allowed only with `allowed_ingress_cidrs` not containing `0.0.0.0/0`. |
| `auth.types` (default `["CERTIFICATE", "TOKEN", "DATA_FEED_KEY"]`; also `CERTIFICATE_IDENTITY`) | `receive.enabledAuthenticationTypes` | Validated against the enum. |
| `auth.client_cert_mode` (`want`, `need`) | Jetty `wantClientAuth` / `needClientAuth` | `need` refuses the TLS handshake without a certificate, which only suits certificate-only deployments. |
| `auth.trust_store_pem_s3_key` | trust store | Key of the client CA bundle PEM in the receipt config bucket (default `trust/client-ca.pem`). Required if `CERTIFICATE` or `CERTIFICATE_IDENTITY` is set (section 7.2). |
| `auth.dfk_s3_prefix` | files in `receive.dataFeedIdentitiesDir` | Prefix of the DFK files in the receipt config bucket (default `dfk/`). Required if `DATA_FEED_KEY` or `CERTIFICATE_IDENTITY` is set without a downstream Stroom (section 7.2). |
| `auth.data_feed_owner_meta_key` | `receive.dataFeedOwnerMetaKey` | Default `AccountId`. |
| `auth.openid` (object: `issuer`, `openid_configuration_endpoint`, `allowed_audiences`, `client_id`, `unique_identity_claim`, …) | `security.authentication.openId` with `identityProviderType: EXTERNAL_IDP` | Required for `TOKEN` unless a downstream Stroom validates API keys. Works with Cognito, Entra ID, Keycloak and similar. The proxy fetches the IdP's JWKS, so it needs outbound HTTPS to it. |
| `downstream` (default `null`) | `downstreamHost.{scheme,hostname,port,pathPrefix,apiKey}` | Optional downstream Stroom, for feed status, receipt policy, Stroom API keys and DFKs held in Stroom. With S3-only forwarding it is usually `null`, which gives `downstreamHost.enabled: false`. |
| `receipt.check_mode` (default `RECEIVE_ALL`; also `FEED_STATUS`, `RECEIPT_POLICY`, `FEED_EXISTENCE`, `DROP_ALL`, `REJECT_ALL`) | `receive.receiptCheckMode` | The first three need `downstream`. With `RECEIVE_ALL`, any authenticated sender can send to any feed name. |
| `receipt.fallback_action` | `receive.fallbackReceiveAction` | Used when downstream can't be reached. |
| `receive.max_request_size` | `receive.maxRequestSize` | |
| `receive.feed_name_generation` (object) | `receive.feedNameGeneration*`, `feedNameTemplate` | |

Terraform `validation` blocks catch inconsistent combinations before apply:

* `TOKEN` needs `openid` (OAuth tokens) or `downstream` (Stroom API keys).
* `FEED_STATUS`, `RECEIPT_POLICY` and `FEED_EXISTENCE` need `downstream`.
* `DATA_FEED_KEY` and `CERTIFICATE_IDENTITY` need `downstream` or `dfk_s3_prefix`.
* `CERTIFICATE` and `CERTIFICATE_IDENTITY` need `trust_store_pem_s3_key`.
* `client_cert_mode = "need"` with key or token types is rejected, because it would refuse senders that have no certificate.
* `auth.required = false` is rejected when `allowed_ingress_cidrs` contains `0.0.0.0/0`.

## 7. S3

### 7.1 Data bucket: immutable once written

Forwarding goes to S3 only (`forward_s3`), and nothing else is forwarded by default. Once the proxy has written an object, nobody can change or delete it until its retention period has passed, not even the account root.

* **Object Lock in `COMPLIANCE` mode**, with versioning, and a default retention of `data_retention_days` applied to every new object version. The variable has **no default** and must be set per environment: in compliance mode the retention of a stored object can be extended but never shortened, and the bucket can't be deleted while it holds locked objects. A lifecycle rule (`noncurrent_version_expiration` and expiry of the current version after the retention period, optional) removes data once it is no longer locked.
* **The proxy role can only add objects**: `s3:PutObject`, `s3:PutObjectTagging` (the forwarder tags each object with its feed and stream type, F11), and, when multipart upload is enabled, `s3:AbortMultipartUpload` and `s3:ListMultipartUploadParts`. It has no read, delete, retention, legal-hold or bucket-configuration rights.
* **The bucket policy** denies any request without TLS, denies the proxy role every `s3:Delete*`, `s3:PutObjectRetention`, `s3:PutObjectLegalHold`, `s3:BypassGovernanceRetention` and `s3:PutBucket*` action (as a backstop to its IAM policy), and denies `s3:PutBucketObjectLockConfiguration` to everyone except `admin_principal_arns`.
* **Encryption**: SSE-KMS with a dedicated customer-managed key and S3 Bucket Keys. The proxy role gets `kms:GenerateDataKey`, plus `kms:Decrypt`, because S3 needs it to complete multipart uploads. The proxy still can't read objects, because it has no `s3:GetObject`. The key policy keeps key deletion to `admin_principal_arns`. Deleting the key would make the locked data unreadable.
* **Unique keys**: S3 can't be made to reject a put to an existing key unless the client sends `If-None-Match`, which the proxy doesn't (F11). A second put to the same key would create a new version on top; the earlier version would stay locked and retrievable, but the "current" object would change. So the forwarder's key template must include a per-batch unique value such as the receipt ID, and a validation enforces that. Phase 3 checks the proxy's default key template.
* **Telling Stroom about new data**: with `data_notifications = "sqs"` (the default), S3 event notifications go to an SQS queue that Stroom's S3/SQS ingest can read. The alternative, the forwarder's `REST` notification type, needs a downstream Stroom.
* **Existing bucket**: `data_bucket_name` can name an existing bucket instead. The AWS provider has no data source for Object Lock settings, so an `external` data source calls `s3api get-object-lock-configuration`. A precondition then fails the plan unless the bucket has versioning and Object Lock in `COMPLIANCE` mode with a default retention.
* **Destroy**: Terraform never deletes the data bucket (`prevent_destroy`, no `force_destroy`). AWS wouldn't allow it while locked objects remain anyway. Removing `30-stroom-proxy` means first taking the bucket out of state.

### 7.2 Receipt config bucket: DFKs and trust store

DFK files and the mTLS trust-store PEM live in one bucket (`receipt_config_bucket`, created by Terraform unless an existing name is given):

```
s3://<receipt-config-bucket>/
├── dfk/                 # DataFeedIdentities JSON files (hashed keys), any number
│   ├── team-a.json
│   └── team-b.json
└── trust/
    └── client-ca.pem    # client CA bundle for mTLS
```

Whoever manages senders writes to this bucket; the proxy role can only read `dfk/*` and `trust/*`.

Each proxy pod has:

* an **init container** (`s3-sync`, the same image as the sidecar) that downloads the DFK files and the PEM, then builds the PKCS12 trust store from the PEM. The proxy therefore starts with every key and trust anchor in place;
* a **sidecar** (`s3-sync`) that compares the DFK prefix with the local directory every `dfk_sync_interval` (default 60 s). It downloads new or changed files to a temporary name and renames them into `dataFeedIdentitiesDir`, and deletes local files that have gone from S3. The proxy's directory watcher then adds, reloads or removes those keys without a restart (F10).

The sidecar image is a pinned `amazon/aws-cli` digest (or a small purpose-built image) running as uid 1000 under the `restricted` Pod Security Standard. Both write to an `emptyDir` shared with the proxy container.

Trust-store changes need a restart (F13). Terraform reads the PEM object's ETag (`aws_s3_object` data source) and puts it in a pod annotation. When the PEM changes, the next `terraform apply` triggers a drained rolling restart of every colour that is running (section 9.4). Adding a CA to the bundle ahead of time avoids hurrying this.

## 8. Pods, nodes and storage

* Each colour is a StatefulSet with `replicas` pods, spread one per node across that colour's per-AZ node groups (`topologySpreadConstraints` on zone with `maxSkew: 1`, a required `podAntiAffinity` on hostname, a nodeSelector on `stroom-proxy/colour`, and a toleration for the proxy taint). A StatefulSet, not a Deployment, because each proxy owns a durable queue on disk (receive store, aggregation, forward queues, retry).
* Each pod gets an EBS `gp3` PVC (`proxy_data_volume_gb`, `iops`, `throughput`) mounted at `/stroom-proxy/data`. EBS volumes are tied to one AZ; the per-AZ node groups make sure a pod can always come back in its volume's AZ.
* `persistentVolumeClaimRetentionPolicy: { whenScaled: Retain, whenDeleted: Retain }` keeps unsent data when replicas go down or a colour is removed.
* **Scaling up** is done in place: increase the colour's `replicas` (and `nodes_per_az` if needed) and apply.
* **Scaling down** is a blue/green switch to a new colour with fewer replicas (section 9.2). The old colour drains completely before it is removed, so no pod is ever removed while it holds unsent data, and no manual relabelling is needed.
* **Destroy**: because of `whenDeleted: Retain`, `terraform destroy` leaves the proxy EBS volumes behind. They keep costing money until deleted. This is deliberate, so unsent data survives. The README lists the cleanup command.
* A PodDisruptionBudget per colour (`maxUnavailable: 1`).
* Sizing: `proxy_resources` (requests and limits) and `proxy_java_opts` are inputs, with a default heap of 50–60 % of the memory limit. A `check` block warns when a colour's nodes can't fit its pods (from the `aws_ec2_instance_type` data source).

Pod-count autoscaling (HPA) is out of scope because of the on-disk queues. Node autoscaling isn't needed with fixed per-colour node groups.

## 9. Upgrades: blue/green and draining

### 9.1 What changes how

| Change | How | Effect on senders |
|---|---|---|
| Proxy image, proxy config, replica count down | Blue/green switch (9.2) | None. |
| Proxy node AMI, node Kubernetes version, instance type | Blue/green switch to a colour with new nodes (9.2) | None. |
| Proxy replica count up | In place | None. |
| DFKs | Synced live from S3 (7.2) | None. |
| Trust-store PEM, server certificate | Drained rolling restart of each running colour (9.4) | None if senders retry. Capacity drops by one pod at a time. |
| EKS control plane (one minor version at a time) | In place, `cluster_version` in `10-infra` | None: only the Kubernetes API is briefly affected. Nodes may lag the control plane by up to three minor versions, so proxy nodes catch up at the next blue/green. |
| EKS add-ons | In place, after the control plane | None. Rolling DaemonSet updates don't affect running pods' networking. |
| System nodes | Managed node group rolling update | None. CoreDNS and the controllers have PDBs. |

### 9.2 Blue/green procedure

Each colour is a complete, independent proxy: its own node groups (`10-infra`), StatefulSet, PVCs and target group (`30-stroom-proxy`). Data feed keys, the trust store, the server certificate and the data bucket are shared.

Starting state: `blue` is the only colour and `active_colour = "blue"`.

1. **Add green.** Add `green` to `proxy_node_colours` in `10-infra` (new AMI, version or instance type as needed) and apply. Add `green` to `proxy_deployments` in `30-stroom-proxy` (new image, config or replica count) and apply. Green's pods start on green's nodes and register in green's target group. The `:9443` test listener now points at green.
2. **Test green.** From `admin_cidrs`, send test data to `https://<hostname>:9443/datafeed` with each authentication type, and check it arrives in the data bucket.
3. **Switch.** Set `active_colour = "green"` and apply. The `:443` listener now forwards new connections to green; `:9443` points at blue. This is one API call on the listener. Connections already open to blue continue to blue (to be confirmed in phase 5 testing). If one is reset instead, the sender gets an error and retries. That loses no data, because the proxy only acknowledges a POST once the data is on disk.
4. **Drain blue.** Blue receives nothing new. It keeps closing its aggregates (within `aggregation.frequency`) and forwarding its queues to S3. `scripts/proxy-queue-status.sh blue` reports the unsent files per pod. Wait until every pod reports zero.
5. **Remove blue.** Remove `blue` from `proxy_deployments` and apply (the StatefulSet goes; its PVCs are retained). Delete blue's PVCs with `scripts/proxy-queue-status.sh blue --delete-empty-pvcs`, which deletes a PVC only if it is empty. Remove `blue` from `proxy_node_colours` and apply. Its nodes have no proxy pods left, so nothing is evicted.

**Rollback**: at any point before step 5, set `active_colour` back to `blue` and apply.

The next upgrade goes from green back to blue. Preconditions check that `active_colour` is in `proxy_deployments`, so the active colour can't be removed by mistake. They also check that every deployment has a node colour in the `10-infra` outputs, and that each colour's nodes can hold its replicas.

Proxy node cost doubles only between steps 1 and 5.

### 9.3 Draining a pod

This applies whenever a receiving pod stops: a rolling restart, `kubectl drain`, a managed node group update or a Spot interruption.

1. When the pod starts terminating, its EndpointSlice entry becomes not-ready, and the LB controller deregisters it from its target group. The NLB stops sending it new connections. Existing connections keep their target for `deregistration_delay` (default 120 s, connection termination off).
2. A `preStop` hook sleeps for `deregistration_delay` + 15 s, so Jetty keeps serving while the NLB drains.
3. Jetty receives `SIGTERM`, stops accepting connections and waits up to Dropwizard's `shutdownGracePeriod` (set to 60 s) for in-flight requests to finish.
4. `terminationGracePeriodSeconds` is greater than the sum of the two (default 240 s).

An upload still running after that is cut off, and the sender retries. Data the proxy has acknowledged is on the PVC; the pod comes back on a node in the same AZ, with the same volume, and carries on forwarding.

The namespace has `elbv2.k8s.aws/pod-readiness-gate-inject: enabled`. A replacement pod therefore only counts as Ready once the NLB reports it healthy, and a rolling restart never has more than one pod out of service. The PodDisruptionBudget (`maxUnavailable: 1`) gives the same guarantee for evictions from node drains.

A Spot interruption gives only two minutes' notice, less than the drain takes with default settings. That is one more reason proxy nodes default to on-demand.

If a node fails outright, nothing drains. The data is still on the EBS volume. The pod is rescheduled in the same AZ, which can take several minutes while EBS force-detaches the volume. Senders retry against the remaining pods meanwhile.

### 9.4 Drained rolling restart

Used for trust-store PEM and server certificate changes, where a whole blue/green switch would be heavy-handed. The StatefulSet `RollingUpdate` restarts pods one at a time, highest ordinal first. Each pod drains as in 9.3, and the readiness gate holds the next restart until the replacement is healthy in the target group.

## 10. Helm chart

The gradata `stroom-proxy` chart (F3) is copied into `gchq/stroom-k8s-operator` at `charts/stroom-proxy`, keeping its Apache 2.0 licence and crediting its origin in the chart README. The changes needed are then made there:

1. Remove `feedStatus.enabled` and `feedStatus.apiKey`. Add a `downstreamHost` block with `enabled` and `apiKey: ${DOWNSTREAM_API_KEY}` (F4).
2. Add values for `receive.enabledAuthenticationTypes`, `receiptCheckMode`, `fallbackReceiveAction`, `dataFeedIdentitiesDir`, `dataFeedOwnerMetaKey`, `allowedCertificateProviders` and `maxRequestSize`.
3. Add a `security.authentication.openId` block.
4. Make `forwardHttpDestinations` a list. Add `forwardS3Destinations` and `forwardFileDestinations`. Update queue keys to 7.14 (`forwardRetryThreadCount`, `livenessCheckInterval`, …).
5. Add `fsync` and `threads` passthrough. Better still, add a generic `extraProxyConfig` map deep-merged into `proxyConfig`, so new proxy settings don't need a chart release.
6. Choose between `wantClientAuth` and `needClientAuth`. Build the trust store from a client CA PEM supplied by the `s3-sync` init container (section 7.2) rather than from the server certificate's `ca.crt`.
7. Two application connectors: 8443 with `useProxyProtocol: true` (exposed through the Service) and 8444 without it (in-pod callers only) (section 5.2). Dropwizard `shutdownGracePeriod` from values.
8. Add the `s3-sync` init container and sidecar (section 7.2), with their image, interval, bucket and prefixes as values.
9. Add `podDisruptionBudget`, `topologySpreadConstraints`, pod anti-affinity, `persistentVolumeClaimRetentionPolicy`, and the `restricted` PSS-compatible `securityContext` (`allowPrivilegeEscalation: false`, drop ALL, `seccompProfile: RuntimeDefault`). Check the image's entrypoint: it only `chown`s and `su-exec`s when started as root, so starting as uid 1000 with `fsGroup: 1000` should skip that path.
10. Add a `preStop` sleep and `terminationGracePeriodSeconds` derived from a `drain.deregistrationDelaySeconds` value (section 9.3).
11. Add a `colour` value. It suffixes resource names, labels pods `stroom-proxy/colour`, and sets the nodeSelector, so two releases (blue and green) can run side by side in one namespace.
12. The Service becomes `ClusterIP` (the `TargetGroupBinding` refers to it). There is no Ingress and no `LoadBalancer` Service.
13. Make the `checksum/config` pod annotation roll pods when config changes. Add a `podAnnotations` value (used for the trust-store ETag, section 7.2).
14. Replace the privileged log-sender with the non-root log-sender (section 17.2), posting to `https://localhost:8444/datafeed`.
15. Add `image.digest`, rendered as `repository@sha256:…` when set.
16. Add `logging.consoleAppenders` (default `true`), which adds console appenders to the `receive` and `send` loggers and the request log, each line prefixed with the log name. CloudWatch then gets the receipt audit trail (section 12). The file appenders stay, for the log-sender.

The chart is released from `gchq/stroom-k8s-operator` alongside the operator charts. `30-stroom-proxy` references it by `chart_repository` and `chart_version`, with a local `chart_path` override (`../../charts/stroom-proxy`) for chart development only. Worthwhile fixes can also be offered back to the gradata chart.

A CI check renders the chart with `helm template`, runs the output through the proxy's own config validation (start the image with `--check`, or the `GenerateProxyExpectedYaml` comparison), and fails on unknown keys. This catches F4-style drift whenever the proxy image tag changes.

## 11. Secrets

* DFKs and the trust-store PEM come from the receipt config bucket (section 7.2), not from Secrets Manager.
* Secrets Manager holds the rest: the OpenID client secret (if the IdP needs one), the downstream API key (only with a downstream Stroom), and the server certificate in `secrets_manager` mode.
* Default delivery: External Secrets Operator with a Pod Identity role scoped to `arn:…:secret:stroom-proxy/<env>/*`. Terraform only creates `ExternalSecret` objects, so **no secret values end up in Terraform state**.
* Fallback for small or dev setups: `secret_delivery = "terraform"` reads the values with `aws_secretsmanager_secret_version` and writes `kubernetes_secret`. This puts the values in state, so the backend bucket must be encrypted and access-restricted. The README warns about it.
* The keystore password is generated in the cluster by an External Secrets `Password` generator, so it never passes through Terraform. It only protects the PKCS12 files built in an `emptyDir` at pod start, so it doesn't need to be stable or stored. In `terraform` delivery mode, `random_password` is used and the value is in state like the other secrets.

## 12. Observability and operations

* **Logs**: the `amazon-cloudwatch-observability` add-on (Fluent Bit) collects container stdout. With the chart's `logging.consoleAppenders` (section 10, item 16), the application, receive, send and access logs all reach CloudWatch Logs, one log group per cluster with a retention variable (`log_retention_days`, default 90). The rolled log files under `/stroom-proxy/logs` on the PVC are posted back into the proxy by the log-sender (section 17.2), so they end up in the data bucket like any other feed.
* **Metrics**: Dropwizard metrics on the admin port 8090. Container Insights gives node and pod metrics. NLB target health per colour is in CloudWatch.
* **Health**: the chart's probes use `/proxyAdmin/filteredhealthcheck?deny=stroom.proxy.app.handler.RemoteFeedStatusService`. Keep that, so pods don't go unready (and get restarted by the liveness probe) when a downstream is down; the proxy queues meanwhile. The NLB health check uses the same endpoint (section 5.1).
* **Upgrades**: section 9.
* **Backups**: not needed for the data bucket (Object Lock). Optional EBS snapshot policy (DLM) on PVC volumes by tag.

## 13. Terraform inputs (proposed)

```hcl
# --- 10-infra ---
aws_region            = "eu-west-2"
name                  = "stroom-proxy-prod"
vpc_cidr              = "10.40.0.0/16"
az_count              = 3
nat_gateway_mode      = "one_per_az"        # single | one_per_az
existing_vpc_id       = null
cluster_version       = "1.37"
admin_principal_arns  = ["arn:aws:iam::123456789012:role/PlatformAdmin"]
api_allowed_cidrs     = ["198.51.100.0/24"]

system_node_instance_type = "t3.medium"
system_node_count         = 2

proxy_node_colours = {
  blue = {
    instance_types      = ["m6i.xlarge"]    # validated: no Graviton (amd64-only image)
    capacity_type       = "ON_DEMAND"
    nodes_per_az        = 1
    kubernetes_version  = "1.37"            # explicit; may lag cluster_version by up to 3 minors
    ami_release_version = null              # latest at creation, then fixed; or pin e.g. "1.37.4-20261020"
    root_volume_gb      = 50
  }
  # green = { ... }                         # only during an upgrade
}

# --- 20-platform ---
route53_zone_id        = "Z0123456789"
tls_certificate_source = "cert_manager_private_ca"
private_ca_arn         = "arn:aws:acm-pca:…"
log_retention_days     = 90

# --- 30-stroom-proxy ---
proxy_deployments = {
  blue = {
    image_tag    = "v7.14-beta.8"
    image_digest = "sha256:…"               # from scripts/latest-proxy-tag.sh
    replicas     = 3
  }
}
active_colour = "blue"

proxy_resources       = { requests = { cpu = "1", memory = "4Gi" }, limits = { cpu = "2", memory = "4Gi" } }
proxy_java_opts       = "-Xms2g -Xmx2g"
proxy_data_volume_gb  = 200
proxy_data_volume_iops       = 3000
proxy_data_volume_throughput = 250

load_balancer_scheme  = "internal"          # default; internet-facing is opt-in
allowed_ingress_cidrs = ["10.0.0.0/8"]      # direct senders (VPN, peering, Direct Connect)
admin_cidrs           = ["10.1.2.0/24"]     # test listener :9443
hostname              = "proxy.example.internal"
deregistration_delay  = 120

privatelink = {
  enabled             = true
  allowed_principals  = ["arn:aws:iam::210987654321:root"]
  acceptance_required = true
  private_dns_name    = "proxy.example.internal"
  verification_zone_id = null               # public zone for the ownership TXT record, if in Route 53
}

auth = {
  required               = true
  types                  = ["CERTIFICATE", "TOKEN", "DATA_FEED_KEY"]
  client_cert_mode       = "want"
  trust_store_pem_s3_key = "trust/client-ca.pem"
  dfk_s3_prefix          = "dfk/"
  openid = {
    issuer            = "https://login.example.com/realms/stroom"
    allowed_audiences = ["stroom-proxy"]
    client_id         = "stroom-proxy"
  }
}

receipt_config_bucket = null                # null = create "<name>-receipt-config"
dfk_sync_interval     = "60s"

downstream = null                           # optional downstream Stroom
receipt    = { check_mode = "RECEIVE_ALL", fallback_action = "RECEIVE" }

data_bucket_name    = null                  # null = create "<name>-data" with Object Lock
data_retention_days = 365                   # required; COMPLIANCE mode can't be shortened
data_notifications  = "sqs"                 # sqs | none
forward_s3 = {
  key_template = "${feed}/${year}/${month}/${day}/${receiptId}.zip"   # illustrative syntax (checked in phase 3); must contain a unique id
  multipart    = true
}

aggregation  = { enabled = true, frequency = "PT10M", max_items = 1000, max_uncompressed_size = "1.0G" }
extra_proxy_config = {}   # deep-merged escape hatch
secret_delivery    = "external_secrets"   # or terraform
```

Outputs: cluster name and endpoint, a `kubeconfig` command, the NLB DNS name, the datafeed URL (`https://<hostname>/datafeed`), the test URL (`https://<hostname>:9443/datafeed`), the endpoint service name and private DNS verification record, the data bucket and SQS queue names, the receipt config bucket name, the namespace, and IAM role ARNs.

## 14. Security baseline

* Nodes sit in private subnets. The NLB security group allows only `allowed_ingress_cidrs` on 443 and `admin_cidrs` on 9443. PrivateLink access is limited by the endpoint service's allowed principals and acceptance. `TargetGroupBinding` adds node security group rules for 8443 and 8090 from the NLB security group. The node security group also allows node-to-node traffic, so it isn't what limits access to the pods: the NetworkPolicy is. The EKS API endpoint is private, plus a public endpoint only for `api_allowed_cidrs`.
* The namespace enforces the `restricted` Pod Security Standard.
* A NetworkPolicy (enforced by the VPC CNI, section 4.1) allows ingress to proxy pods on 8443 and 8090 only from the NLB's private IPs, and nothing on 8444. Because sender addresses arrive in the PROXY header, a pod must never accept 8443 from anything other than the NLB (section 5.2). Egress is unrestricted in v1, since the proxy needs DNS, S3, the IdP's JWKS endpoint and AWS APIs.
* IMDSv2 is required with hop limit 1, so pods can't use the node role. All AWS access goes through Pod Identity. The proxy role can write to the data bucket and read the receipt config prefixes, and nothing else (section 7).
* Data in S3 is immutable for its retention period (section 7.1). EBS volumes, EKS Secrets and both buckets are encrypted with KMS. The state bucket is encrypted and versioned.
* Images are pinned by digest (F1). Optional: mirror to ECR with a pull-through cache to avoid Docker Hub rate limits and give a private pull path.

## 15. Decisions

Agreed 2026-10-29; the last seven rows were added the same day after review comments.

| Topic | Decision |
|---|---|
| Helm chart | Copy the gradata `stroom-proxy` chart into `gchq/stroom-k8s-operator` (`charts/stroom-proxy`) and update it there (section 10). Terraform references it by chart repo and version. |
| Code location | `gchq/stroom-k8s-operator`: Terraform in `terraform/aws-eks-proxy/`, this design in `design/`. |
| Image | Pin `v7.14-beta.8` plus digest. Move to `v7.14.0` when it ships. Never use `v7.14-LATEST`. |
| Ingress | Terraform-owned NLB with TLS passthrough, PROXY protocol v2, and a target group per colour bound with `TargetGroupBinding`. No ALB. |
| LB scheme | `load_balancer_scheme` variable, default `internal`. `internet-facing` is opt-in and requires `allowed_ingress_cidrs` without `0.0.0.0/0`. |
| VPC | A new 3-AZ VPC by default. `existing_vpc_id` + subnet ids switch to an existing one. |
| Secrets | Secrets Manager → External Secrets Operator by default. `secret_delivery = "terraform"` fallback for dev (values in state). |
| Logs | All proxy logs to stdout and CloudWatch. Rolled log files posted back into the proxy by the non-root log-sender. |
| System nodes | A small untainted system node group (2 × `t3.medium`) runs the cluster services. |
| Autoscaling | None in v1: pod and node counts are fixed by variables. |
| **PrivateLink** | Optional VPC endpoint service on the NLB, with allowed principals, acceptance required by default, and a private DNS name equal to `hostname`. |
| **Authentication** | mTLS + OIDC token + DFK all enabled by default, `client_cert_mode = "want"`. DFKs and the trust-store PEM come from an S3 bucket, synced into each pod by a sidecar. DFK changes are live; trust-store changes roll the pods. |
| **Forwarding** | S3 only by default, to a data bucket with Object Lock in `COMPLIANCE` mode and a required `data_retention_days`. The proxy role can only put objects. New objects are announced on an SQS queue. Downstream Stroom is optional and off by default (`RECEIVE_ALL`). |
| **Upgrades** | Blue/green: each colour has its own per-AZ proxy node groups, StatefulSet and target group. Terraform switches the `:443` listener; the old colour drains its queues before it is removed. Platform upgrades (control plane, add-ons, system nodes) are in place. |
| **Draining** | `preStop` sleep longer than the NLB deregistration delay, Dropwizard graceful shutdown, pod readiness gates and a PDB, so a pod never stops while the NLB is still sending it connections. |
| **Log sender** | Wire in the non-root, supercronic-based log-sender that already exists on a branch, disabled by default until a released image exists. |
| **Buckets** | Terraform creates the data and receipt config buckets by default; existing buckets can be named instead. |

Open items:

* The branch and image name of the non-root log-sender, and when it will be released.
* `data_retention_days` per environment.
* To confirm in testing: open connections survive a listener switch (section 9.2), and the proxy's default S3 key template is unique per batch (section 7.1).

## 16. Implementation phases

1. `10-infra`: VPC, EKS, system node group, add-ons. Rework the existing proxy node group into `proxy_node_colours` with one node group per AZ per colour. Done when `kubectl get nodes` shows a proxy node in each AZ for the colour, and the system pods are running.
2. `20-platform`: LB controller, gp3 StorageClass, CloudWatch add-on, External Secrets, cert-manager.
3. Copy the gradata `stroom-proxy` chart into `charts/stroom-proxy`, then make the changes in section 10, with the `helm template` + config validation CI check. Check the proxy's default S3 key template.
4. `30-stroom-proxy` with one colour: the data bucket with Object Lock and SQS notifications, the receipt config bucket, the NLB, PrivateLink, auth with certificate, OIDC and DFK, S3 forwarding, NetworkPolicy. Done when:
   * `curl --cert … https://<hostname>/datafeed` returns 200, and so do the same request with an OIDC token and with a DFK and no certificate;
   * a request with none of them is refused;
   * the data arrives in the data bucket, and neither the proxy role nor an admin can delete it or change a stored version;
   * a DFK added to S3 works within `dfk_sync_interval`, and one removed from S3 stops working;
   * the same requests work through a PrivateLink endpoint from another VPC, with the sender's address in the receive log;
   * receive log lines are visible in CloudWatch.
5. Blue/green and draining: the second colour, test listener, listener switch, `proxy-queue-status.sh`, the drain settings, runbooks, and `terraform test` suites for the variable validations. Done when a blue → green → blue cycle under continuous test traffic loses no acknowledged data and senders see no errors other than retried resets.
6. Other options: downstream Stroom with `RECEIPT_POLICY` and HTTP forwarding, `internet-facing` with ACME certificates, `terraform` secret delivery.

## 17. Future work

Not in v1. Listed so the v1 design doesn't block any of it.

### 17.1 Helm chart (gchq/stroom-k8s-operator)

* **Values schema**: `values.schema.json`, so bad values fail at `helm install` rather than at proxy start-up.
* **Chart tests**: a `helm test` pod that posts a small sample file to `/datafeed` and checks for a 200.
* **Chart CI**: `ct lint` and `ct install` against a kind cluster on every change, plus the config validation check from section 10.
* **Publishing**: release the chart to an OCI registry (e.g. GHCR), with chart versions independent of the proxy version and `appVersion` tracking the proxy tag.
* **Image updates**: Renovate (or similar) raising pull requests when a new `v7.14.N` tag and digest appear, for both the chart default and the Terraform examples.
* **Optional templates**: `ServiceMonitor` for Prometheus, and `NetworkPolicy` (moving it from Terraform into the chart).
* **StroomProxy custom resource**: the operator already manages Stroom node lifecycle (draining tasks before shutdown, rolling upgrades). A `StroomProxy` resource could run the blue/green procedure in section 9.2 itself (create the new colour, switch, wait for empty queues, remove the old colour), replacing the Terraform-driven steps. That is a substantial Go change.
* **Stroom alongside**: deploy Stroom itself with the operator's `StroomCluster` resource on the same EKS platform.

### 17.2 Log sender

A reworked `gchq/stroom-log-sender` already exists on a branch: it runs as uid 1000 under supercronic instead of root cron, needs no `privileged`, and posts the rolled log files to the pod's own proxy. The v1 chart and Terraform wire it in (image, tag and digest as variables) but leave it **disabled by default** (`log_sender.enabled = false`) until a released image exists, so phase 4 doesn't wait for it. When enabled:

* it posts to `https://localhost:8444/datafeed`, the connector without PROXY protocol (section 5.2);
* it authenticates with a DFK (from the same S3-synced directory) or its own client certificate.

Logs then go through the proxy's own queue and forwarding into the data bucket. Once it is enabled everywhere, `logging.consoleAppenders` can default to `false` for the receive and send logs, so they aren't stored twice.

### 17.3 Stroom-Proxy changes

These would need GitHub issues raised by a person:

* **arm64 image**: publish `gchq/stroom-proxy` for arm64, to allow cheaper Graviton nodes (F2).
* **Drain mode**: an admin task or endpoint that closes open aggregates immediately and reports when all queues are empty. This would shorten step 4 of blue/green and replace the file counting in `proxy-queue-status.sh`.
* **`If-None-Match` on S3 puts**: send `If-None-Match: *`, so the data bucket policy can require it and reject any overwrite (F11).
* **SSL reload**: include Dropwizard's SSL reload bundle, so trust-store and certificate changes don't need a restart (F13).
* **Certificate from a load balancer header**: parse a PEM or URL-encoded PEM certificate in `x509CertificateHeader` (F5), and accept CIDR ranges in `allowedCertificateProviders` (F6). Only needed if an ALB is ever used.
* **Release pipeline**: `v7.14-LATEST` should only follow release builds, not branch builds (F1).

### 17.4 Platform

* ALB with AWS WAF and ACM certificates. Needs the proxy changes in 17.3, since TLS would end at the ALB.
* Mirroring images into ECR (pull-through cache), for private pulls and to avoid Docker Hub rate limits.
* Restricting egress in the NetworkPolicy to known destinations.
* Full-cluster blue/green (a second cluster behind the same endpoint service), for changes that can't be made in place.
* Multi-region deployment.
