# Stroom-Proxy 7.14 on AWS EKS with Terraform: design

Status: design agreed 2026-10-29 and revised the same day after review comments (PrivateLink, authentication, immutable S3, blue/green upgrades, log sender, and the current ALB topology). See section 15. Phases 1 to 4 (`10-infra`, `20-platform`, the `stroom-proxy` chart and `30-stroom-proxy`) are written. The Terraform is not yet applied to AWS; the chart, including the values `30-stroom-proxy` renders, has been validated and boot-tested against the 7.14-beta.8 image. Phases 5 and 6 are not written.

## 1. Goal

Terraform that takes an empty AWS account (or an existing VPC) and produces:

* an EKS cluster whose proxy nodes' EC2 instance type and count are inputs;
* Stroom-Proxy 7.14 (image `gchq/stroom-proxy` from Docker Hub) with a configurable number of pods;
* **two HTTPS endpoints on port 443** that accept data (`/datafeed`, `/stroom/datafeed`), reachable directly (VPC, peering, VPN, Direct Connect) and through AWS PrivateLink, so senders can authenticate either way over either path:
  * an **mTLS endpoint**, where a client certificate is required and checked by the load balancer;
  * a **non-mTLS endpoint**, where senders authenticate with an OpenID Connect token or a data feed key (DFK);
* DFKs and the mTLS trust-store PEM pulled from S3;
* forwarding to an S3 bucket in which objects can't be changed or deleted once the proxy has written them;
* upgrades without downtime: blue/green for the proxy and its nodes, with proper draining whenever a receiving pod stops.

The load balancer layout mirrors the current deployment: one ALB with an mTLS listener and a non-mTLS listener, and two NLBs, each forwarding 443 to one of those listeners and each with its own VPC endpoint service.

Out of scope for the first version: Stroom itself, multi-region, and autoscaling the pod count from load.

## 2. Findings that shape the design

These came from the 7.14 source, Docker Hub, AWS documentation and the public Helm charts. Each one changes a decision below.

| # | Finding | Consequence |
|---|---------|-------------|
| F1 | There is no 7.14 GA release yet. The newest tag is `v7.14-beta.8` (16 Oct 2026). The floating tag `v7.14-LATEST` has the same digest as `v7.14-beta.8-parallel-pathways`, a branch build, not `v7.14-beta.8`. | Never deploy a floating tag. Terraform pins an explicit tag plus digest (`image_tag`, `image_digest`). A helper script finds the newest `v7.14.N` / `v7.14-beta.N` tag. |
| F2 | The `gchq/stroom-proxy` image is published for `amd64` only. | Graviton (`*g` families such as `m7g`, `c7g`) cannot be used. A variable validation rejects them. |
| F3 | The only existing stroom-proxy Helm chart is `gradata-systems/stroom-helm-charts` → `charts/stroom-proxy` (chart 1.2.13, appVersion `v7.10.5`, last pushed 31 Mar 2026; formerly `p-kimberley/stroom-kubernetes`). `gchq/stroom-k8s-operator` (a fork of `gradata-systems/stroom-k8s-operator`) has only the operator and CRD charts, and its custom resources cover Stroom clusters, databases, backups and task autoscaling, not Stroom-Proxy. There is no `gchq/stroom-k8s` repo. | **That chart has no licence** (nor did `p-kimberley/stroom-kubernetes`), so it can't be copied. A new chart is written from scratch in `gchq/stroom-k8s-operator` as `charts/stroom-proxy`, MIT like the rest of the repo (section 10). The Terraform lives in the same repo. |
| F4 | That chart does not boot 7.14 as written: it always renders `proxyConfig.feedStatus.enabled` and `.apiKey`, which no longer exist in 7.14 (`feedStatus` only has `url` and `feedStatusCache`; the API key moved to `downstreamHost.apiKey`). Proxy enables `FAIL_ON_UNKNOWN_PROPERTIES` (`App.java:147`), so unknown keys stop start-up. It also has no values for `enabledAuthenticationTypes`, `receiptCheckMode`, `downstreamHost`, data feed identities, OpenID or S3 forwarding. | The chart needs a 7.14 update (section 10). |
| F5 | The proxy reads `receive.x509CertificateHeader` as a servlet request attribute, not as a PEM string in an HTTP header (`CertificateExtractorImpl.extractCertificate`). Only the DN header (`x509CertificateDnHeader`) works when a load balancer ends TLS. | With the ALB checking client certificates, the proxy sees only the subject DN, from the header the ALB adds. Certificate identity is by DN (section 6). |
| F6 | `allowedCertificateProviders` accepts IP addresses or host names, not CIDR ranges, and ALB node IPs change. | It can't be used to pin DN-header trust to the ALB. Network controls do that instead (section 5.3). |
| F7 | S3 forwarding and SQS ingest use the AWS SDK default credential chain (`AwsCredentialsHelper`). | EKS Pod Identity works with no proxy changes. |
| F8 | The gradata chart's log-sender sidecar runs as root with `privileged: true`. | Not used. A non-root log-sender already exists on a branch (section 17.2). |
| F9 | ingress-nginx, which the chart's Ingress template assumes, was retired by Kubernetes SIG Network in March 2026. | Don't use the chart's Ingress. |
| F10 | The proxy watches `receive.dataFeedIdentitiesDir` with a Java `WatchService` (`DataFeedIdentitiesDirWatcher`). It loads every `*.json` regular file at start, reloads a file when it is created or modified, and drops that file's keys when it is deleted. | DFKs synced from S3 into that directory take effect without a restart. Files must be written atomically (temporary name not ending `.json`, then rename) so a half-written file is never parsed (section 7.2). |
| F11 | The S3 forwarder (`ForwardS3DestinationImpl`, `S3ClientHelper`) only calls `PutObject`, with object tags (`Feed`, stream type) and optional multipart upload through the transfer manager. It never deletes or overwrites deliberately, and it doesn't send `If-None-Match`. It uses AWS SDK 2.54, which sends a checksum on every upload by default. | An Object Lock bucket works with it: Object Lock needs a checksum or `Content-MD5` on each put, and the SDK sends one. The proxy's IAM role needs only `s3:PutObject`, `s3:PutObjectTagging` and the multipart actions. A bucket policy can't require `If-None-Match`, so object keys must be unique (section 7.1). |
| F12 | Dropwizard 5 (`HttpConnectorFactory`) supports `useForwardedHeaders` (and `useProxyProtocol`) on a connector. | Not relied on for sender addresses: see F19 (section 5.4). |
| F13 | The proxy doesn't include Dropwizard's SSL reload bundle, so its own TLS settings are only read at start-up. | Little impact now: the client trust store and the public server certificate live on the ALB, which updates them without restarts (section 5.2). |
| F14 | If a request has no real client certificate, the proxy takes the DN from the `x509CertificateDnHeader` header (default `X-SSL-CLIENT-S-DN`). It trusts that header from **any** source when `allowedCertificateProviders` is empty (`CertificateExtractorImpl.getDN`, `isRemoteHostTrustedCertProvider`). The receive config is global, so the proxy can't trust the header on one path (the mTLS listener) and not on another (the non-mTLS listener). | Anyone who can get the DN header to the proxy can claim any certificate identity. The ALB must stop the header arriving through the non-mTLS listener, and only the ALB may reach the proxy pods (section 5.3). Confirmed by test against 7.14-beta.8: a POST with no client certificate and a made-up `X-Stroom-Mtls-Subject` was accepted (200), and the receive log recorded `RemoteDN=` empty, so the claimed identity isn't even logged. **The current deployment should be tested for this** (section 15). |
| F15 | The image's own config serves the admin endpoints on port **8091** (`/proxyAdmin`). In 7.14 the downstream health checks are `stroom.proxy.app.handler.RemoteFeedStatusClient`, `stroom.proxy.app.ReceiveDataRuleSetClient`, `stroom.proxy.app.security.ProxyApiKeyCheckClient` and `stroom.proxy.app.handler.RemoteS3EventClient` (not `RemoteFeedStatusService`), registered whether or not a downstream is configured. `filteredhealthcheck` answers 500 for an unknown name in `deny`, and reads only one comma-separated `deny` value. | The admin port is 8091. Probes and target-group health checks deny those four checks and the IdP check (`stroom.security.common.impl.ExternalIdpConfigurationProvider`) in one list, so pods stay ready while a downstream or the IdP is down. |
| F16 | Jetty's SNI host check rejects any request whose Host doesn't match the server certificate (`400 Invalid SNI`). Behind the ALB, Host is the public name; the pod's certificate is self-signed. | The chart sets `disableSniHostCheck: true` on both HTTPS connectors. Without it, every request would fail. |
| F17 | The proxy won't start without an enabled forward destination. A destination with no `enabled` key is enabled for HTTP but **disabled** for file and S3 destinations (their JSON constructors default it to false). | The chart marks every destination `enabled: true` unless it says otherwise, and fails to render without one. |
| F18 | The S3 forwarder's default key template, `${type}/${year}/${month}/${day}/${idPath}/${feed}/${idPadded}.zip`, uses `${idPath}` and `${idPadded}`, which the forwarder doesn't supply; it supplies time variables, `${uuid}`, `${feed}`, `${type}` and `${receiptId}`. | The default doesn't give unique keys. The key template is always set, and must contain `${uuid}` or `${receiptId}` (section 7.1). |
| F19 | The ALB's default `xff_header_processing_mode` is `append`: it adds the client's address to any `X-Forwarded-For` the client sent. Jetty's forwarded-header handling takes the leftmost entry, which the client controls. | With `useForwardedHeaders`, any sender could write any address into the receive log. The ALB is set to `remove` X-Forwarded-For; the proxy logs the ALB's address, and ALB access logs (optional) keep the real client addresses (section 5.4). |

## 3. Architecture

```
   Senders on the private network (VPC, peering, VPN, Direct Connect)
   and senders in other VPCs / accounts (interface endpoints, PrivateLink)
          │ TCP 443                                   │ TCP 443
          │ mtls.proxy.…                              │ proxy.…
  ┌───────▼───────────────────┐         ┌─────────────▼─────────────┐
  │ VPC endpoint service (m)  │         │ VPC endpoint service (p)  │
  └───────┬───────────────────┘         └─────────────┬─────────────┘
  ┌───────▼───────────────────┐         ┌─────────────▼─────────────┐
  │ NLB-mtls (internal)       │         │ NLB-plain (internal)      │
  │ :443 → ALB :8443 (TCP)    │         │ :443 → ALB :443 (TCP)     │
  └───────┬───────────────────┘         └─────────────┬─────────────┘
  ┌───────▼───────────────────────────────────────────▼─────────────┐
  │ ALB (internal, ACM certificate for both host names)             │
  │ :8443 HTTPS, mTLS verify (trust store from S3 PEM)              │
  │        adds X-Stroom-Mtls-Subject: <client DN>                  │
  │ :443  HTTPS, no client certificate                              │
  │        rule: request has X-Stroom-Mtls-Subject → 403            │
  │ both: forward to the ACTIVE colour's target group               │
  │ :9443 / :9444 test listeners (mTLS / plain) → INACTIVE colour,  │
  │        admin_cidrs only, during an upgrade                      │
  └──────────────┬─────────────────────────────────┬────────────────┘
                 │ TargetGroupBinding (blue)        │ TargetGroupBinding (green)
  ┌──── VPC (3 AZs, private subnets) ─────────────────────────────────────────────┐
  │  blue proxy nodes (1 group per AZ)  green nodes (during an upgrade)           │
  │  ┌───────────┐┌───────────┐┌───────────┐   ┌─────────┐┌─────────┐┌─────────┐  │
  │  │proxy-b-0  ││proxy-b-1  ││proxy-b-2  │   │proxy-g-0││proxy-g-1││proxy-g-2│  │
  │  │:8443 HTTPS││  ...      ││  ...      │   │  ...    ││  ...    ││  ...    │  │
  │  │:8444 local││           ││           │   └─────────┘└─────────┘└─────────┘  │
  │  │:8091 admin││           ││           │                                      │
  │  │+ s3-sync  ││           ││           │   system nodes: CoreDNS, LB          │
  │  │+ log-sndr*││           ││           │   controller, ESO, EBS CSI           │
  │  │EBS gp3 PVC││EBS gp3 PVC││EBS gp3 PVC│   controller, CloudWatch             │
  │  └─────┬─────┘└─────┬─────┘└─────┬─────┘                                      │
  │        │ PutObject  │            ▲ GetObject (DFKs)                           │
  │        └─────┬──────┘            │                                            │
  └──────────────┼───────────────────┼────────────────────────────────────────────┘
                 ▼                   │
   ┌────────────────────────────┐ ┌──┴──────────────────────────┐
   │ data bucket: versioning +  │ │ receipt config bucket:      │
   │ Object Lock COMPLIANCE     │ │ dfk/*.json                  │
   │ (→ optional SQS notifi-    │ │ trust/client-ca.pem → ALB   │
   │    cations for Stroom)     │ └─────────────────────────────┘
   └────────────────────────────┘

   * log-sender: wired in, disabled until a released image exists (section 17.2)
   Load balancers sit in dedicated "lb" subnets; proxy pods accept traffic only from those.
```

## 4. Terraform layout

There are **three root stacks with separate state**:

* The `helm` and `kubernetes` providers can't be configured from a cluster created in the same apply without fragile `depends_on` tricks, so the cluster has its own stack.
* `kubernetes_manifest` resources for custom resources (`ExternalSecret`, `TargetGroupBinding`) fail at plan time if their CRDs aren't installed yet. So the operators that install the CRDs (`20-platform`) are applied before anything that uses them (`30-stroom-proxy`).
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
│   ├── platform/                      # LB controller, gp3 StorageClass, external-secrets, CloudWatch
│   └── stroom-proxy/                  # buckets, ALB, NLBs, PrivateLink, namespace, IAM pod identity, helm_release per colour
├── stacks/
│   ├── 10-infra/                      # network + eks   → outputs cluster name/endpoint/VPC ids/subnets/node colours
│   ├── 20-platform/                   # cluster operators and their CRDs (reads 10-infra outputs)
│   └── 30-stroom-proxy/               # the proxy and its AWS resources (reads 10-infra and 20-platform outputs)
├── envs/
│   └── example/                       # backend config and tfvars per stack
└── examples/
    ├── internal-default.tfvars        # both endpoints, S3 forwarding, PrivateLink off
    └── internal-privatelink.tfvars
```

* State: S3 backend with native S3 locking (`use_lockfile = true`), one state key per stack per environment. A small `bootstrap/` stack, or a manual step, creates the bucket.
* Providers: `aws` ~> 6.x, `helm` ~> 3.x, `kubernetes` ~> 2.x. Pin community modules to exact minor versions.
* Environments: a directory of tfvars per environment (`envs/dev`, `envs/prod`) rather than workspaces, so state keys and backends are explicit.

### 4.1 `10-infra`

* **network**: a new VPC across 3 AZs with three tiers of subnets:
  * **public** (NAT gateways);
  * **lb**: small private subnets (a /26 per AZ) used only by the ALB and the two NLBs, so proxy pods can be limited to traffic from these ranges (section 5.3);
  * **private** (nodes and pods).

  NAT gateways: `single` (cheap) or `one_per_az` (resilient). Optional VPC endpoints for S3, ECR, STS and CloudWatch Logs. Or set `existing_vpc_id` and the subnet ids (including `existing_lb_subnet_ids`) to skip VPC creation.
* **eks**: the cluster version is a variable (default: newest EKS standard-support version, 1.37 today). Use access entries (`API` auth mode) and give the cluster creator admin plus a list of `admin_principal_arns`. The API endpoint is private, plus a public endpoint only if `api_allowed_cidrs` is set. Logging control-plane events to CloudWatch is optional. KMS envelope encryption of Secrets is on.
* **Managed node groups** (AL2023 AMI, IMDSv2 required with hop limit 1):
  * **system**: untainted. It runs CoreDNS, the LB controller, External Secrets, the EBS CSI controller and the CloudWatch agent. `system_node_instance_type` (default `t3.medium`) and `system_node_count` (default 2). Updated in place by managed node group rolling updates, since nothing on it holds data.
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

* the AWS Load Balancer Controller (Helm chart, Pod Identity role). It is used only for its `TargetGroupBinding` resource, which registers proxy pod IPs in Terraform-owned ALB target groups (section 5);
* a `gp3` StorageClass (`WaitForFirstConsumer`, encrypted, `iops` and `throughput` from variables, `allowVolumeExpansion: true`), set as the default;
* the `amazon-cloudwatch-observability` add-on (Fluent Bit container logs, Container Insights);
* External Secrets Operator, with a Pod Identity role that can read only secrets under `secrets_name_prefix` (default `stroom-proxy/<name>/`, section 11). The `SecretStore` is created by `30-stroom-proxy` in the proxy namespace, because Terraform can't plan a custom resource in the same apply that installs its CRD.

Neither cert-manager nor external-dns is needed: the public server certificate is an ACM certificate on the ALB, and Terraform creates the Route 53 records for the NLBs directly.

### 4.3 `30-stroom-proxy`

* **S3**: the data bucket (versioning, Object Lock, SSE-KMS, bucket policy) and, unless an existing one is given, the receipt config bucket (section 7).
* **Load balancers**: the ALB with its listeners, rules, trust store, ACM certificate and security group; a target group per colour; the two NLBs with their ALB-type target groups and security groups; and the Route 53 records (section 5).
* **PrivateLink**: a VPC endpoint service per NLB, when enabled (section 5.4).
* **Kubernetes**: the namespace (`restricted` Pod Security label, `elbv2.k8s.aws/pod-readiness-gate-inject: enabled`), the Secrets Manager `SecretStore`, `ExternalSecret` objects, the NetworkPolicy, and a `TargetGroupBinding` per colour.
* **IAM**: the proxy's Pod Identity role and association.
* **Helm**: a `helm_release` per colour (`stroom-proxy-blue`, `stroom-proxy-green`), with values rendered from Terraform variables (section 13). There is no hand-edited values file.

## 5. Ingress: ALB, two NLBs and PrivateLink

### 5.1 Load balancers

All three load balancers are created by Terraform, not by the LB controller from Kubernetes objects. Blue/green needs listener actions that Terraform switches (section 9); the endpoint services, DNS records and security groups need the load balancers' ARNs and names at plan time; and `terraform destroy` removes them cleanly. The LB controller's `TargetGroupBinding` only keeps each colour's target group in step with that colour's pods.

All three are **internal** and sit in the **lb subnets**. (`load_balancer_scheme = "internet-facing"` puts the NLBs in the public subnets instead; it is opt-in and requires `allowed_ingress_cidrs` without `0.0.0.0/0`.)

**ALB**

| Listener | TLS | Default action | Notes |
|---|---|---|---|
| `:8443` mTLS | ACM certificate; mutual authentication **verify** mode with the trust store (5.2) | forward to the active colour's target group | The ALB rejects a TLS handshake without a valid client certificate. The client subject DN header is renamed to `X-Stroom-Mtls-Subject` (5.3). |
| `:443` plain | ACM certificate; no client certificate | forward to the active colour's target group | Rule (priority 1): any request carrying `X-Stroom-Mtls-Subject` or `X-Amzn-Mtls-*` → fixed 403 (5.3). Rule: path `/lb-health` → fixed 200, for the NLB health checks. |
| `:9443` test mTLS | as `:8443` | forward to the inactive colour's target group | Only while two colours exist (section 9.2). |
| `:9444` test plain | as `:443` | forward to the inactive colour's target group | As above, with the same 403 rule. |

* Security group: 443 and 8443 from the two NLBs' security groups; 9443 and 9444 from `admin_cidrs`.
* Target groups: one per colour, `target_type = ip`, HTTPS to pod port 8443, health check HTTP on 8091 at the chart's `healthCheckPath` (`/proxyAdmin/filteredhealthcheck?minimal=true&deny=…`, F15), `deregistration_delay` from a variable (default 120 s).
* Idle timeout `alb_idle_timeout` (default 300 s), long enough for slow uploads.
* Optional: `waf_web_acl_arn` associates an AWS WAF web ACL with the ALB.
* Access logs to an S3 bucket, optional.

**NLBs**

| NLB | Listener | Target group | Endpoint service |
|---|---|---|---|
| `nlb-mtls` | TCP `:443` | type `alb`, TCP port 8443 → the ALB's `:8443` listener | `privatelink.mtls` |
| `nlb-plain` | TCP `:443` | type `alb`, TCP port 443 → the ALB's `:443` listener | `privatelink.plain` |

* Both NLBs health-check the ALB over HTTPS on port 443 at `/lb-health`. The mTLS listener can't be used for this, because it would reject the health checker's connection, which has no client certificate.
* Security groups: 443 from `allowed_ingress_cidrs`. `enforce_security_group_inbound_rules_on_private_link_traffic = off`, because PrivateLink access is controlled by the endpoint services (5.4).

**Host names and certificate**: `hostname` (plain, e.g. `proxy.example.internal`) and `mtls_hostname` (e.g. `mtls.proxy.example.internal`) each get a Route 53 alias to their NLB when `route53_zone_id` is set. One ACM certificate on the ALB covers both names (`tls_certificate_source`: `acm_private_ca` through AWS Private CA (the default, for internal names), `acm_public` with DNS validation, `acm_existing` with a certificate ARN, or `acm_imported`, which imports a PEM certificate and key: for dev, with a throwaway test CA and made-up names, when there is no domain or Private CA. The key is then in Terraform state, and ACM can't renew an imported certificate). ACM renews the other kinds, with no restarts.

**From the ALB to the pods**: HTTPS on port 8443. The ALB doesn't validate target certificates, so each pod generates a self-signed certificate at start-up (init container). This keeps traffic encrypted inside the VPC without managing a certificate.

### 5.2 mTLS at the ALB

* **Trust store**: an `aws_lb_trust_store` whose CA bundle is `trust/client-ca.pem` in the receipt config bucket (section 7.2). Terraform passes the S3 object version, so a changed PEM is picked up on the next apply (`ModifyTrustStore`), without touching the proxies. Optional certificate revocation lists (`client_crl_s3_keys`) are added to the trust store the same way.
* **Verify mode**: the ALB checks the chain, validity dates and any revocation lists. `X-Amzn-Mtls-Clientcert-*` headers carry the leaf certificate's subject, issuer, serial and validity to the target. The subject header is renamed `X-Stroom-Mtls-Subject` (listener attribute `routing.http.request.x_amzn_mtls_clientcert_subject.header_name`), so it has a name nothing else uses.
* **The proxy** sets `receive.x509CertificateDnHeader: X-Stroom-Mtls-Subject` and `x509CertificateDnFormat: LDAP` (comma-separated), and leaves `allowedCertificateProviders` empty (F6). The ALB sends the DN in RFC 2253 form (`CN=client,OU=…,O=…`, most specific first, no spaces), so `CERTIFICATE_IDENTITY` entries in DFK files must match that form exactly.

### 5.3 Stopping forged DN headers (F14)

The proxy trusts the DN header on every request it receives (F14). The design blocks every other path for that header:

1. **Non-mTLS listener**: a priority-1 rule returns 403 for any request carrying `X-Stroom-Mtls-Subject` or any `X-Amzn-Mtls-*` header, whatever its value. Test listener `:9444` has the same rule.
2. **mTLS listener**: the ALB adds the header after verifying the certificate. Phase 4 tests confirm that a client-supplied `X-Stroom-Mtls-Subject` is replaced, not passed alongside. If it isn't, the same 403 rule is added there too: AWS evaluates rules on the client's request before adding mTLS headers. That ordering is also confirmed in testing.
3. **Direct to the pods**: a NetworkPolicy allows 8443 and 8091 **only from the lb subnets** (section 14). Pods, nodes and anything else in the VPC can't reach the proxy port, so they can't send the header around the ALB.
4. **In-pod callers** (the log-sender) use port 8444 on localhost. It is not exposed outside the pod.

A proxy change that let the DN header be trusted only on one connector would make this simpler (section 17.3).

### 5.4 PrivateLink and sender addresses

When `privatelink.enabled`, Terraform creates **two** `aws_vpc_endpoint_service` resources, one per NLB, so senders can use either authentication method over PrivateLink:

* `allowed_principals`: account, role or organisation ARNs that may create endpoints (shared by both services, or set per service);
* `acceptance_required` (default `true`): each new endpoint connection is accepted by an operator;
* private DNS names `mtls_hostname` and `hostname`, so senders use the same names as everyone else and the ALB certificate matches. AWS requires a TXT record in the domain's public DNS to verify ownership of each name. Terraform outputs them, and creates them if `privatelink.verification_zone_id` names a public Route 53 zone.

Senders create interface endpoints in their VPC, in subnets whose **AZ IDs** match the NLBs' (AZ names differ between accounts). PrivateLink traffic goes through the same ALB listeners and target groups, so blue/green switching applies to it too.

**Sender addresses**: the ALB removes `X-Forwarded-For` (`xff_header_processing_mode = remove`), because with its default (`append`) a client could put any address it liked first in the header, and Jetty would log that (F19). So the receive log records the ALB's address, not the sender's. Real client addresses are in the ALB access logs (`alb_access_logs_bucket`), for direct traffic; for PrivateLink traffic they would be the NLB's addresses anyway, as an ALB can't take PROXY protocol. The receive log still records the authenticated identity (certificate DN, token subject or DFK owner).

**ALB security group**: if the NLBs preserve client IPs to their ALB target, traffic reaches the ALB from the senders' addresses (or the NLBs' lb-subnet addresses over PrivateLink) rather than from the NLB security groups. The ALB therefore also accepts its listener ports from `allowed_ingress_cidrs` and the lb subnets; it is internal, and these are the same listeners and rules. Testing should confirm which applies.

## 6. Authentication and receipt options

| Endpoint | How senders authenticate |
|---|---|
| mTLS (`mtls_hostname`) | Client certificate, verified by the ALB; the proxy authenticates the DN (`CERTIFICATE`, or `CERTIFICATE_IDENTITY` with DFK files). A token or DFK on the same request is also accepted. |
| Plain (`hostname`) | OpenID Connect token (`TOKEN`) or data feed key (`DATA_FEED_KEY`). No certificate is asked for, and the forged-header rule (5.3) means `CERTIFICATE` can never succeed here. |

The proxy's receive config is shared by both endpoints. The variables map onto 7.14 `proxyConfig.receive`, `downstreamHost` and `security`:

| Variable | Proxy config | Notes |
|---|---|---|
| `auth.required` (bool, default `true`) | `receive.authenticationRequired` | `false` = anonymous receipt. Allowed only with `allowed_ingress_cidrs` not containing `0.0.0.0/0`. |
| `auth.types` (default `["CERTIFICATE", "TOKEN", "DATA_FEED_KEY"]`; also `CERTIFICATE_IDENTITY`) | `receive.enabledAuthenticationTypes` | Validated against the enum. |
| `auth.trust_store_pem_s3_key` | ALB trust store (5.2) | Key of the client CA bundle PEM in the receipt config bucket (default `trust/client-ca.pem`). Required if `CERTIFICATE` or `CERTIFICATE_IDENTITY` is set. |
| `auth.client_crl_s3_keys` | ALB trust store revocation | Optional list of CRL files in the receipt config bucket. |
| `auth.dfk_s3_prefix` | files in `receive.dataFeedIdentitiesDir` | Prefix of the DFK files in the receipt config bucket (default `dfk/`). Required if `DATA_FEED_KEY` or `CERTIFICATE_IDENTITY` is set without a downstream Stroom (section 7.2). |
| `auth.data_feed_owner_meta_key` | `receive.dataFeedOwnerMetaKey` | Default `AccountId`. |
| `auth.openid` (object: `issuer`, `openid_configuration_endpoint`, `allowed_audiences`, `client_id`, `unique_identity_claim`, …) | `security.authentication.openId` with `identityProviderType: EXTERNAL_IDP` | Required for `TOKEN` unless a downstream Stroom validates API keys. Works with Cognito, Entra ID, Keycloak and similar. The proxy fetches the IdP's JWKS, so it needs outbound HTTPS to it. |
| (fixed) | `receive.x509CertificateDnHeader`, `x509CertificateDnFormat` | `X-Stroom-Mtls-Subject`, `LDAP` (5.2). |
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
* `auth.required = false` is rejected when `allowed_ingress_cidrs` contains `0.0.0.0/0`.

## 7. S3

### 7.1 Data bucket: immutable once written

Forwarding goes to S3 only (`forward_s3`), and nothing else is forwarded by default. Once the proxy has written an object, nobody can change or delete it until its retention period has passed, not even the account root.

* **Object Lock in `COMPLIANCE` mode**, with versioning, and a default retention of `data_retention_days` applied to every new object version. The variable has **no default** and must be set per environment: in compliance mode the retention of a stored object can be extended but never shortened, and the bucket can't be deleted while it holds locked objects. A lifecycle rule (`noncurrent_version_expiration` and expiry of the current version after the retention period, optional) removes data once it is no longer locked.
* **The proxy role can only add objects**: `s3:PutObject`, `s3:PutObjectTagging` (the forwarder tags each object with its feed and stream type, F11), and, when multipart upload is enabled, `s3:AbortMultipartUpload` and `s3:ListMultipartUploadParts`. It has no read, delete, retention, legal-hold or bucket-configuration rights.
* **The bucket policy** denies any request without TLS, denies the proxy role every `s3:Delete*`, `s3:PutObjectRetention`, `s3:PutObjectLegalHold`, `s3:BypassGovernanceRetention` and `s3:PutBucket*` action (as a backstop to its IAM policy), and denies `s3:PutBucketObjectLockConfiguration` to everyone except `admin_principal_arns`.
* **Encryption**: SSE-KMS with a dedicated customer-managed key and S3 Bucket Keys. The proxy role gets `kms:GenerateDataKey`, plus `kms:Decrypt`, because S3 needs it to complete multipart uploads. The proxy still can't read objects, because it has no `s3:GetObject`. The key policy keeps key deletion to `admin_principal_arns`. Deleting the key would make the locked data unreadable.
* **Unique keys**: S3 can't be made to reject a put to an existing key unless the client sends `If-None-Match`, which the proxy doesn't (F11). A second put to the same key would create a new version on top; the earlier version would stay locked and retrievable, but the "current" object would change. So the forwarder's key template must include a per-batch unique value, and the proxy's default doesn't (F18). Terraform always sets it, by default to `${type}/${year}/${month}/${day}/${feed}/${uuid}.zip`, and a validation requires `${uuid}` or `${receiptId}`.
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
    ├── client-ca.pem    # client CA bundle, used by the ALB trust store
    └── *.crl            # optional revocation lists
```

Whoever manages senders writes the DFK files to this bucket. The PEM is uploaded by Terraform from `auth.client_ca_bundle_pem`, or, with an existing bucket, already there. Versioning is on, so the ALB trust store refers to an exact PEM version; the identity running Terraform reads it when it creates or updates the trust store. The bucket uses SSE-S3, so that needs no KMS grant. The proxy role can only read `dfk/*`.

**DFKs** reach each proxy pod through:

* an **init container** (`s3-sync`, the same image as the sidecar) that downloads the DFK files before the proxy starts, so it starts with every key in place;
* a **sidecar** (`s3-sync`) that compares the DFK prefix with the local directory every `dfk_sync_interval` (default 60 s). It downloads new or changed files to a temporary name and renames them into `dataFeedIdentitiesDir`, and deletes local files that have gone from S3. The proxy's directory watcher then adds, reloads or removes those keys without a restart (F10).

The sidecar image is a pinned `amazon/aws-cli` digest (or a small purpose-built image) running as uid 1000 under the `restricted` Pod Security Standard. Both write to an `emptyDir` shared with the proxy container.

**Trust-store PEM** changes are applied to the ALB (5.2) by the next `terraform apply`, which reads the PEM object's current version. No proxy restarts are needed. Adding a CA to the bundle ahead of time still avoids hurrying the change.

## 8. Pods, nodes and storage

* Each colour is a StatefulSet with `replicas` pods, spread one per node across that colour's per-AZ node groups (`topologySpreadConstraints` on zone with `maxSkew: 1`, a required `podAntiAffinity` on hostname, a nodeSelector on `stroom-proxy/colour`, and a toleration for the proxy taint). A StatefulSet, not a Deployment, because each proxy owns a durable queue on disk (receive store, aggregation, forward queues, retry).
* Each pod gets an EBS `gp3` PVC (`proxy_data_volume_gb`, `iops`, `throughput`) mounted at `/stroom-proxy/data`. EBS volumes are tied to one AZ; the per-AZ node groups make sure a pod can always come back in its volume's AZ.
* `persistentVolumeClaimRetentionPolicy: { whenScaled: Retain, whenDeleted: Retain }` keeps unsent data when replicas go down or a colour is removed.
* **Scaling up** is done in place: increase the colour's `replicas` (and `nodes_per_az` if needed) and apply.
* **Scaling down** is a blue/green switch to a new colour with fewer replicas (section 9.2). The old colour drains completely before it is removed, so no pod is ever removed while it holds unsent data.
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
| Client trust-store PEM, CRLs | ALB trust store update on apply (5.2) | None. |
| Server certificate | ACM renewal on the ALB | None. |
| EKS control plane (one minor version at a time) | In place, `cluster_version` in `10-infra` | None: only the Kubernetes API is briefly affected. Nodes may lag the control plane by up to three minor versions, so proxy nodes catch up at the next blue/green. |
| EKS add-ons | In place, after the control plane | None. Rolling DaemonSet updates don't affect running pods' networking. |
| System nodes | Managed node group rolling update | None. CoreDNS and the controllers have PDBs. |

### 9.2 Blue/green procedure

Each colour is a complete, independent proxy: its own node groups (`10-infra`), StatefulSet, PVCs and ALB target group (`30-stroom-proxy`). The load balancers, data feed keys, trust store and data bucket are shared.

Starting state: `blue` is the only colour and `active_colour = "blue"`.

1. **Add green.** Add `green` to `proxy_node_colours` in `10-infra` (new AMI, version or instance type as needed) and apply. Add `green` to `proxy_deployments` in `30-stroom-proxy` (new image, config or replica count) and apply. Green's pods start on green's nodes and register in green's target group. The test listeners `:9443` and `:9444` now point at green.
2. **Test green.** From `admin_cidrs`, send test data to the ALB's test listeners with each authentication type: certificate on `:9443`, token and DFK on `:9444`. Check it arrives in the data bucket.
3. **Switch.** Set `active_colour = "green"` and apply. Both ALB listeners (`:443` and `:8443`) now forward to green, and the test listeners point at blue. The ALB routes per request, so requests already in progress on blue finish there; new requests, including new requests on existing keep-alive connections, go to green. Optionally, `canary_weight` first sends a percentage of requests to green (weighted target groups) before the full switch.
4. **Drain blue.** Blue receives nothing new. It keeps closing its aggregates (within `aggregation.frequency`) and forwarding its queues to S3. `scripts/proxy-queue-status.sh blue` reports the unsent files per pod. Wait until every pod reports zero.
5. **Remove blue.** Remove `blue` from `proxy_deployments` and apply (the StatefulSet goes; its PVCs are retained). Delete blue's PVCs with `scripts/proxy-queue-status.sh blue --delete-empty-pvcs`, which deletes a PVC only if it is empty. Remove `blue` from `proxy_node_colours` and apply. Its nodes have no proxy pods left, so nothing is evicted.

**Rollback**: at any point before step 5, set `active_colour` back to `blue` and apply.

The next upgrade goes from green back to blue. Preconditions check that `active_colour` is in `proxy_deployments`, so the active colour can't be removed by mistake. They also check that every deployment has a node colour in the `10-infra` outputs, and that each colour's nodes can hold its replicas.

Proxy node cost doubles only between steps 1 and 5.

### 9.3 Draining a pod

This applies whenever a receiving pod stops: a rolling restart, `kubectl drain`, a managed node group update or a Spot interruption.

1. When the pod starts terminating, its EndpointSlice entry becomes not-ready, and the LB controller deregisters it from its target group. The ALB stops sending it new requests. Requests in progress get up to `deregistration_delay` (default 120 s) to finish.
2. A `preStop` hook sleeps for `deregistration_delay` + 15 s, so Jetty keeps serving while the ALB drains.
3. Jetty receives `SIGTERM`, stops accepting connections and waits up to Dropwizard's `shutdownGracePeriod` (set to 60 s) for in-flight requests to finish.
4. `terminationGracePeriodSeconds` is greater than the sum of the two (default 240 s).

An upload still running after that is cut off, and the sender retries. Data the proxy has acknowledged is on the PVC; the pod comes back on a node in the same AZ, with the same volume, and carries on forwarding.

The namespace has `elbv2.k8s.aws/pod-readiness-gate-inject: enabled`. A replacement pod therefore only counts as Ready once the ALB reports it healthy, and a rolling restart never has more than one pod out of service. The PodDisruptionBudget (`maxUnavailable: 1`) gives the same guarantee for evictions from node drains.

A Spot interruption gives only two minutes' notice, less than the drain takes with default settings. That is one more reason proxy nodes default to on-demand.

If a node fails outright, nothing drains. The data is still on the EBS volume. The pod is rescheduled in the same AZ, which can take several minutes while EBS force-detaches the volume. Senders retry against the remaining pods meanwhile.

### 9.4 Drained rolling restart

Rarely needed now that certificates and the trust store live on the ALB, but available for proxy settings that a blue/green would be heavy-handed for. The StatefulSet `RollingUpdate` restarts pods one at a time, highest ordinal first. Each pod drains as in 9.3, and the readiness gate holds the next restart until the replacement is healthy in the target group.

## 10. Helm chart

`charts/stroom-proxy` in `gchq/stroom-k8s-operator` is written from scratch, MIT like the rest of the repo: the gradata chart has no licence (F3). Its README documents the values. In outline:

1. **One release per colour.** `colour` suffixes resource names, labels pods `stroom-proxy/colour`, and pins them to the colour's nodes (nodeSelector plus a toleration for the proxy taint), so blue and green releases run side by side in one namespace.
2. **StatefulSet**, one pod per node (required anti-affinity), spread across zones (`maxSkew: 1`), `podManagementPolicy: Parallel`, `persistentVolumeClaimRetentionPolicy` Retain/Retain, a PodDisruptionBudget (`maxUnavailable: 1`). The data volume is mounted once at `/stroom-proxy/volume`, holding `data/`, `temp/` and `logs/`.
3. **Non-root, `restricted` PSS**: uid/gid 1000 (the image's `proxy` user, which owns `/stroom-proxy`, so the entrypoint's root-only `chown` path is skipped), `fsGroup: 1000` with `OnRootMismatch`, no privilege escalation, all capabilities dropped, `RuntimeDefault` seccomp.
4. **`proxyConfig` passthrough**: the `proxyConfig` value is the proxy's own config section, in its own keys, deep-merged with chart defaults (CERTIFICATE + TOKEN + DATA_FEED_KEY, `RECEIVE_ALL`, downstream off, the ALB's DN header). New proxy settings need no chart release. The chart forces the paths, the data feed identities directory and the directory scanner off, enables destinations that don't say otherwise and fails without one (F17). Secrets are referenced as `${NAME}` and supplied through `extraEnv` / `extraEnvFrom`. The pod gets `POD_NAME`, so `proxyId: <prefix>-${POD_NAME}` gives every pod its own stable proxy ID (used in receipt IDs; a shared ID could repeat receipt IDs across pods).
5. **Connectors**: 8443 HTTPS from the ALB (`useForwardedHeaders: true`, but the ALB removes the header, F19); 8444 HTTPS bound to `127.0.0.1` (in-pod callers); admin 8091 plain HTTP (F15). No client authentication in Jetty (the ALB checks certificates); SNI host check off (F16); `shutdownGracePeriod` from values.
6. **`tls` init container** (the proxy image's `keytool`): a self-signed certificate in a memory-backed `emptyDir`, kept across container restarts.
7. **DFK sync**: a `dfk-sync-init` init container and a `dfk-sync` native sidecar (`amazon/aws-cli`, pinned by digest, uid 1000, read-only root filesystem) running `files/s3-sync.sh` (section 7.2).
8. **Probes and draining**: startup, readiness and liveness probes on `healthCheckPath` (F15); a `preStop` sleep of the deregistration delay plus 15 s, and `terminationGracePeriodSeconds` covering it and Jetty's shutdown (section 9.3).
9. **Services**: a ClusterIP Service (ports `https`, `admin`) for the `TargetGroupBinding`, and a headless Service for the StatefulSet. No Ingress, no `LoadBalancer` Service.
10. **Logging**: console appenders for the application log, and (with `logging.consoleAppenders`, default on) for the receive, send and request logs, prefixed `receive`, `send`, `access`, so CloudWatch gets the receipt audit trail. Minute-rolled files on the volume as well.
11. **Images by digest**: `image.digest` renders `repository@sha256:…`; the image tag defaults to the chart's `appVersion`.
12. **Log-sender** container, off by default, posting to `https://localhost:8444/datafeed` (section 17.2).
13. A `checksum/config` pod annotation rolls the pods when the config changes.

The chart is released from `gchq/stroom-k8s-operator` alongside the operator charts (`oci://ghcr.io/gchq/helm-charts`). `30-stroom-proxy` references it by `chart_repository` and `chart_version`, with a local `chart_path` override (`../../charts/stroom-proxy`) for chart development.

**CI check** (`hack/validate-stroom-proxy-chart.sh`, a job in `build-helm-chart.yml`): renders the chart with each values file in `ci/`, runs the generated `config.yml` through the proxy image's own `check` command (which rejects unknown keys, F4), and boots the proxy as the pod would (non-root, generated keystore, the chart's volume layout) with the default values: the health check must answer 200 and an unauthenticated POST to `/datafeed` must get 401. This catches config drift whenever the proxy image changes. The boot test found F15, F16 and F17, which `check` alone doesn't.

## 11. Secrets

* DFKs and the trust-store PEM come from the receipt config bucket (section 7.2), and the public server certificate from ACM, not from Secrets Manager.
* Secrets Manager holds the rest: the OpenID client secret (if the IdP needs one) and the downstream API key (only with a downstream Stroom).
* Default delivery: External Secrets Operator with a Pod Identity role scoped to `arn:…:secret:stroom-proxy/<env>/*`. Terraform only creates `ExternalSecret` objects, so **no secret values end up in Terraform state**.
* Fallback for small or dev setups: `secret_delivery = "terraform"` reads the values with `aws_secretsmanager_secret_version` and writes `kubernetes_secret`. This puts the values in state, so the backend bucket must be encrypted and access-restricted. The README warns about it.
* The pod's self-signed certificate is generated at start-up in a memory-backed `emptyDir` and never stored. Its keystore password is a fixed chart value, not a secret: it protects a throwaway file, and the ALB doesn't verify target certificates.

## 12. Observability and operations

* **Logs**: the `amazon-cloudwatch-observability` add-on (Fluent Bit) collects container stdout. With the chart's `logging.consoleAppenders` (section 10, item 16), the application, receive, send and access logs all reach CloudWatch Logs, one log group per cluster with a retention variable (`log_retention_days`, default 90). The rolled log files under `/stroom-proxy/logs` on the PVC are posted back into the proxy by the log-sender once it is enabled (section 17.2). Optional ALB access logs record every request, including those the ALB rejected.
* **Metrics**: Dropwizard metrics on the admin port 8091. Container Insights gives node and pod metrics. ALB and NLB metrics (including mTLS handshake failures and target health per colour) are in CloudWatch.
* **Health**: the chart's probes use `/proxyAdmin/filteredhealthcheck`, denying the downstream and IdP checks (F15), so pods don't go unready (and get restarted by the liveness probe) when a downstream Stroom or the IdP is down; the proxy queues meanwhile. The ALB target groups use the same endpoint (section 5.1).
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
existing_vpc_id       = null                # + existing_private/public/lb_subnet_ids
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
log_retention_days = 90

# --- 30-stroom-proxy ---
proxy_deployments = {
  blue = {
    image_tag    = "v7.14-beta.8"
    image_digest = "sha256:…"               # from scripts/latest-proxy-tag.sh
    replicas     = 3
  }
}
active_colour = "blue"
canary_weight = 0                           # % of requests to the inactive colour during an upgrade

proxy_resources       = { requests = { cpu = "1", memory = "4Gi" }, limits = { cpu = "2", memory = "4Gi" } }
proxy_java_opts       = "-Xms2g -Xmx2g"
proxy_data_volume_gb  = 200
proxy_data_volume_iops       = 3000
proxy_data_volume_throughput = 250

load_balancer_scheme   = "internal"         # default; internet-facing is opt-in
allowed_ingress_cidrs  = ["10.0.0.0/8"]     # direct senders (VPN, peering, Direct Connect)
admin_cidrs            = ["10.1.2.0/24"]    # test listeners :9443 / :9444
hostname               = "proxy.example.internal"        # non-mTLS endpoint
mtls_hostname          = "mtls.proxy.example.internal"   # mTLS endpoint
route53_zone_id        = "Z0123456789"
tls_certificate_source = "acm_private_ca"   # acm_private_ca | acm_public | acm_existing | acm_imported
private_ca_arn         = "arn:aws:acm-pca:…"
alb_idle_timeout       = 300
deregistration_delay   = 120
waf_web_acl_arn        = null

privatelink = {
  enabled              = true
  allowed_principals   = ["arn:aws:iam::210987654321:root"]
  acceptance_required  = true
  verification_zone_id = null               # public zone for the ownership TXT records, if in Route 53
}

auth = {
  required               = true
  types                  = ["CERTIFICATE", "TOKEN", "DATA_FEED_KEY"]
  client_ca_bundle_pem   = "-----BEGIN CERTIFICATE-----\n…"   # uploaded to trust_store_pem_s3_key; or null with an existing receipt_config_bucket
  trust_store_pem_s3_key = "trust/client-ca.pem"
  client_crl_s3_keys     = []
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

Outputs: cluster name and endpoint, a `kubeconfig` command, the two datafeed URLs (`https://<hostname>/datafeed`, `https://<mtls_hostname>/datafeed`), the ALB test URLs, the NLB DNS names, the two endpoint service names and their private DNS verification records, the data bucket and SQS queue names, the receipt config bucket name, the namespace, and IAM role ARNs.

## 14. Security baseline

* Nodes sit in private subnets; load balancers in the lb subnets. The NLB security groups allow only `allowed_ingress_cidrs` on 443. PrivateLink access is limited by the endpoint services' allowed principals and acceptance. The ALB security group allows the listener ports only from the NLBs, and the test ports only from `admin_cidrs`. `TargetGroupBinding` adds node security group rules for 8443 and 8091 from the ALB security group. The node security group also allows node-to-node traffic, so it isn't what limits access to the pods: the NetworkPolicy is. The EKS API endpoint is private, plus a public endpoint only for `api_allowed_cidrs`.
* Client certificates are checked by the ALB in verify mode, against the trust store and any revocation lists. Forged DN headers are blocked as in section 5.3.
* The namespace enforces the `restricted` Pod Security Standard.
* A NetworkPolicy (enforced by the VPC CNI, section 4.1) allows ingress to proxy pods on 8443 and 8091 only from the lb subnets, and nothing on 8444. Because the proxy trusts the DN header (F14), a pod must never accept 8443 from anything other than the ALB (section 5.3). Egress is unrestricted in v1, since the proxy needs DNS, S3, the IdP's JWKS endpoint and AWS APIs.
* IMDSv2 is required with hop limit 1, so pods can't use the node role. All AWS access goes through Pod Identity. The proxy role can write to the data bucket and read the DFK prefix, and nothing else (section 7).
* Data in S3 is immutable for its retention period (section 7.1). EBS volumes, EKS Secrets and both buckets are encrypted with KMS. The state bucket is encrypted and versioned.
* Optional AWS WAF on the ALB.
* Images are pinned by digest (F1). Optional: mirror to ECR with a pull-through cache to avoid Docker Hub rate limits and give a private pull path.

## 15. Decisions

Agreed 2026-10-29; the rows from **PrivateLink** down were added or revised the same day after review comments.

| Topic | Decision |
|---|---|
| Helm chart | A new `charts/stroom-proxy` in `gchq/stroom-k8s-operator`, written from scratch (the gradata chart has no licence, F3), MIT (section 10). Terraform references it by chart repo and version. |
| Code location | `gchq/stroom-k8s-operator`: Terraform in `terraform/aws-eks-proxy/`, this design in `design/`. |
| Image | Pin `v7.14-beta.8` plus digest. Move to `v7.14.0` when it ships. Never use `v7.14-LATEST`. |
| VPC | A new 3-AZ VPC by default, with public, lb and private subnets. `existing_vpc_id` + subnet ids switch to an existing one. |
| Secrets | Secrets Manager → External Secrets Operator by default. `secret_delivery = "terraform"` fallback for dev (values in state). |
| Logs | All proxy logs to stdout and CloudWatch. Rolled log files posted back into the proxy by the non-root log-sender once enabled. |
| System nodes | A small untainted system node group (2 × `t3.medium`) runs the cluster services. |
| Autoscaling | None in v1: pod and node counts are fixed by variables. |
| **Ingress** | Mirror the current deployment: one internal ALB with an mTLS-verify listener and a non-mTLS listener; two internal NLBs forwarding 443 to them; Terraform owns all three. ALB target group per colour, bound with `TargetGroupBinding`. ACM server certificate. |
| **PrivateLink** | Two VPC endpoint services, one per NLB, so senders can use either authentication method over PrivateLink. Allowed principals, acceptance required by default, private DNS names `hostname` and `mtls_hostname`. |
| **DN header safety** | Rename the ALB's subject header, reject it on the non-mTLS listener, and only let the lb subnets reach the pods (section 5.3). |
| **Authentication** | mTLS endpoint: certificate checked by the ALB, DN passed to the proxy. Non-mTLS endpoint: token and DFK only. DFKs come from S3, synced live into each pod. The trust-store PEM in S3 feeds the ALB trust store. |
| **Forwarding** | S3 only by default, to a data bucket with Object Lock in `COMPLIANCE` mode and a required `data_retention_days`. The proxy role can only put objects. New objects are announced on an SQS queue. Downstream Stroom is optional and off by default (`RECEIVE_ALL`). |
| **Upgrades** | Blue/green: each colour has its own per-AZ proxy node groups, StatefulSet and ALB target group. Terraform switches both ALB listeners, optionally after a weighted canary; the old colour drains its queues before it is removed. Platform upgrades (control plane, add-ons, system nodes) are in place. |
| **Draining** | `preStop` sleep longer than the target group deregistration delay, Dropwizard graceful shutdown, pod readiness gates and a PDB, so a pod never stops while the ALB is still sending it requests. |
| **Log sender** | Wire in the non-root, supercronic-based log-sender that already exists on a branch, disabled by default until a released image exists. |
| **Buckets** | Terraform creates the data and receipt config buckets by default; existing buckets can be named instead. |

Open items:

* **Test the current deployment for F14**: send a request to its non-mTLS listener with a made-up DN in the subject header it uses (e.g. `X-Amzn-Mtls-Clientcert-Subject: CN=someone-else`). If the proxy accepts it as certificate authentication, the current deployment allows identity spoofing and needs the section 5.3 rule now.
* The branch and image name of the non-root log-sender, and when it will be released.
* `data_retention_days` per environment.
* To confirm in testing: the ALB replaces a client-supplied subject header on the mTLS listener (5.3), and whether the NLB preserves client IPs to its ALB target (5.4).

## 16. Implementation phases

1. `10-infra`: VPC with public, lb and private subnets, EKS, system node group, add-ons, per-colour proxy node groups (one per AZ per colour). Done when `kubectl get nodes` shows a proxy node in each AZ for the colour, and the system pods are running.
2. `20-platform`: LB controller, gp3 StorageClass, CloudWatch add-on, External Secrets.
3. Write `charts/stroom-proxy` (section 10), with a CI check that renders it, validates the generated config with the proxy image and boots the proxy.
4. `30-stroom-proxy` with one colour: the data bucket with Object Lock and SQS notifications, the receipt config bucket, the ALB with both listeners and the trust store, the two NLBs, both endpoint services, S3 forwarding, NetworkPolicy. Done when:
   * a request with a valid client certificate to `https://<mtls_hostname>/datafeed` returns 200, and one without a certificate fails the TLS handshake;
   * requests to `https://<hostname>/datafeed` with an OIDC token and with a DFK return 200, and one with neither is refused;
   * a request to `https://<hostname>/datafeed` carrying a forged subject header gets 403, on its own and together with a valid token;
   * a request to a pod's 8443 from inside the cluster (not through the ALB) is blocked;
   * the data arrives in the data bucket, and neither the proxy role nor an admin can delete it or change a stored version;
   * a DFK added to S3 works within `dfk_sync_interval`, and one removed from S3 stops working; a CA added to the PEM in S3 is trusted after `terraform apply`;
   * the same requests work through both PrivateLink endpoints from another VPC;
   * receive log lines are visible in CloudWatch.
5. Blue/green and draining: canary weights, `proxy-queue-status.sh`, `latest-proxy-tag.sh` and runbooks. The second colour, the test listeners, the listener switch, the drain settings and the `terraform test` suites were done in phase 4: the inactive colour's target group needs a listener for its health checks to run, so the test listeners couldn't wait. Done when a blue → green → blue cycle under continuous test traffic on both endpoints loses no acknowledged data and senders see no errors other than retried resets.
6. Other options: downstream Stroom with `RECEIPT_POLICY` and HTTP forwarding, internet-facing NLBs with public ACM certificates, WAF, `terraform` secret delivery.

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

* it posts to `https://localhost:8444/datafeed`, the in-pod connector (section 5.3);
* it authenticates with a DFK from the same S3-synced directory.

Logs then go through the proxy's own queue and forwarding into the data bucket. Once it is enabled everywhere, `logging.consoleAppenders` can default to `false` for the receive and send logs, so they aren't stored twice.

### 17.3 Stroom-Proxy changes

These would need GitHub issues raised by a person:

* **DN header trust per connector**: let `x509CertificateDnHeader` be honoured only on a named connector (or only from configured CIDR ranges), so the proxy itself can refuse DN headers that didn't come through the mTLS listener (F6, F14).
* **Record the DN used for authentication**: a request authenticated by DN header is logged with `RemoteDN=` empty (F14), so the audit trail doesn't show which identity was claimed.
* **Consistent `enabled` defaults for forward destinations**: file and S3 destinations without `enabled` are disabled, HTTP ones enabled (F17).
* **A unique default S3 key template**: the default uses `${idPath}` and `${idPadded}`, which the S3 forwarder doesn't supply (F18).
* **Tolerant health check filters**: `filteredhealthcheck` answers 500 for an unknown check name in `deny` (F15), so a renamed check makes every pod unready.
* **Full certificate from a load balancer header**: parse the URL-encoded PEM in `X-Amzn-Mtls-Clientcert-Leaf` (F5), so the proxy can use the whole certificate, not just the DN.
* **arm64 image**: publish `gchq/stroom-proxy` for arm64, to allow cheaper Graviton nodes (F2).
* **Drain mode**: an admin task or endpoint that closes open aggregates immediately and reports when all queues are empty. This would shorten step 4 of blue/green and replace the file counting in `proxy-queue-status.sh`.
* **`If-None-Match` on S3 puts**: send `If-None-Match: *`, so the data bucket policy can require it and reject any overwrite (F11).
* **Release pipeline**: `v7.14-LATEST` should only follow release builds, not branch builds (F1).

### 17.4 Platform

* Mirroring images into ECR (pull-through cache), for private pulls and to avoid Docker Hub rate limits.
* Restricting egress in the NetworkPolicy to known destinations.
* Full-cluster blue/green (a second cluster behind the same endpoint services), for changes that can't be made in place.
* Multi-region deployment.
