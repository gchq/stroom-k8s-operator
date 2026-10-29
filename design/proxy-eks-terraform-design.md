# Stroom-Proxy 7.14 on AWS EKS with Terraform: design

Status: design agreed (2026-10-29, see section 13). No Terraform has been written yet.

## 1. Goal

Terraform that takes an empty AWS account (or an existing VPC) and produces:

* an EKS cluster with a managed node group whose EC2 instance type and size are inputs;
* Stroom-Proxy 7.14 (image `gchq/stroom-proxy` from Docker Hub) with a configurable number of pods;
* an HTTPS endpoint on port 443 that accepts data (`/datafeed`, `/stroom/datafeed`);
* inputs that choose how senders authenticate (client certificate, data feed key, token or API key, or none) and how data is checked and forwarded.

Out of scope for the first version: Stroom itself, multi-region, and autoscaling the pod count from load.

## 2. Findings that shape the design

These came from the 7.14 source, Docker Hub and the public Helm charts. Each one changes a decision below.

| # | Finding | Consequence |
|---|---------|-------------|
| F1 | There is no 7.14 GA release yet. The newest tag is `v7.14-beta.8` (16 Oct 2026). The floating tag `v7.14-LATEST` has the same digest as `v7.14-beta.8-parallel-pathways`, a branch build, not `v7.14-beta.8`. | Never deploy a floating tag. Terraform pins an explicit tag plus digest (`image_tag`, `image_digest`). A helper script finds the newest `v7.14.N` / `v7.14-beta.N` tag. |
| F2 | The `gchq/stroom-proxy` image is published for `amd64` only. | Graviton (`*g` families such as `m7g`, `c7g`) cannot be used. A variable validation rejects them. |
| F3 | The only existing stroom-proxy Helm chart is `gradata-systems/stroom-helm-charts` → `charts/stroom-proxy` (chart 1.2.13, appVersion `v7.10.5`, last pushed 31 Mar 2026; formerly `p-kimberley/stroom-kubernetes`). `gchq/stroom-k8s-operator` (a fork of `gradata-systems/stroom-k8s-operator`) has only the operator and CRD charts, and its custom resources cover Stroom clusters, databases, backups and task autoscaling, not Stroom-Proxy. There is no `gchq/stroom-k8s` repo. | The gradata chart (Apache 2.0) is copied into `gchq/stroom-k8s-operator` as `charts/stroom-proxy` and updated there for 7.14 (section 8). The Terraform lives in the same repo. |
| F4 | That chart does not boot 7.14 as written: it always renders `proxyConfig.feedStatus.enabled` and `.apiKey`, which no longer exist in 7.14 (`feedStatus` only has `url` and `feedStatusCache`; the API key moved to `downstreamHost.apiKey`). Proxy enables `FAIL_ON_UNKNOWN_PROPERTIES` (`App.java:147`), so unknown keys stop start-up. It also has no values for `enabledAuthenticationTypes`, `receiptCheckMode`, `downstreamHost`, data feed identities, OpenID or S3 forwarding. | The chart needs a 7.14 update (section 8). |
| F5 | The proxy reads `receive.x509CertificateHeader` as a servlet request attribute, not as a PEM string in an HTTP header (`CertificateExtractorImpl.extractCertificate`). Only the DN header (`x509CertificateDnHeader`) works when a load balancer ends TLS. | If TLS ends at an AWS load balancer, certificate authentication can only use the DN header, which then has to be protected. TLS passthrough to the pod avoids this (section 5). |
| F6 | `allowedCertificateProviders` accepts IP addresses or host names, not CIDR ranges. ALB node IPs change. | Behind an ALB, the DN-header trust check cannot be pinned to the ALB. Pod security groups or a NetworkPolicy have to do that job. |
| F7 | S3 forwarding and SQS ingest use the AWS SDK default credential chain (`AwsCredentialsHelper`). | EKS Pod Identity works with no proxy changes. |
| F8 | The chart's log-sender sidecar runs as root with `privileged: true`. | Turn it off by default (it fails the EKS `restricted` Pod Security Standard). Ship proxy logs another way (section 10). |
| F9 | ingress-nginx, which the chart's Ingress template assumes, was retired by Kubernetes SIG Network in March 2026. | Don't use the chart's Ingress. Expose the Service through the AWS Load Balancer Controller. |

## 3. Architecture

```
                 Internet / partner networks (allowed_ingress_cidrs)
                                   │  TCP 443
                     ┌─────────────▼──────────────┐
  Route 53 ─────────►│  NLB (internet or internal)│  one per AZ subnet (public or private)
  proxy.example.com  │  TCP 443 → pod 8443         │  TLS passthrough, client IP preserved
                     └─────────────┬──────────────┘
         ┌───────────────── VPC (3 AZs) ┼─────────────────────────────────────┐
         │   private subnets            │                                     │
         │  ┌──────────────┐  ┌─────────▼────┐  ┌──────────────┐            │
         │  │ node (AZ a)  │  │ node (AZ b)  │  │ node (AZ c)  │ managed    │
         │  │ proxy-0      │  │ proxy-1      │  │ proxy-2      │ node group │
         │  │  Jetty TLS   │  │  ...         │  │  ...         │ instance   │
         │  │  :8443 (mTLS)│  │              │  │              │ type = var │
         │  │  :8090 admin │  │              │  │              │            │
         │  │  EBS gp3 PVC │  │  EBS gp3 PVC │  │  EBS gp3 PVC │            │
         │  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘            │
         │         └─────── forward (HTTPS / S3 / file) ┼───────────────────►│ downstream Stroom
         │                                              │                    │ or S3 bucket
         │  NAT GW ◄── image pulls (Docker Hub), IdP JWKS, downstream calls  │
         └───────────────────────────────────────────────────────────────────┘
   Add-ons: vpc-cni, coredns, kube-proxy, aws-ebs-csi-driver, eks-pod-identity-agent,
            aws-load-balancer-controller, (optional) cert-manager, external-dns,
            external-secrets, amazon-cloudwatch-observability
```

## 4. Terraform layout

There are **three root stacks with separate state**:

* The `helm` and `kubernetes` providers can't be configured from a cluster created in the same apply without fragile `depends_on` tricks, so the cluster has its own stack.
* `kubernetes_manifest` resources for custom resources (`Certificate`, `ExternalSecret`, `ClusterIssuer`) fail at plan time if their CRDs aren't installed yet. So the operators that install the CRDs (`20-platform`) are applied before anything that uses them (`30-stroom-proxy`).
* A cluster rebuild shouldn't force workload churn, and the other way round.

```
stroom-k8s-operator/terraform/aws-eks-proxy/   # in gchq/stroom-k8s-operator, next to charts/stroom-proxy
├── README.md
├── scripts/
│   └── latest-proxy-tag.sh            # finds newest v7.14 tag + digest on Docker Hub (F1)
├── modules/
│   ├── network/                       # wraps terraform-aws-modules/vpc
│   ├── eks/                           # wraps terraform-aws-modules/eks (cluster, node group, add-ons, access entries)
│   ├── platform/                      # LB controller, gp3 StorageClass, cert-manager, external-dns, external-secrets, CloudWatch
│   └── stroom-proxy/                  # namespace, ExternalSecrets, Certificate, NetworkPolicy, IAM pod identity, helm_release
├── stacks/
│   ├── 10-infra/                      # network + eks   → outputs cluster name/endpoint/VPC ids
│   │   ├── main.tf  variables.tf  outputs.tf  versions.tf  backend.tf
│   ├── 20-platform/                   # cluster operators and their CRDs (reads 10-infra outputs)
│   │   ├── main.tf  variables.tf  outputs.tf  versions.tf  backend.tf
│   └── 30-stroom-proxy/               # the proxy and its custom resources (reads 10-infra and 20-platform outputs)
│       ├── main.tf  variables.tf  outputs.tf  versions.tf  backend.tf
└── examples/
    ├── internal-cert-and-datafeed-key.tfvars   # the default deployment
    ├── internet-mtls-only.tfvars               # internet-facing, client_cert_mode = need
    └── internal-token-oidc.tfvars
```

* State: S3 backend with native S3 locking (`use_lockfile = true`), one state key per stack per environment. A small `bootstrap/` stack, or a manual step, creates the bucket.
* Providers: `aws` ~> 6.x, `helm` ~> 3.x, `kubernetes` ~> 2.x. Pin community modules to exact minor versions.
* Environments: a directory of tfvars per environment (`envs/dev`, `envs/prod`) rather than workspaces, so state keys and backends are explicit.

### 4.1 `10-infra`

* **network**: a new VPC across 3 AZs with public and private subnets tagged for the LB controller (`kubernetes.io/role/elb`, `kubernetes.io/role/internal-elb`). NAT gateways: `single` (cheap) or `one_per_az` (resilient). Optional VPC endpoints for S3, ECR, STS and CloudWatch Logs. Or set `existing_vpc_id` and subnet ids to skip VPC creation.
* **eks**: the cluster version is a variable (default: newest EKS standard-support version). Use access entries (`API` auth mode) and give the cluster creator admin plus a list of `admin_principal_arns`. The API endpoint is private plus a public endpoint restricted to `api_allowed_cidrs`. Logging control-plane events to CloudWatch is optional. KMS envelope encryption of Secrets is on.
* **Two managed node groups** (AL2023 AMI, IMDSv2 required with hop limit 1):
  * **system**: untainted. It runs CoreDNS, the LB controller, cert-manager, External Secrets, external-dns, the EBS CSI controller and the CloudWatch agent. `system_node_instance_type` (default `t3.medium`) and `system_node_count` (default 2, spread across AZs).
  * **proxy**: labelled and tainted `workload=stroom-proxy:NoSchedule`, so only proxy pods (which tolerate the taint) run there.
    * `node_instance_types` (list, e.g. `["m6i.xlarge"]`), `node_capacity_type` (`ON_DEMAND` by default; `SPOT` is allowed but warned against because proxies hold unsent data);
    * `node_min_size`, `node_desired_size`, `node_max_size`;
    * `node_root_volume_gb`;
    * validation rejects Graviton families (F2).

  DaemonSets that must run on every node (VPC CNI, kube-proxy, EBS CSI node, Pod Identity agent, Fluent Bit) tolerate all taints by default or are configured to.
* **Add-ons** (EKS managed): `vpc-cni` (with `enableNetworkPolicy: true`, needed for the NetworkPolicy in section 12), `coredns`, `kube-proxy`, `aws-ebs-csi-driver` (with a Pod Identity role) and `eks-pod-identity-agent`.

### 4.2 `20-platform`

All of these run on the system node group:

* the AWS Load Balancer Controller (Helm chart, Pod Identity role);
* a `gp3` StorageClass (`WaitForFirstConsumer`, encrypted, `iops` and `throughput` from variables, `allowVolumeExpansion: true`), set as the default;
* the `amazon-cloudwatch-observability` add-on (Fluent Bit container logs, Container Insights);
* External Secrets Operator, with a `ClusterSecretStore` for Secrets Manager (the default secret delivery, section 9);
* cert-manager with a `ClusterIssuer`, when `tls_certificate_source` is `cert_manager_acme` (Route 53 DNS-01) or `cert_manager_private_ca` (`aws-privateca-issuer`);
* external-dns for the Route 53 record, when `route53_zone_id` is set.

### 4.3 `30-stroom-proxy`

* The namespace, with the `restricted` Pod Security label.
* `ExternalSecret` objects (or plain `kubernetes_secret` in `terraform` delivery mode).
* A `Certificate` for the server certificate, when cert-manager issues it.
* The NetworkPolicy (section 12).
* The Pod Identity association for S3 forwarding or SQS ingest.
* A `helm_release` whose values are rendered from Terraform variables (section 11). There is no hand-edited values file.

## 5. Ingress on 443 and TLS

| Option | How | Certificate auth | Pros | Cons |
|---|---|---|---|---|
| **A. NLB TLS passthrough (recommended)** | `Service type=LoadBalancer`, LB controller annotations: `aws-load-balancer-type: external`, `nlb-target-type: ip`, `scheme`, listener 443 → targetPort 8443, `source-ranges`, `target-group-attributes: preserve_client_ip.enabled=true` | Jetty does mTLS itself (`wantClientAuth`/`needClientAuth`), so the proxy sees the real certificate. Every auth type works. | No header trust problem (F5, F6). Same model as bare-metal and Docker deployments. Long uploads are not cut off by an L7 idle timeout. Real client IP in the receive log. | Server certificate must be in the cluster (cert-manager or supplied), not ACM. No AWS WAF. |
| B. ALB with mTLS verify | Ingress (`alb` class), ACM certificate, ALB trust store from the client CA bundle in S3, backend HTTPS | DN only, through `X-Amzn-Mtls-Clientcert-Subject` → `x509CertificateDnHeader`, format `LDAP` | ACM-managed certificate, WAF, ALB access logs. | Header spoofing has to be blocked with pod security groups (F6). The full certificate isn't available to the proxy. 4000 s idle timeout limit. |
| C. ALB, TLS only, no client certs | As B without a trust store | none | Simplest for `DATA_FEED_KEY` or `TOKEN` only. | No certificate auth. |

Decision: build **A** only. B and C are recorded for a later version if WAF or ACM certificates become a requirement (section 15). The NLB is `internal` by default (`load_balancer_scheme`).

**NLB health check**: HTTP on the admin port 8090, path `/proxyAdmin/filteredhealthcheck?deny=stroom.proxy.app.handler.RemoteFeedStatusService` (LB controller annotations `healthcheck-protocol`, `healthcheck-port`, `healthcheck-path`). A TCP check on 8443 would pass while the proxy is unhealthy.

**Client IP preservation**: with `preserve_client_ip.enabled=true`, packets reach the pod with the sender's own address, not the NLB's. Security groups and the NetworkPolicy therefore allow `allowed_ingress_cidrs`, not just the VPC range (section 12).

**Server certificate sources** (`tls_certificate_source`):

* `cert_manager_acme`: Let's Encrypt through Route 53 DNS-01, for internet-facing endpoints.
* `cert_manager_private_ca`: AWS Private CA, for internal endpoints.
* `existing_secret`: the name of a `kubernetes.io/tls` Secret supplied out of band.
* `secrets_manager`: a PEM certificate, key and chain in Secrets Manager, synced through External Secrets.

The client CA bundle (`client_ca_bundle_pem`, or a Secrets Manager ARN) goes into the trust store. The chart's init container already builds the PKCS12 keystore and trust store from `tls.crt`, `tls.key` and `ca.crt`. That needs changing so `ca.crt` (the server chain) and the client CA bundle are separate keys.

**DNS**: `hostname` is required. If `route53_zone_id` is set, external-dns (or a plain `aws_route53_record` alias to the NLB found with a data source) creates the record.

## 6. Authentication and receipt options

The variables map directly onto 7.14 `proxyConfig.receive`, `downstreamHost` and `security`:

| Variable | Proxy config | Notes |
|---|---|---|
| `auth.required` (bool, default `true`) | `receive.authenticationRequired` | `false` = anonymous receipt. Allowed only with `allowed_ingress_cidrs` not containing `0.0.0.0/0`. |
| `auth.types` (set of `CERTIFICATE`, `CERTIFICATE_IDENTITY`, `DATA_FEED_KEY`, `TOKEN`) | `receive.enabledAuthenticationTypes` | Validated against the enum. |
| `auth.client_cert_mode` (`want`, `need`) | Jetty `wantClientAuth` / `needClientAuth` | `need` refuses the TLS handshake without a certificate, which suits certificate-only deployments. |
| `auth.client_ca_bundle` | trust store | Required if `CERTIFICATE` or `CERTIFICATE_IDENTITY` is set. |
| `auth.data_feed_identities` (map of file name → JSON, or a Secrets Manager ARN) | files in `receive.dataFeedIdentitiesDir` | For `DATA_FEED_KEY` and `CERTIFICATE_IDENTITY` without a downstream Stroom. Mounted read-only from a Secret. |
| `auth.data_feed_owner_meta_key` | `receive.dataFeedOwnerMetaKey` | Default `AccountId`. |
| `auth.openid` (object: `issuer`, `openid_configuration_endpoint`, `allowed_audiences`, `client_id`, `unique_identity_claim`, …) | `security.authentication.openId` with `identityProviderType: EXTERNAL_IDP` | For `TOKEN` with an external IdP (Cognito, Entra ID, Keycloak). |
| `downstream.url` | `downstreamHost.{scheme,hostname,port,pathPrefix}` | Downstream Stroom (or proxy). |
| `downstream.api_key_secret_arn` | `downstreamHost.apiKey` (from an env var) | Used for feed status, receipt policy, API key verification and data feed key fetch. |
| `receipt.check_mode` (`FEED_STATUS`, `RECEIPT_POLICY`, `FEED_EXISTENCE`, `RECEIVE_ALL`, `DROP_ALL`, `REJECT_ALL`) | `receive.receiptCheckMode` | The first three need `downstream`. |
| `receipt.fallback_action` | `receive.fallbackReceiveAction` | Used when downstream can't be reached. |
| `receive.max_request_size` | `receive.maxRequestSize` | |
| `receive.feed_name_generation` (object) | `receive.feedNameGeneration*`, `feedNameTemplate` | |

Terraform `validation` blocks catch inconsistent combinations before apply:

* `TOKEN` needs `openid` (OAuth tokens) or `downstream` (Stroom API keys).
* `FEED_STATUS`, `RECEIPT_POLICY` and `FEED_EXISTENCE` need `downstream`.
* `DATA_FEED_KEY` and `CERTIFICATE_IDENTITY` need `downstream` (keys fetched from Stroom) or `data_feed_identities` (local files). This matters when `downstream = null`.
* `CERTIFICATE` and `CERTIFICATE_IDENTITY` need a client CA bundle.
* `client_cert_mode = "need"` with only key or token types is rejected, because it would refuse senders that have no certificate.
* `auth.required = false` is rejected when `allowed_ingress_cidrs` contains `0.0.0.0/0`.

## 7. Pods, nodes and storage

* `proxy_replicas` sets the StatefulSet replica count. A StatefulSet, not a Deployment, because each proxy owns a durable queue on disk (receive store, aggregation, forward queues, retry).
* Each pod gets an EBS `gp3` PVC (`proxy_data_volume_gb`, `iops`, `throughput`) mounted at `/stroom-proxy/data`. EBS volumes are tied to one AZ, so after first scheduling a pod is pinned to the AZ of its volume. `topologySpreadConstraints` (zone, `maxSkew: 1`) plus a `podAntiAffinity` preference on hostname spread pods across AZs and nodes.
* `persistentVolumeClaimRetentionPolicy: { whenScaled: Retain, whenDeleted: Retain }` keeps unsent data when replicas go down or the release is removed. A retained PVC is reattached if the replica count goes back up, so data is never lost, only held until then.
* **Scaling down in v1** is a runbook step, because the proxy has no "stop receiving, finish forwarding" switch (section 15):
  1. Take the highest-numbered pods out of the NLB by setting their `stroom-proxy/receiving` label to `"false"` (`kubectl label pod … --overwrite`). The chart gives every pod `stroom-proxy/receiving: "true"` and the Service selects on it (section 8, item 12), so the relabelled pod stops getting new connections but keeps forwarding. The label must not be part of the StatefulSet's own selector. A pod restart resets it to `"true"`, so relabel if the pod restarts during the drain.
  2. Watch the pod's forward queue directories (or the send log) until they are empty.
  3. Reduce `proxy_replicas` and apply.
  4. Delete the retained PVC once it is confirmed empty.

  Terraform can't safely do this alone, and the README says so plainly.
* **Destroy**: because of `whenDeleted: Retain`, `terraform destroy` leaves the proxy EBS volumes behind. They keep costing money until deleted. This is deliberate, so unsent data survives, and the README lists the cleanup command (volumes are tagged with the cluster name and PVC name).
* A PodDisruptionBudget (`maxUnavailable: 1`) protects against node group upgrades and drains.
* Sizing: `proxy_resources` (requests and limits) and `proxy_java_opts` are inputs, with a default heap of 50–60 % of the memory limit. A `check` block warns when `node_desired_size × allocatable` can't fit `proxy_replicas × requests`. (Approximate: it uses a small built-in table of instance vCPU and memory for common families, or the `aws_ec2_instance_type` data source.)
* The proxy node group should keep `node_desired_size ≥ number of AZs`, so every AZ that holds a volume has a node. A validation enforces it.

Pod-count autoscaling (HPA) is deliberately out of scope because of the on-disk queues. Node-count autoscaling (Karpenter or Cluster Autoscaler) can come later.

## 8. Helm chart

The gradata `stroom-proxy` chart (F3) is copied into `gchq/stroom-k8s-operator` at `charts/stroom-proxy`, keeping its Apache 2.0 licence and crediting its origin in the chart README. The changes needed for 7.14 are then made there:

1. Remove `feedStatus.enabled` and `feedStatus.apiKey`. Add a `downstreamHost` block with `apiKey: ${DOWNSTREAM_API_KEY}` (F4).
2. Add values for `receive.enabledAuthenticationTypes`, `receiptCheckMode`, `fallbackReceiveAction`, `dataFeedIdentitiesDir` (+ Secret mount), `dataFeedOwnerMetaKey`, `allowedCertificateProviders` and `maxRequestSize`.
3. Add a `security.authentication.openId` block.
4. Make `forwardHttpDestinations` a list. Add `forwardS3Destinations` and `forwardFileDestinations`. Update queue keys to 7.14 (`forwardRetryThreadCount`, `livenessCheckInterval`, …).
5. Add `fsync` and `threads` passthrough. Better still, add a generic `extraProxyConfig` map deep-merged into `proxyConfig`, so new proxy settings don't need a chart release.
6. Choose between `wantClientAuth` and `needClientAuth`, and use a separate client CA key for the trust store.
7. Add `podDisruptionBudget`, `topologySpreadConstraints`, `persistentVolumeClaimRetentionPolicy`, and the `restricted` PSS-compatible `securityContext` (`allowPrivilegeEscalation: false`, drop ALL, `seccompProfile: RuntimeDefault`). Check the image's entrypoint: it only `chown`s and `su-exec`s when started as root, so starting as uid 1000 with `fsGroup: 1000` should skip that path.
8. Make the `checksum/config` pod annotation roll pods when config changes.
9. Default the log-sender sidecar to off (F8).
10. Add `image.digest`, rendered as `repository@sha256:…` when set.
11. Add `logging.consoleAppenders` (default `true`), which adds console appenders to the `receive` and `send` loggers and the request log, each line prefixed with the log name. CloudWatch then gets the receipt audit trail (section 10). The file appenders stay, ready for the log shipper in section 15.
12. Add a `stroom-proxy/receiving: "true"` pod label and select on it in the Service, so the scale-down runbook (section 7) can take a pod out of the NLB.
13. Add tolerations and a node selector for the `workload=stroom-proxy` taint and label, through the existing `tolerations` and `nodeSelector` values.

The chart is released from `gchq/stroom-k8s-operator` alongside the operator charts. `30-stroom-proxy` references it by `chart_repository` and `chart_version`, with a local `chart_path` override (`../../charts/stroom-proxy`) for chart development only. Worthwhile fixes can also be offered back to the gradata chart.

A CI check renders the chart with `helm template`, runs the output through the proxy's own config validation (start the image with `--check`, or the `GenerateProxyExpectedYaml` comparison), and fails on unknown keys. This catches F4-style drift whenever the proxy image tag changes.

## 9. Secrets

* Source of truth: AWS Secrets Manager (downstream API key, keystore password, data feed identity files, OpenID client secret, optional server certificate).
* Default delivery: External Secrets Operator with a Pod Identity role scoped to `arn:…:secret:stroom-proxy/<env>/*`. Terraform only creates `ExternalSecret` objects, so **no secret values end up in Terraform state**.
* Fallback for small or dev setups: `secret_delivery = "terraform"` reads the values with `aws_secretsmanager_secret_version` and writes `kubernetes_secret`. This puts the values in state, so the backend bucket must be encrypted and access-restricted. The README warns about it.
* The keystore password is generated in the cluster by an External Secrets `Password` generator, so it never passes through Terraform. It only protects the PKCS12 files that the init container builds in an `emptyDir` at pod start, so it doesn't need to be stable or stored. In `terraform` delivery mode, `random_password` is used and the value is in state like the other secrets.

## 10. Observability and operations

* **Logs (v1)**: the `amazon-cloudwatch-observability` add-on (Fluent Bit) collects container stdout only. With the chart's `logging.consoleAppenders` (section 8, item 11), the application, receive, send and access logs all reach stdout and so CloudWatch Logs, one log group per cluster with a retention variable (`log_retention_days`, default 90). The same logs are also written as rolled files under `/stroom-proxy/logs` on the PVC. Nothing ships them anywhere in v1; they are kept for the log shipper (section 15).
* **Metrics**: Dropwizard metrics on the admin port 8090. Container Insights gives node and pod metrics.
* **Health**: the chart's probes use `/proxyAdmin/filteredhealthcheck?deny=stroom.proxy.app.handler.RemoteFeedStatusService`. Keep that, so pods don't go unready (and get restarted by the liveness probe) when downstream Stroom is down; the proxy queues meanwhile. The NLB health check uses the same endpoint (section 5).
* **Upgrades**: bump `image_tag` and `image_digest`, then the StatefulSet `RollingUpdate` (`partition` available for canaries). Upgrade EKS one minor version at a time: control plane, then add-ons, then node group.
* **Backups**: optional EBS snapshot policy (DLM) on PVC volumes by tag. Usually not needed when forwarding promptly.

## 11. Terraform inputs (proposed)

```hcl
# --- 10-infra ---
aws_region            = "eu-west-2"
name                  = "stroom-proxy-prod"
vpc_cidr              = "10.40.0.0/16"
az_count              = 3
nat_gateway_mode      = "one_per_az"        # single | one_per_az
existing_vpc_id       = null
cluster_version       = "1.34"
admin_principal_arns  = ["arn:aws:iam::123456789012:role/PlatformAdmin"]
api_allowed_cidrs     = ["198.51.100.0/24"]

system_node_instance_type = "t3.medium"
system_node_count         = 2

node_instance_types   = ["m6i.xlarge"]      # proxy node group; validated: no Graviton (amd64-only image)
node_capacity_type    = "ON_DEMAND"
node_min_size         = 3
node_desired_size     = 3
node_max_size         = 6
node_root_volume_gb   = 50

# --- 20-platform ---
route53_zone_id       = "Z0123456789"
tls_certificate_source = "cert_manager_private_ca"   # internal endpoint
private_ca_arn        = "arn:aws:acm-pca:…"
log_retention_days    = 90

# --- 30-stroom-proxy ---
proxy_image_tag       = "v7.14-beta.8"
proxy_image_digest    = "sha256:…"          # from scripts/latest-proxy-tag.sh
proxy_replicas        = 3
proxy_resources       = { requests = { cpu = "1", memory = "4Gi" }, limits = { cpu = "2", memory = "4Gi" } }
proxy_java_opts       = "-Xms2g -Xmx2g"
proxy_data_volume_gb  = 200
proxy_data_volume_iops       = 3000
proxy_data_volume_throughput = 250

load_balancer_scheme  = "internal"          # default; internet-facing is opt-in
allowed_ingress_cidrs = ["10.0.0.0/8"]      # senders on the private network (VPN, peering, Direct Connect)
hostname              = "proxy.example.internal"

auth = {
  required          = true
  types             = ["CERTIFICATE", "DATA_FEED_KEY"]
  client_cert_mode  = "want"
  client_ca_bundle_secret_arn  = "arn:aws:secretsmanager:…:secret:stroom-proxy/prod/client-ca"
  data_feed_identities_secret_arn = null      # keys fetched from downstream instead
  openid            = null
}

downstream = {
  url                = "https://stroom.example.com"
  api_key_secret_arn = "arn:aws:secretsmanager:…:secret:stroom-proxy/prod/api-key"
}

receipt = { check_mode = "RECEIPT_POLICY", fallback_action = "RECEIVE" }

forward_http = [{ name = "stroom", url = "https://stroom.example.com/stroom/datafeed", threads = 5 }]
forward_s3   = []   # [{ name = "archive", bucket = "…", key_template = "…" }] → creates IAM role + Pod Identity association

aggregation  = { enabled = true, frequency = "PT10M", max_items = 1000, max_uncompressed_size = "1.0G" }
extra_proxy_config = {}   # deep-merged escape hatch
secret_delivery    = "external_secrets"   # or terraform
```

Outputs: cluster name and endpoint, a `kubeconfig` command, the NLB DNS name, the datafeed URL (`https://<hostname>/datafeed`), the namespace, and IAM role ARNs.

## 12. Security baseline

* Nodes sit in private subnets. The NLB security group allows only `allowed_ingress_cidrs` on 443. Because the client IP is preserved (section 5), the proxy node security group also allows `allowed_ingress_cidrs` on 8443, plus the VPC range on 8090 for NLB health checks. The EKS API endpoint is private plus a public endpoint restricted to `api_allowed_cidrs`.
* The namespace enforces the `restricted` Pod Security Standard.
* A NetworkPolicy (enforced by the VPC CNI, section 4.1) allows ingress to proxy pods on 8443 from `allowed_ingress_cidrs` only, and on 8090 from the VPC range (NLB health checks, CloudWatch agent). Egress is unrestricted in v1, since the proxy needs DNS, the downstream Stroom, the IdP JWKS endpoint and AWS APIs.
* IMDSv2 is required with hop limit 1, so pods can't use the node role. All AWS access goes through Pod Identity.
* EBS volumes and EKS Secrets are encrypted (KMS). The state bucket is encrypted and versioned.
* Images are pinned by digest (F1). Optional: mirror to ECR with a pull-through cache to avoid Docker Hub rate limits and give a private pull path.

## 13. Decisions (agreed 2026-10-29)

| Topic | Decision |
|---|---|
| Helm chart | Copy the gradata `stroom-proxy` chart into `gchq/stroom-k8s-operator` (`charts/stroom-proxy`) and update it for 7.14 there (section 8). Terraform references it by chart repo and version. |
| Code location | `gchq/stroom-k8s-operator`: Terraform in `terraform/aws-eks-proxy/`, this design in `design/`. |
| Image | Pin `v7.14-beta.8` plus digest. Move to `v7.14.0` when it ships. Never use `v7.14-LATEST`. |
| Ingress | NLB TLS passthrough only (option A). The ALB options stay documented but are not built. |
| LB scheme | `load_balancer_scheme` variable, default `internal`. `internet-facing` is opt-in and requires `allowed_ingress_cidrs` without `0.0.0.0/0`. |
| Default auth | `enabledAuthenticationTypes = [CERTIFICATE, DATA_FEED_KEY]`, `client_cert_mode = "want"`. |
| Downstream | Optional, present by default (Stroom URL + API key, `receiptCheckMode = RECEIPT_POLICY`). `downstream = null` → `downstreamHost.enabled: false`, `RECEIVE_ALL`, S3 or file forwarding only. |
| VPC | A new 3-AZ VPC by default. `existing_vpc_id` + subnet ids switch to an existing one. |
| Secrets | Secrets Manager → External Secrets Operator by default. `secret_delivery = "terraform"` fallback for dev (values in state). |
| Logs | All proxy logs (application, receive, send, access) to stdout and CloudWatch through the observability add-on now. Rolled log files kept on the PVC. Privileged log-sender off. A non-root shipper to Stroom later (section 15). |
| Nodes | Default 3 × `m6i.xlarge` on-demand (one per AZ) for proxies. Spot allowed by variable, with a warning. A small untainted system node group (2 × `t3.medium`) runs the cluster services (design correction, not a user choice). |
| Autoscaling | None in v1: pod and node counts are fixed by variables. Karpenter can come later. |

No open items remain. The chart's home (F3) was settled on 2026-10-29.

## 14. Implementation phases

Phases 1–5 deliver the agreed defaults. Phase 6 adds the remaining v1 options.

1. `10-infra`: VPC, EKS, system and proxy node groups, add-ons (VPC CNI with network policy). Done when `kubectl get nodes` shows proxy nodes in 3 AZs and the system pods are running.
2. `20-platform`: LB controller, gp3 StorageClass, CloudWatch add-on, External Secrets, cert-manager, external-dns.
3. Copy the gradata `stroom-proxy` chart into `charts/stroom-proxy`, then make the 7.14 changes (section 8), with the `helm template` + config validation CI check.
4. `30-stroom-proxy` with the default deployment: NLB passthrough, `CERTIFICATE` + `DATA_FEED_KEY` auth, downstream Stroom with `RECEIPT_POLICY`, HTTP forwarding, secrets through External Secrets, NetworkPolicy. Done when:
   * `curl --cert … https://<hostname>/datafeed` returns 200 and the data arrives downstream;
   * the same with a data feed key and no certificate returns 200;
   * a request with neither is refused;
   * receive log lines are visible in CloudWatch.
5. Runbooks (scale-down, image upgrade, EKS upgrade, destroy cleanup) and `terraform test` suites for the variable validations in sections 6 and 7.
6. Other v1 options: `TOKEN` with OpenID, `downstream = null` with data feed identity files, S3 forwarding with Pod Identity, `internet-facing` with ACME certificates, `terraform` secret delivery.

## 15. Future work

Not in v1. Listed so the v1 design doesn't block any of it.

### 15.1 Helm chart (gchq/stroom-k8s-operator)

After the 7.14 changes in section 8:

* **Values schema**: `values.schema.json`, so bad values fail at `helm install` rather than at proxy start-up.
* **Chart tests**: a `helm test` pod that posts a small sample file to `/datafeed` and checks for a 200.
* **Chart CI**: `ct lint` and `ct install` against a kind cluster on every change, plus the config validation check from section 8.
* **Publishing**: release the chart to an OCI registry (e.g. GHCR), with chart versions independent of the proxy version and `appVersion` tracking the proxy tag.
* **Image updates**: Renovate (or similar) raising pull requests when a new `v7.14.N` tag and digest appear, for both the chart default and the Terraform examples.
* **Optional templates**: `ServiceMonitor` for Prometheus, `NetworkPolicy` (moving it from Terraform into the chart), and the NLB Service annotations as first-class values.
* **StroomProxy custom resource**: the operator already manages Stroom node lifecycle (draining tasks before shutdown, rolling upgrades). A `StroomProxy` resource could do the same for proxies: drain before scale-down, then autoscale safely. That would replace the chart and the manual runbook in section 7, but it is a substantial Go change.
* **Stroom alongside**: deploy Stroom itself with the operator's `StroomCluster` resource on the same EKS platform, so a proxy and a Stroom can run side by side.

### 15.2 Shipping proxy logs to Stroom

The chart's existing log-sender sidecar (F8) can't run under the `restricted` Pod Security Standard. Options:

| Option | How | Pros | Cons |
|---|---|---|---|
| **(a) Non-root log-sender (recommended)** | Rework the `gchq/stroom-log-sender` image to run as uid 1000 using supercronic instead of root cron, no `privileged`. Send to the pod's own proxy at `https://localhost:8443/datafeed`. | The chart already has the wiring (crontab, headers, feeds per log type). Logs go through the proxy's own queue, retry and forwarding, so they need no separate certificate or route to Stroom. | Needs a new log-sender image release. The proxy must accept the sidecar's credentials (its own certificate or a data feed key). |
| (b) Fluent Bit sidecar | Tail the rolled files and post them with Fluent Bit's HTTP output, adding `Feed`, `System` and `Environment` headers. | Standard tool, no custom image. | Needs Stroom-specific header and batching config. Posting per batch rather than per rolled file changes how data arrives in Stroom. |
| (c) Through CloudWatch | CloudWatch Logs subscription → Firehose → S3 → SQS → a proxy's S3/SQS ingest. | No sidecar at all. | More AWS moving parts, more latency, and the log format changes on the way. |

Once the log shipper exists, `logging.consoleAppenders` can default to `false` for the receive and send logs, so they aren't stored twice.

### 15.3 Stroom-Proxy changes

These would need GitHub issues raised by a person:

* **arm64 image**: publish `gchq/stroom-proxy` for arm64, to allow cheaper Graviton nodes (F2).
* **Certificate from a load balancer header**: parse a PEM or URL-encoded PEM certificate in `x509CertificateHeader`, so ALB mTLS (option B) can pass the full certificate (F5).
* **CIDR ranges in `allowedCertificateProviders`**, so the header trust check can be pinned to load balancer subnets (F6).
* **Release pipeline**: `v7.14-LATEST` should only follow release builds, not branch builds (F1).
* **Drain mode**: an admin task or endpoint that stops receiving, reports not-ready, and finishes forwarding. This would replace the manual scale-down runbook in section 7 and allow safe pod-count autoscaling.

### 15.4 Platform

* Node autoscaling with Karpenter (zone-aware, so it respects the AZ of each proxy's EBS volume).
* Pod-count autoscaling, once drain mode exists.
* ALB with WAF and ACM certificates (option B or C in section 5).
* Mirroring images into ECR (pull-through cache), for private pulls and to avoid Docker Hub rate limits.
* Restricting egress in the NetworkPolicy to known destinations.
* Periodic EBS snapshots (DLM) of proxy volumes.
* Multi-region deployment.
