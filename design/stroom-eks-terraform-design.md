# Stroom 7.14 on AWS EKS with Terraform: design

Status: first draft, 2026-10-30, with the decisions of the same day (section 16.1). Not reviewed. Remaining gaps are marked **(open)** and collected in section 16.2. It builds on the Stroom-Proxy design (`proxy-eks-terraform-design.md`, referred to below as "the proxy design") and reuses its stacks and modules where it can.

## 1. Goal

Terraform that adds a Stroom cluster (the full application, not Stroom-Proxy) to the EKS platform built for Stroom-Proxy, and produces:

* Stroom 7.14 (image `gchq/stroom`) on EKS, with node groups sized for Stroom (more memory, local NVMe), separate from the proxy nodes;
* a **fixed-size cluster** of Stroom nodes, each with a unique, sensible and permanent node name (section 11.1);
* an Amazon RDS for MySQL 8.4 database for Stroom's `stroom` and `stats` schemas;
* EFS for shared file storage (the stream store), local NVMe for LMDB, and a per-node EBS volume for index shards and the LMDB stores that must survive node replacement;
* **ingest from the proxy's data bucket**: Stroom is told about each new object by the bucket's SQS queue and reads it in place, never copying or deleting it;
* sign-in through an external OpenID Connect provider: Azure Entra ID by default, with Keycloak or Cognito as alternatives;
* the Stroom UI and API on an internal HTTPS endpoint, with sticky sessions, and HTTPS all the way to the pods;
* Stroom-Proxy checking received data against Stroom's receipt rules, and carrying on receiving while Stroom is down;
* upgrades and node replacement that drain processing tasks before a node stops, and that lose no data, because new data waits in SQS while Stroom is down.

Out of scope for the first version: Stroom receiving data directly from senders (senders use the proxy), Stroom's own HTTP `/datafeed` behind a load balancer, Elastic/Solr/Kafka integrations, multi-region, and autoscaling the pod count.

## 2. Findings that shape the design

From the 7.14 source (`7.14` branch, CHANGELOG at `v7.14-beta.8`/`beta.9`), stroom-docs, and the operator in this repo. Numbered S1… to keep them apart from the proxy design's F1….

| # | Finding | Consequence |
|---|---------|-------------|
| S1 | S3/SQS ingest is new in 7.14 (`v7.14-beta.2`, #5546) and still being fixed in every beta since (#5793, #5844, #5853, #5887). It is not in 7.13. stroom-docs say nothing about it. | 7.14 is the minimum version. Treat ingest as beta until 7.14.0, and test it early (section 17, phase 1). |
| S2 | Ingest is a per-node job, "S3 Event Notifications Poll" (disabled by default), that long-polls `appConfig.receive.s3Event.sqs.queueUrl`. Each message must be a **raw S3 event notification** (`Records`, `eventVersion` 2.x, `ObjectCreated:*`); SNS-wrapped and EventBridge messages are refused. SQS visibility, not a cluster lock, stops two nodes taking the same message. | The proxy stack's direct bucket → SQS notification (proxy design 7.1) is the right shape. Enable the job on processing nodes only. |
| S3 | For each event Stroom does a `HeadObject` (with `If-Match` on the event's eTag), reads the feed and other meta from the object's **user metadata** (the proxy's `S3MetaKeysMapper`), applies the receipt policy, and creates a stream that **points at the object in place** (`fs_meta_s3_location`). The data is never copied. It reads the zip at processing time, using the proxy zip's 10-digit entry names: one proxy zip becomes one Stroom stream. | The data bucket is Stroom's raw stream store. The key layout doesn't matter to Stroom. |
| S4 | Stroom never deletes, overwrites or tags the object: physically deleting such a stream only removes database rows ("S3 is not under our control"). | Works with Object Lock COMPLIANCE. But Stroom's data retention no longer frees space, and an S3 lifecycle expiry breaks streams Stroom still references. The bucket's `data_expire_after_retention` must be off, or `data_retention_days` must be at least Stroom's longest retention (section 7.3). |
| S5 | The object must sit on an **`S3 v1 (Read only)` data volume** whose region and bucket match the event; volumes are rows in the database, set up in the UI (Data Volumes), each with its own S3 client config JSON. With no matching volume the message is logged and later refused. | The bootstrap Job creates the read-only volume (section 5.4). `S3ConfigDoc` (UI document) is only for the `S3Appender` pipeline element, not ingest. |
| S6 | No deduplication: a repeated S3 notification (S3 delivers at least once) or a failed SQS delete creates a second stream for the same object. | Raise a Stroom issue for a uniqueness check on bucket, key and version (decision 16.1). Until it lands, downstream processing must tolerate the occasional duplicate stream. |
| S7 | Failed messages: retryable errors (S3 communication, failed delete) are left on the queue; others go to `deadLetterQueueUrl` with error attributes if it is set, and are otherwise **only logged** and retried after the visibility timeout, contrary to the property's description. | Set `deadLetterQueueUrl` to the proxy stack's DLQ, and keep the queue's redrive policy (`maxReceiveCount = 5`) as a backstop. |
| S8 | AWS credentials use the SDK default chain when `credentials` is null (SDK 2.54, which includes EKS Pod Identity). An `assumeRole` setting fetches credentials once and never refreshes them. | Pod Identity, no `assumeRole`. Needs a test (Pod Identity in the default chain is unconfirmed for Stroom). |
| S9 | Stream (fs) volumes have no node column: every node must be able to read and write every stream volume. Index volumes belong to one node (`index_volume.node_name`). Volume types: `STANDARD` (filesystem), `S3_V1` (writable; each stream zipped and uploaded, reads download and unzip through local temp), `S3_V2` (experimental, "not for production"), `S3_V1_READ_ONLY` (S5). | Raw data is read in place from S3 (S3). Streams Stroom writes (processed events, errors, reference data) need a **shared** writable volume: EFS, or a writable `S3_V1` bucket (section 5.3). Index volumes go on per-node disks. |
| S10 | LMDB (reference data, search results, analytics, duplicate check, Plan B) must not be on remote storage. The docs found EBS "VERY slow" for the reference store and recommend instance-store SSD; the reference store can be rebuilt, so losing it is acceptable. LMDB uses the OS page cache, which counts against the pod's memory. | LMDB stores that can be rebuilt go on instance-store NVMe; those that must survive node replacement (analytics, duplicate check, Plan B) go on EBS. Memory limits leave room for page cache (section 5). |
| S11 | Nodes find each other through the database: each node writes its name and endpoint URL (`appConfig.node.name`, `appConfig.nodeUri`) on boot, and nodes call each other over the application port. Jobs, index volumes and Plan B `nodeList` are keyed by node name. Inter-node calls use a cluster token signed with a key kept in the database, not the IdP. | Node names must be unique and never change: a StatefulSet pod name, with the headless Service name as `nodeUri`. Renaming a node set orphans its index volumes and job rows. Index shards belong to the node that wrote them, so a node can't simply be removed: the cluster has a fixed size, and nodes are added but not taken away (section 11.1). |
| S12 | The leader ("master") is the enabled node with the highest priority; it hands processor tasks to the others. Every node can serve the UI and process; a UI-only/processing split is a deployment choice (jobs disabled on UI nodes). | Two node sets: `ui` (UI and API, few jobs) and `proc` (processing) (section 11). |
| S13 | UI sessions are held in memory (`STROOM_SESSION_ID` cookie), so the UI needs sticky sessions and WebSockets (`/web-socket/`). The stack's nginx blocks `clustercall.rpc` from outside. | ALB target group stickiness on the application cookie; ALB rule denying `clustercall.rpc` (section 9). |
| S14 | Flyway migrations run at start-up under a cluster-wide lock, whenever the database's build version differs from the image's. Nothing says whether two Stroom versions may run against one database at once; the upgrade docs are empty. | Version upgrades stop every node, then start the new version (section 12). Node replacement within a version can roll. |
| S15 | Ports: 8080 application over HTTP (UI, `/api`, `/datafeed`), 8081 admin (`/stroomAdmin`, healthcheck); the operator adds an HTTPS application connector on 8443 when its `https` settings are given. Default heap `-Xmx2g`; docs give no sizing guidance beyond "production needs more". Java 25 image, uid 1000. | Heap from a variable, sized against the memory limit and LMDB page cache (section 11). The image's architecture must be checked (the proxy image is amd64 only, F2) **(open)**. |
| S16 | External IdP config is `appConfig.security.authentication.openId` with `identityProviderType: EXTERNAL_IDP`. Entra ID needs the v2.0 endpoints, an exposed API with `accessTokenAcceptedVersion: 2`, `allowedAudiences` with both `<client id>` and `api://<client id>`, `profile` in `requestScopes`, and `uniqueIdentityClaim: oid` (choose before the first sign-in). Group and role claims are ignored: authorisation is Stroom's own users and groups. Cognito access tokens have no `aud` (`audienceClaimRequired: false`); Keycloak needs an audience mapper. | Per-IdP presets in the module (section 8). The first admin is created with the `manage_users` CLI. |
| S17 | The operator (`StroomCluster` CR) already does the Stroom-specific lifecycle: enable the node and its jobs on start, disable them and wait for running tasks to finish in `preStop`, drain before deleting a cluster, adjust task limits from CPU (`StroomTaskAutoscaler`), and (internal IdP only) create and rotate an API key for its scripts. It accepts an external database (`serverAddress`). | Deploy Stroom with the operator, after merging upstream (S19) and making the changes in section 10.2. |
| S18 | Operator problems found by reading the code: pod and node names are `stroom-<cluster>-node-<node set>-<n>` (`GetBaseName`, `GetNodeSetName`), so a cluster named `stroom-prod` gives `stroom-stroom-prod-node-processing-0`; nothing stops a node set's `count` going down or a node set being renamed or removed; its Ingress is nginx-only (hard-coded annotations and rewrite); one PVC per pod with fixed subpaths (`reference_data`, `search_results`, … all on that PVC); no PDB or topology spread; `volumeClaimTemplates` copied on every update, so a size change fails; the probe `periodSeconds` is set from `initialDelaySeconds`; the JDBC URL has no TLS options; the `DatabaseServer` root password is the literal path string; `DatabaseBackup` looks up `batch/v1beta1` CronJobs (gone since 1.25); the sample's HTTPS field name is wrong, so it silently runs plain HTTP; the sample image is `v7.1-LATEST`; the log-sender is root and privileged. | Use the operator without its Ingress, `DatabaseServer` or `DatabaseBackup`. Several of these are already fixed upstream (S19); the rest are changes for v1 (section 10.2). |
| S19 | The fork is behind its upstream, `gradata-systems/stroom-k8s-operator`: upstream `master` (`67bb687`, 2026-10-26, prerelease `1.2.0-beta.1`) has 48 commits the fork lacks; the fork's base is upstream `1.1.5`. Upstream fixes the probe period, the `DatabaseServer` root password, the `DatabaseBackup` CronJob API and the sample's HTTPS field; makes the Ingress class default to the cluster's IngressClass; adds baseline pod hardening (no privilege escalation, `RuntimeDefault` seccomp, no service account token), health-check filtering in probes, SQL and shell injection fixes, reduced RBAC, and golden-file, envtest and e2e tests against Stroom 7.13.2 with Keycloak. It does **not** change pod naming, the fixed subpaths, the `volumeClaimTemplates` update, PDBs, topology spread, Stroom's JDBC TLS or count guards, and has no API key automation (the fork's #34, which upstream lists as a known gap for the internal IdP). Same MIT licence. A trial merge conflicts in four Go and script hunks plus release plumbing. | Merge upstream `master` into the fork before any of our operator changes (section 17, phase 0), and offer #34 upstream. Decide during the merge: image registry (gchq or ghcr), version numbering (fork `2.0.0` vs upstream `1.2.x`), and whether to drop the all-in-one manifest and workflows as upstream did. |
| S20 | `gradata-systems/stroom-helm-charts` has a `charts/stroom` chart, but it is an alpha umbrella chart for Stroom 6.1 (appVersion `v6.1.32`, unchanged since May 2022, with ZooKeeper, Kafka and Solr subcharts), and the repository has no licence. | Not usable or copyable. The operator is the deployment method (section 10). |

## 3. Architecture

```
   Users (browser, API clients) on the private network
          │ HTTPS 443  stroom.…
  ┌───────▼───────────────────────────────────────────────────┐
  │ ALB (internal) — ACM certificate                          │
  │  /, /api/…, /web-socket/ → ui target group (sticky cookie)│
  │  *clustercall.rpc, /datafeed* → fixed 403                 │
  └───────┬───────────────────────────────────────────────────┘
          │ HTTPS 8443, TargetGroupBinding (operator's ui Service)
  ┌──── same EKS cluster and VPC as the proxy ───────────────────────────────────────┐
  │  namespace stroom                                                                │
  │  ui node set (UI/API)               proc node set (jobs, S3 event poll)          │
  │  ┌──────────┐┌──────────┐           ┌──────────┐┌──────────┐┌──────────┐         │
  │  │  …-ui-0  ││  …-ui-1  │ ◀─8443──▶ │ …-proc-0 ││ …-proc-1 ││ …-proc-2 │         │
  │  │:8443 app ││          │ node↔node │          ││          ││          │         │
  │  │:8081 adm ││          │           │          ││          ││          │         │
  │  └──────────┘└──────────┘           └──────────┘└──────────┘└──────────┘         │
  │   every pod: EBS PVC (index shards, analytics/Plan B LMDB, logs)                 │
  │              NVMe emptyDir (reference data, search results, temp, s3_cache)      │
  │              EFS (shared stream volume)                                          │
  │       ▲ HTTPS 8443, receipt rules (API key)                                      │
  │  proxy namespace, proxy nodes                                                    │
  │  operator, cert-manager, trust-manager (system nodes)                            │
  └───────────────────────────────┬───────────────────────┬──────────────────────────┘
                     3306 (TLS)   │                       │ ReceiveMessage/Delete
                       ┌──────────▼───────┐   ┌───────────▼───────────┐
                       │ RDS MySQL 8.4    │   │ SQS data-events + DLQ │
                       │ stroom + stats   │   │ ◀── bucket            │
                       │ Multi-AZ         │   │     notifications     │
                       └──────────────────┘   └───────────┬───────────┘
                                                          │ HeadObject/GetObject
                                              ┌───────────▼──────────────┐
          Stroom-Proxy ── PutObject ────────▶ │ data bucket (Object Lock │
                                              │ COMPLIANCE, KMS)         │
                                              │ = Stroom raw stream store│
                                              └──────────────────────────┘
```

## 4. Reuse and Terraform layout

### 4.1 What is reused

| Proxy piece | Use for Stroom |
|---|---|
| `10-infra`: VPC, EKS, system node group, add-ons | Same cluster. Add Stroom node groups with NVMe RAID0 (sections 5.2, 11.2) and the EFS CSI driver add-on. |
| `10-infra`: one node group per AZ per colour | Same pattern for Stroom node sets, so a node always exists in the AZ of each EBS volume. No colours (section 12). |
| `20-platform`: LB controller, gp3 StorageClass, External Secrets, CloudWatch add-on (with Application Signals off, F22) | Kept as they are. Add an EFS StorageClass, cert-manager and trust-manager with the in-cluster CA (9.1), metrics-server (for the task autoscaler), and the operator and its CRDs (Helm). |
| `30-stroom-proxy`: data bucket, KMS key, SQS queue and DLQ | Stroom reads them. Their names and ARNs come from that stack's outputs (`data_bucket`, `data_events_queue_url`, plus new outputs for the KMS key, the DLQ and the bucket's expiry settings). The stack also gains a `stroom_downstream` input for the receipt policy (8.1, 4.3). |
| `modules/stroom-proxy`: ALB, ACM certificate options (`acm_private_ca`, `acm_public`, `acm_existing`, `acm_imported`), Route 53 alias, `TargetGroupBinding`, Pod Identity role, namespace with `restricted` PSS, NetworkPolicy, ESO `SecretStore` | Same patterns in a new `modules/stroom`. The certificate code could move into a shared `modules/acm-certificate` **(open)**. |
| exec-based provider auth (F23), `time_sleep` after Pod Identity associations (F27), `envs/<env>/local-*` overrides | Same. |

### 4.2 Layout

```
terraform/aws-eks/                 # renamed from terraform/aws-eks-proxy (decision 16.1)
├── modules/
│   ├── network/ eks/ platform/ stroom-proxy/   # existing; eks and platform gain Stroom options
│   ├── stroom-db/                 # RDS MySQL, parameter group, subnet group, secret
│   └── stroom/                    # ALB, Pod Identity, namespace, EFS, StroomCluster CR, bootstrap job
├── stacks/
│   ├── 10-infra/ 20-platform/ 30-stroom-proxy/  # existing
│   └── 40-stroom/                 # reads 10, 20 and 30 outputs
└── envs/<env>/40-stroom.tfvars
```

`40-stroom` is a separate stack so Stroom can be rebuilt without touching the proxy, and so the proxy can run without Stroom. It reads the bucket, queue and key from `30-stroom-proxy`'s remote state, or from variables when the bucket was created elsewhere.

### 4.3 Apply order

The proxy needs things that only exist once Stroom does (its API key, and Stroom answering receipt-rule requests), and Stroom needs the proxy's bucket and queue. So the first build applies `30-stroom-proxy` twice:

1. `10-infra`, `20-platform`;
2. `30-stroom-proxy` with `stroom_downstream = null`: the proxy receives with `RECEIVE_ALL`, as now;
3. `40-stroom`: Stroom starts, the bootstrap Job writes the proxy's API key to Secrets Manager (5.4);
4. `30-stroom-proxy` again with `stroom_downstream` set (8.1): the proxy switches to `RECEIPT_POLICY` in a drained rolling update.

Later applies go in stack order as usual.

## 5. Storage

### 5.1 Where each directory goes

| Directory (under `/stroom`) | Holds | Storage | Why |
|---|---|---|---|
| Stream volume, written streams | Processed events, errors, reference streams, anything a pipeline writes | **EFS** (shared, `efs-sc`), mounted on every node | Shared by all nodes (S9). A writable `S3_V1` volume is tested later as a replacement (5.3). |
| Raw received data | The proxy's zips | **Data bucket**, `S3_V1_READ_ONLY` volume | Read in place (S3, S5). |
| `volumes/index` | Lucene index shards | **EBS gp3**, per pod (`data` PVC) | Per node (S9), must persist. |
| `lmdb/analytic_store`, `lmdb/duplicate_check`, `planb` | Analytic rule state, Plan B state | **EBS gp3**, per pod | Must survive node replacement, which wipes NVMe (S10); losing them can cause duplicate alerts or lost Plan B state. Slower than NVMe; EBS IOPS and throughput are variables, to be measured **(open)**. |
| `reference_data`, `reference_staging_data`, `search_results`, `lmdb_library` | Reference LMDB, staging, query results, native libraries | **Instance-store NVMe** via `emptyDir` | Fast local disk (S10); rebuildable or temporary. |
| temp (incl. `s3_cache`, S3 read staging) | Downloaded zips being processed | **Instance-store NVMe** via `emptyDir` | Must hold several whole zips (S9). |
| `logs`, `output` | Rolled logs, file appender output | EBS (the `data` PVC) | Small. Logs also go to CloudWatch through stdout (proxy design section 12). |
| caches (`content_index`, `git_repo`, `asset_cache`, `keystores`) | Rebuildable caches | `emptyDir` | Rebuilt on start. |

### 5.2 Instance store

Stroom node groups use instance types with local NVMe (`r6id`, `r7id`, `m6id`, `m7id`, `i4i`; the `d` matters). The AL2023 launch template sets `nodeadm`'s `localStorage: {strategy: RAID0}`, which builds a RAID0 array from the NVMe disks and puts kubelet and containerd on it, so `emptyDir` volumes and the container filesystem land on NVMe with no extra provisioner. `emptyDir` `sizeLimit` and the pod's `ephemeral-storage` request keep pods within the disk. Contents are lost when the node is replaced, which is acceptable for these directories (5.1).

Not used: the local volume static provisioner (a local PV per pod, pinned to one node). More moving parts, and a pod could never move node.

### 5.3 Shared stream volume: EFS now, S3 later

Decision: EFS for v1; a writable `S3_V1` volume is tested in a later phase as a possible replacement.

* **EFS**: a POSIX shared filesystem, as on-prem NFS. EFS CSI driver with an access point owned by uid 1000, mounted read-write on every Stroom pod at `/stroom/volumes/stream`. Elastic throughput. Encrypted with a KMS key; backed up with AWS Backup. Cost and latency are the drawbacks; Stroom writes many small files.
* **`S3_V1` writable volume (later test)**: a second bucket (not Object Locked, as Stroom deletes from it), no shared filesystem. Every read and write goes through local temp (S9), and its production use is unproven. If it works it would remove EFS.

In short: **EFS for shared file storage, local NVMe for LMDB** that can be rebuilt (and temp), and a per-node EBS volume for index shards and the LMDB stores that hold state.

### 5.4 Volume setup inside Stroom

Data and index volumes are database rows, not config, and so are users and API keys. A **bootstrap Job** in `40-stroom` sets them up. It runs on the first apply and again whenever the node sets change (its spec includes the node list, so Terraform replaces it), and every step is idempotent:

1. create the first administrator and the `stroom-proxy` user with its API key (Stroom CLI `manage_users` and `create_api_key`, which work on the database, as the operator's API key Job does), and write the key to Secrets Manager (8.1);
2. create the `S3_V1_READ_ONLY` data volume for the proxy's bucket, with an S3 client config that uses the default credential chain;
3. create the EFS stream volume and make it the default write volume;
4. create an index volume group with one volume per node, at `/stroom/volumes/index` on each node (and add one when a node is added, 11.1);
5. enable the S3 event poll job on the `proc` nodes.

Steps 2–5 use the Stroom REST API with a short-lived API key the Job creates for itself in step 1. A CronJob from the same image renews the proxy's key before it expires (8.1). The Job's service account has its own Pod Identity role, allowed only `secretsmanager:PutSecretValue` on the proxy key's secret. The exact CLI and API calls are to be worked out against 7.14 **(open)**.

## 6. Database

* **Amazon RDS for MySQL 8.4** (decided; the version Stroom's own stack uses), Multi-AZ, in the private subnets, encrypted, with automated backups and a final snapshot. One instance with two schemas (`stroom`, `stats`). Not yet tested with Stroom, but the migrations use only tables, views and stored procedures (no functions, triggers or definers), so no special privileges are expected.
* Parameter group: `character_set_server = utf8mb4`, `collation_server = utf8mb4_0900_ai_ci` (the docstore sets its own `utf8mb4_0900_as_cs` columns), `lower_case_table_names = 0`, `max_connections` from the node count × pools × `maxPoolSize` (30 per pool by default) with headroom, `require_secure_transport = ON` once the JDBC URL can carry TLS options (S18).
* Credentials in Secrets Manager: the RDS-managed master password, and `stroomuser`'s password. A database init Job in `40-stroom` (MySQL client, master password) creates the two schemas and `stroomuser` before the StroomCluster exists, since the operator expects both. External Secrets delivers `stroomuser`'s password to the namespace in the format the operator expects (key = username, value = password).
* The operator connects to MySQL itself (drain-on-delete, autoscaler; with TLS since the upstream merge), so the security group allows 3306 from the Stroom pods, the operator pod and the init Job.
* The operator's `DatabaseServer` and `DatabaseBackup` are not used (S18).

## 7. Ingest from the proxy's bucket

### 7.1 Flow

1. The proxy writes a zip to the data bucket with the feed and meta as object metadata (proxy design F11).
2. The bucket sends an `ObjectCreated` event straight to the `data-events` queue (proxy stack; 14-day retention, DLQ after 5 receives).
3. On each processing node the "S3 Event Notifications Poll" job long-polls the queue, `HeadObject`s the object, applies the receipt policy, and creates a stream on the read-only volume (S2, S3).
4. Processor filters pick the stream up as usual; reading it downloads and unzips the object into local temp.

While Stroom is down or upgrading, events wait in the queue for up to 14 days, so nothing is lost; Stroom catches up when it starts.

### 7.2 Configuration

```yaml
appConfig:
  receive:
    s3Event:
      sqs:
        awsRegionName: <region>
        queueUrl: <30-stroom-proxy data_events_queue_url>
        deadLetterQueueUrl: <DLQ url>       # S7
        # credentials: null → default chain → Pod Identity (S8)
```

The read-only volume's region and bucket must match the events exactly (S5).

### 7.3 Retention

Stroom's raw streams are the bucket's objects (S4):

* the bucket's lifecycle expiry must be off, or longer than any Stroom data retention rule;
* Stroom's data retention deletes only database rows; removing objects is S3's job (a lifecycle rule once both the Object Lock retention and Stroom's retention have passed);
* the periods are set per environment (decided): `40-stroom` takes `raw_data_retention_days`, the longest Stroom retention rule for raw streams, and a precondition refuses a plan if the proxy stack's S3 expiry (`data_expire_after_retention`, `data_retention_days`, read from its outputs) would remove objects sooner. Stroom's retention rules themselves are set in Stroom.

### 7.4 IAM (Pod Identity role for the Stroom service account)

* `sqs:ReceiveMessage`, `sqs:DeleteMessage`, `sqs:ChangeMessageVisibility`, `sqs:GetQueueAttributes` on the queue; `sqs:SendMessage` on the DLQ;
* `s3:GetObject` (also covers `HeadObject`) and `s3:ListBucket` on the data bucket; no write or delete;
* `kms:Decrypt` on the data bucket's key;
* when `S3_V1` is tested for written streams (5.3): read, write and delete on that second bucket only.

The data bucket policy (proxy design 7.1) gains a read statement for this role. The bootstrap Job has a separate role (5.4).

## 8. Authentication

* `identityProviderType: EXTERNAL_IDP`, with module presets:

| `idp` | Settings set by the module |
|---|---|
| `entra` (default) | `openIdConfigurationEndpoint = https://login.microsoftonline.com/<tenant>/v2.0/.well-known/openid-configuration`; `allowedAudiences = [<client id>, api://<client id>]`; `requestScopes = [openid, email, profile, offline_access?]`; `uniqueIdentityClaim = oid`; `userDisplayNameClaim = preferred_username`. App registration with an exposed API and `accessTokenAcceptedVersion: 2` (S16). |
| `keycloak` | Realm discovery URL; audience mapper required; `uniqueIdentityClaim = sub`. |
| `cognito` | User pool discovery URL; `audienceClaimRequired = false`; `formTokenRequest = true`; `userDisplayNameClaim = cognito:username`. |

* Redirect URI to register: `https://<hostname>/api/auth/flow/v1/signin-oidc`.
* Client secret in Secrets Manager → External Secrets → the operator's `openId.clientSecret`. Entra secrets expire within 24 months: a runbook and a reminder (for example an alarm driven by a secret tag holding the expiry date) are needed **(open: mechanism)**.
* App registrations (or Keycloak and Cognito clients) are created **outside this Terraform** (decided), by whoever owns the tenant; the module takes the tenant or discovery URL, the client ID and the Secrets Manager name of the client secret.
* The first administrator is created by the bootstrap Job with `manage_users` (S16), from a variable naming the admin's IdP identity.
* The operator's in-pod scripts (enable jobs, drain tasks) authenticate with a **Stroom API key** under every IdP type (decided). Today the operator's API key automation (fork #34: a CLI Job creates the `stroom-k8s-operator` user and a 365-day key, renewed 35 days before expiry, delivered as a Secret) runs only with the internal IdP, and an external IdP falls back to a client-credentials token, which would need a second app registration. The automation is extended to `EXTERNAL_IDP` (section 10.2): the CLI's `manage_users` and `create_api_key` work on the database, so they don't depend on the IdP. No second client, no second expiring secret.
* Stroom-Proxy fetches receipt rules from Stroom (section 8.1).

### 8.1 Stroom-Proxy receipt policy

Decision: the proxy checks data against Stroom's receipt rules.

* Proxy config: `receive.receiptCheckMode: RECEIPT_POLICY` and `receive.fallbackReceiveAction: RECEIVE`, so the proxy keeps accepting data while Stroom is stopped or can't be reached (an upgrade never becomes a sender outage); `downstreamHost` points at the `ui` node set's Service inside the cluster on 8443 (section 9.1), and `downstreamHost.apiKey` holds the key. The proxy module already has the `receipt` (`check_mode`, `fallback_action`) and `downstream` (`hostname`, `api_key_secret_name`, …) variables; `30-stroom-proxy` gains one input, `stroom_downstream`, that sets them together (4.3). The proxy's HTTP client must also trust the in-cluster CA (9.1), which needs a small proxy module and chart change.
* Authentication: a **Stroom API key** (decided) for a `stroom-proxy` Stroom user with only the `STROOM_PROXY` application permission (check receipt status, fetch hashed receipt rules, verify API keys). The bootstrap Job (5.4) creates the user and key and writes the key to a Secrets Manager secret; External Secrets delivers it to the proxy namespace. A CronJob renews the key before it expires **(open: key lifetime and renewal margin)**.
* Network: the Stroom NetworkPolicy lets the proxy pods reach the `ui` pods' port 8443. The proxy's probes already ignore the receipt-rule health check (proxy design F15), so proxy pods stay Ready while Stroom is down.
* Rule changes reach the proxies at the proxy's `receiptPolicy` sync interval; while Stroom is down they use the rules they last fetched **(to test: behaviour when a proxy restarts while Stroom is down)**.
* Stroom applies its receipt policy again at S3 ingest (S3), so data the proxy accepted under the fallback is still filtered when Stroom ingests it.

## 9. Access

* **ALB (internal)**, a separate one from the proxy's, in the lb subnets, `:443` with an ACM certificate (same `tls_certificate_source` options as the proxy), and `:80` redirecting to 443.
* Target group: `ip` targets, **HTTPS** to the pods' port 8443 (section 9.1). Health check over HTTP on the admin port 8081, `/stroomAdmin/ping` or a filtered healthcheck (S15) **(open: which)**. Stickiness: application cookie `STROOM_SESSION_ID`. Long idle timeout for WebSockets.
* Rules: `*clustercall.rpc` → 403 (S13); `/stroomAdmin*` is never routed (it's on 8081 anyway); `/datafeed*` → 403 in v1 (data comes through the proxy).
* `TargetGroupBinding` points at the operator's `…-http` Service for the `ui` node set. The operator's own Ingress is disabled (`ingressEnabled: false`, S18).
* Security group: 443 from `allowed_ingress_cidrs` (users' networks). Optional PrivateLink endpoint service via an NLB, as for the proxy (not in v1).
* Route 53 alias for `hostname` when `route53_zone_id` is set.
* Optional ALB `authenticate-oidc` in front of the UI is not used: Stroom does its own sign-in, and the docs' ALB edge-proxy mode loses the `oid` claim.

### 9.1 TLS inside the cluster

Decision: no data travels in plain text inside the VPC. The ALB, the proxy (receipt rules) and other Stroom nodes (cluster calls to `nodeUri`) all use HTTPS to the pods' port 8443. The admin port 8081 stays HTTP: it carries health checks only, and the NetworkPolicy limits it to the lb subnets and the namespace (13).

* Each pod serves HTTPS on 8443 with the operator's `https` settings (`tlsSecretName` holding `keystore.p12` and `truststore.p12`, `tlsKeystorePasswordSecret`). The plain HTTP connector (8080) isn't reachable from outside the pod (NetworkPolicy); the in-pod lifecycle scripts keep using it on localhost.
* Certificate: one certificate for the Stroom Services and `*.<headless service>.<namespace>.svc.cluster.local`, from an in-cluster CA. cert-manager in `20-platform` holds a self-signed CA as a `ClusterIssuer`; `40-stroom` creates a `Certificate` that writes a PKCS#12 keystore and truststore into the Secret the operator mounts, so no private key passes through Terraform state. trust-manager publishes the CA certificate as a ConfigMap in the `stroom` and proxy namespaces, so the proxy can trust it (8.1).
* Stroom reads its keystore at start-up, so a renewed certificate needs a rolling restart; the certificate lasts a year and is renewed with a planned restart **(open: check whether Stroom 7.14 reloads its keystore)**.
* The ALB doesn't validate target certificates (as for the proxy).
* **(open)**: whether Stroom nodes verify each other's certificates on cluster calls, and whether `nodeUri.scheme: https` is enough to switch them over.

## 10. Deploying Stroom with the operator

### 10.1 Decision: the operator

| | Operator (`StroomCluster` CR) | New `charts/stroom` Helm chart |
|---|---|---|
| Lifecycle (enable jobs on start, drain tasks on stop, drain on delete) | Built in | Copy the operator's scripts into the chart |
| Task autoscaling | `StroomTaskAutoscaler` | None |
| Storage layout | One PVC with fixed subpaths; needs changes for `emptyDir` and EFS | Free |
| Terraform fit | `kubernetes_manifest` for the CR (CRDs installed in `20-platform`) | `helm_release`, like the proxy |
| Work | Go changes (10.2) | A new chart; duplicated lifecycle logic |

Decided: the operator, after merging upstream (S19). The lifecycle handling is the hard, Stroom-specific part, it already exists, and fixing the operator benefits other users of this repo. The proxy chart's patterns (PDB, topology spread, `restricted` PSS) move into the operator. The gradata `charts/stroom` chart is not an option (S20).

### 10.2 Operator changes for v1

1. Node names and fixed size (section 11.1): an optional, immutable `nodeNamePrefix` field; CRD validation rules that stop a node set's `count` going down and a node set being removed or renamed; and a `stopped` field that scales every node set to 0 for version upgrades without changing `count`.
2. Storage: let each node set map Stroom directories to `emptyDir` (with `sizeLimit`) or to the data PVC, rather than fixed subpaths; allow extra claim templates; don't rewrite `volumeClaimTemplates` on update (S18).
3. A PodDisruptionBudget per node set and `topologySpreadConstraints` (not upstream).
4. JDBC options (TLS) on the external database connection (upstream only added TLS to the operator's own MySQL connection).
5. Pod and container security contexts that pass the `restricted` Pod Security level, building on upstream's hardening (S19): run as uid 1000 rather than starting as root; log-sender off.
6. API key automation (fork #34) also for `EXTERNAL_IDP` (section 8), reconciled with upstream's node hold (`holdNodes`) during the merge.
7. HTTPS to the pods with a cert-manager keystore (section 9.1); check the `https` settings end to end.
8. Pod annotation `instrumentation.opentelemetry.io/inject-java: "false"` (F22).
9. Ingress: leave it unused (`ingressEnabled: false`; we use `TargetGroupBinding`). Upstream's class-neutral Ingress is enough if anyone wants one.

Fixed by the upstream merge, so no longer on this list: probe periods, the `DatabaseServer` root password, the `DatabaseBackup` CronJob API, the sample's HTTPS field (S19).

## 11. Nodes and pods

### 11.1 Node names and a fixed cluster size

Each Stroom node has a node name that is unique, readable, and **permanent**: the database keys the node's index volumes and shards, job settings, Plan B `nodeList` entries and processor task history by it (S11). A pod's node name is its StatefulSet pod name, so the name comes from the StroomCluster and node set names and the pod's ordinal.

* **Scheme**: `<cluster>-<node set>-<ordinal>`, for example `stroom-prod-proc-0`, `stroom-prod-proc-1`, `stroom-prod-ui-0`. The cluster name carries the environment, so names are unique across environments too, which helps when logs or metrics from several environments are side by side. Node set names are short (`proc`, `ui`). The whole name is a DNS label (63 characters at most; lower case, digits and `-`), because it is also the pod's host name in `nodeUri` (`<pod>.<headless service>.<namespace>.svc.cluster.local`).
* **Operator change**: the operator names pods `stroom-<cluster>-node-<node set>-<n>` (S18). A new optional `nodeNamePrefix` on the StroomCluster replaces `stroom-<cluster>-node-`, so `nodeNamePrefix: stroom-prod` with node set `proc` gives `stroom-prod-proc-0`. Unset, names stay as they are, so existing clusters keep their node names.
* **Names are set once.** The cluster name, `nodeNamePrefix` and node set names can't change after the first start; changing any of them creates new Stroom nodes and orphans the old ones' data. The CRD makes `nodeNamePrefix` immutable (`self == oldSelf`), the node set rules below cover node set names, and Terraform refuses a plan that changes any of them (the same precondition as for `count`).
* **Ordinals and AZs**: with one pod per node and one node group per AZ, ordinal 0 lands in the first AZ that has room, and its EBS volume then pins it there. Names don't encode the AZ; the pod's `topology.kubernetes.io/zone` label and the volume show it.

**The cluster size is fixed.** Index shards (and Plan B shards) belong to the node that wrote them, so a node can't be removed without first moving or deleting its shards, which Stroom has no tool for. Scaling a StatefulSet down always removes the highest ordinals, whatever they hold.

* Each node set's `count` is set at creation and may only grow. Adding a node is a planned change: a new node name, a new index volume for it (added by the bootstrap Job, section 5.4), and its jobs enabled.
* Shrinking, renaming or removing a node set is refused, twice over:
  * by the CRD: node sets become a map list keyed by `name` (`+listType=map`, `+listMapKey=name`), with transition rules `self.count >= oldSelf.count` on each node set and, on the list, every old node set name still present (`oldSelf.all(n, self.exists(m, m.name == n.name))`);
  * by Terraform: a precondition comparing each node set's `count` with the replicas of its existing StatefulSet (read with a `kubernetes_stateful_set_v1` data source), so the plan fails before anything is applied.
* Removing a node on purpose (hardware retired, cluster reshaped) is **manual only** (decided): a runbook to stop processing on the node, delete or move its index shards and close its volumes in Stroom, then change the cluster outside the guards. No Terraform input relaxes them.
* Autoscaling the pod count is out of scope, and so is anything else that changes `count` (HPA, KEDA). The task autoscaler (S17) is fine: it changes task limits, not pods.
* A Stroom node that is down stays in the cluster: its pod is recreated with the same name on a node in the same AZ, reattaches its EBS volume, and rebuilds its instance-store LMDB data.

### 11.2 Nodes and sizing

* **Node groups** (in `10-infra`, one per AZ per node set, labelled `workload=stroom`, `stroom/node-set=<name>`, tainted `workload=stroom:NoSchedule`):

| Node set | First (dev/test) cluster, decided | Pods |
|---|---|---|
| `proc` | `r6id.2xlarge` (8 vCPU, 64 GiB, 474 GB NVMe), 1 per AZ | 1 Stroom pod per node |
| `ui` | `m6id.xlarge` (4 vCPU, 16 GiB, 237 GB NVMe), 1 in each of 2 AZs | 1 per node |

  3 `proc` + 2 `ui` (decided for the first cluster; counts can only grow, 11.1). Instance types are a starting guess, since the docs give no sizing; production is sized from the current deployment's load **(open)**. Stroom alone needs 32 vCPU (3 × 8 + 2 × 4); with the system and proxy nodes the dev account's On-Demand vCPU quota (32 today) must go to about 64.
* **Pods**: one per node (anti-affinity), memory request = limit. Heap about 40–50 % of the limit (`-Xmx` via `extraJvmOpts` or `memoryOptions`), leaving the rest for direct memory, LMDB page cache and the OS. Example for `r6id.2xlarge`: limit 56 GiB, heap 24 GiB.
* **EBS** `data` PVC per pod: gp3, size and IOPS per node set; one per AZ group so the pod always has a node in its volume's AZ.
* **Probes**: a long startup probe (migrations hold a lock, S14); readiness on 8081.
* **Jobs**: the `proc` node set runs all jobs including the S3 event poll; the `ui` set runs only the UI-side jobs (operator default: "Reindex Content").

## 12. Upgrades and maintenance

| Change | How |
|---|---|
| Stroom version | Stop all nodes with the StroomCluster's `stopped: true` (a new operator field that scales every StatefulSet to 0 without changing `count`, which may only grow; 11.1), waiting for each `preStop` drain; change the image; set `stopped: false`. The first node to start runs the migrations under the cluster-wide lock and the others wait (S14), so the startup probes allow for the migration time. Downtime is the drain plus migration time; data waits in SQS (7.1). Whether a rolling version upgrade is safe is unknown (S14) **(open)**. |
| Adding a node | Raise the node set's `count` (and its node groups, if there is no room). The new pod gets the next ordinal and name; the bootstrap Job runs again, adds its index volume and enables its jobs (5.4). |
| Removing a node | Not supported by an apply; manual runbook only (11.1). |
| Config change, same version | Rolling restart, one pod at a time, each draining its tasks (operator `preStop`). |
| Node AMI or instance type | One AZ group at a time: add a node to the group, cordon and drain the old one (the pod moves to the new node with its EBS volume, which stays in the AZ; its NVMe `emptyDir` data is rebuilt), remove the old node. The PDB allows one pod down per node set. Blue/green node colours (proxy design section 9) aren't used: Stroom pods hold per-node state and can't run twice. |
| Database | RDS minor versions in the maintenance window; major versions after a snapshot, with Stroom stopped. |

Because ingest is decoupled through SQS, Stroom downtime delays processing but loses no data. Users lose the UI for the duration.

## 13. Security

* Namespace `stroom`, Pod Security `restricted` (after operator change 10.2.5); non-root uid 1000.
* NetworkPolicy: 8443 from the lb subnets (ALB), from other Stroom pods (node-to-node) and from the proxy pods (receipt rules, 8.1); 8081 from the lb subnets (health checks) and the namespace; nothing else, so 8080 is reachable only inside the pod. Egress unrestricted in v1 (IdP, AWS APIs, RDS).
* Pod Identity roles: Stroom's (7.4) and the bootstrap Job's (5.4); nothing else gets them.
* RDS: private, TLS required (`require_secure_transport`, once operator change 10.2.4 is in), security group limited to the Stroom, operator and init Job pods' subnets.
* EFS: access point with a fixed uid/gid, mount targets in the private subnets, security group on 2049 from the nodes.
* `clustercall.rpc` blocked at the ALB (S13).
* Secrets (DB password, OIDC client secret, the proxy's API key, the TLS keystore) only in Secrets Manager and Kubernetes Secrets, never in Terraform state (ESO and cert-manager).

## 14. Observability

* Stroom logs to stdout → Fluent Bit → CloudWatch (the operator's config; check the console appenders, as for the proxy).
* CloudWatch alarms: SQS queue age of oldest message (ingest falling behind), DLQ depth > 0 (refused objects), RDS CPU, storage and connections, EFS throughput, ALB 5xx and unhealthy targets.
* Stroom's own health checks on 8081; metrics-server for the task autoscaler.

## 15. Terraform inputs (proposed, `40-stroom`)

```hcl
name                    = "stroom-dev"
node_name_prefix        = "stroom-dev"     # node names stroom-dev-proc-0, stroom-dev-ui-0, … (11.1)
stroom_image            = { repository = "gchq/stroom", tag = "v7.14-beta.N", digest = "sha256:…" }
raw_data_retention_days = 90               # longest Stroom retention for raw streams; checked against the bucket expiry (7.3)
hostname                = "stroom.example.internal"
tls_certificate_source  = "acm_private_ca"   # as the proxy
route53_zone_id         = null
allowed_ingress_cidrs   = ["10.0.0.0/8"]

node_sets = {
  # count may only grow (11.1); node set names and node_name_prefix are permanent
  proc = { count = 3, memory_limit = "56Gi", heap = "24g", cpu = 7, data_volume_gb = 500, jobs = "all" }
  ui   = { count = 2, memory_limit = "14Gi", heap = "6g",  cpu = 3, data_volume_gb = 50,  jobs = "ui" }
}

stream_volume = { type = "efs" }               # s3_v1 tested later (5.3)

database = {
  engine         = "mysql"
  engine_version = "8.4"
  instance_class = "db.r6g.large"
  multi_az       = true
  storage_gb     = 200
}

idp = {
  type          = "entra"                      # entra | keycloak | cognito
  discovery_url = null                         # derived for entra from tenant_id
  tenant_id     = "<tenant>"
  client_id     = "<client id>"
  client_secret_secret_name = "stroom/dev/oidc-client-secret"
  first_admin   = "<oid of first admin>"
}

ingest = {
  queue_url = null                             # null → from 30-stroom-proxy remote state
  dlq_url   = null
  bucket    = null
}

proxy_api_key_secret_name = "stroom/dev/proxy-api-key"   # written by the bootstrap Job (5.4)
```

And in `30-stroom-proxy`, for the second apply (4.3):

```hcl
stroom_downstream = {
  hostname            = "stroom-dev-ui-http.stroom.svc.cluster.local"  # the operator's ui Service (named from node_name_prefix), port 8443
  api_key_secret_name = "stroom/dev/proxy-api-key"
  ca_bundle_configmap = "stroom-internal-ca"                           # from trust-manager (9.1)
}   # sets receipt.check_mode = RECEIPT_POLICY, receipt.fallback_action = RECEIVE and downstream
```

## 16. Decisions and open questions

### 16.1 Decisions (2026-10-30)

| Question | Decision |
|---|---|
| Deployment method | The operator (`StroomCluster`), after merging upstream `gradata-systems/stroom-k8s-operator` into the fork (10, S19). |
| Storage | EFS for shared file storage (the stream store), local NVMe for LMDB that can be rebuilt and for temp, a per-node EBS volume for index shards and the LMDB stores that hold state (5). |
| Stream store type | EFS now; test a writable `S3_V1` volume later (5.3). |
| Database | Amazon RDS for MySQL 8.4, Multi-AZ (6). |
| Duplicate streams (S6) | Raise a Stroom issue for a uniqueness check on bucket, key and version in `fs_meta_s3_location`; accept rare duplicates until it lands. |
| IdP registrations | Created outside Terraform by the tenant's owners; the module takes IDs and a secret name (8). |
| Operator authentication | Extend the operator's API key automation to external IdPs; no client-credentials client (8, 10.2). |
| Stroom-Proxy → Stroom | Receipt policy (`RECEIPT_POLICY`), fallback `RECEIVE`, authenticated with a Stroom API key (8.1). |
| TLS inside the cluster | HTTPS to the pods from the ALB, the proxy and other nodes (9.1). |
| Node removal | Manual runbook only; nothing in Terraform relaxes the guards (11.1). |
| First cluster | 3 `proc` + 2 `ui` (11.2). |
| Retention | Set per environment; the module checks the bucket expiry against Stroom's raw-stream retention (7.3). |
| Terraform directory | Rename `terraform/aws-eks-proxy` to `terraform/aws-eks` (4.2). |

### 16.2 Open

1. **Sizing for production**: node types, heap, EBS, EFS and RDS sizes from the current deployment's load (11.2).
2. **Version upgrades**: can 7.14.x patch releases roll, or is stop-all always needed (S14)?
3. **Health check** endpoint suitable for the ALB and readiness (9, S15).
4. **Image architecture** of `gchq/stroom` (S15).
5. **TLS details**: does Stroom reload its keystore; do nodes verify each other's certificates; is `nodeUri.scheme: https` enough (9.1).
6. **Bootstrap Job**: the exact API and CLI calls for volumes, jobs, the first admin and the proxy's API key (5.4).
7. **Secret expiry**: reminders for the Entra client secret; lifetime and renewal of the proxy's API key (8, 8.1).
8. **EBS performance** for the state LMDB stores and index shards (5.1).
9. **Reference data `EffectiveTime`**: the proxy's S3 forwarder doesn't carry `EffectiveTime` in object metadata, so reference streams ingested from S3 get the receipt time as effective time **(to test)**.
10. **eTag `If-Match`**: S3 event eTags are unquoted; check `HeadObject` accepts them **(to test; the ingest spike answers it)**.
11. **Proxy restart while Stroom is down** under `RECEIPT_POLICY`: does it start and receive with no cached rules (8.1) **(to test)**.
12. **RDS compatibility**: Stroom's migrations and `max_connections` on RDS MySQL 8.4 **(to test)**.
13. **Upstream merge choices**: image registry, version numbering, release workflows (S19).
14. **Proxy trust of the in-cluster CA**: which proxy config (HTTP client TLS settings) takes the CA bundle (8.1, 9.1).

## 17. Implementation phases

0. **Groundwork**: merge upstream `gradata-systems/stroom-k8s-operator` `master` into the fork (S19), keeping fork #34; rename `terraform/aws-eks-proxy` to `terraform/aws-eks`; raise the Stroom issue for duplicate streams (S6).
1. **Ingest spike** (early, since S1–S8 are beta code): a single Stroom pod in the dev cluster with a throwaway MySQL, the read-only volume and the queue, Pod Identity. Done when a proxy zip becomes a stream, a pipeline reads it, the DLQ path works, and the eTag and `EffectiveTime` questions (16.2.9, 16.2.10) are answered.
2. **Operator changes** (10.2), with the upstream golden-file and `envtest` tests extended to cover them.
3. **`10-infra` and `20-platform` additions**: Stroom node groups with NVMe RAID0, EFS CSI driver and StorageClass, cert-manager and trust-manager with the in-cluster CA, metrics-server, the operator and CRDs.
4. **`modules/stroom-db`** and **`modules/stroom`** / `40-stroom`, and `stroom_downstream` in `30-stroom-proxy`: RDS and its init Job, EFS, ALB, certificate, Pod Identity, ExternalSecrets, `StroomCluster`, the bootstrap Job and key renewal CronJob, `terraform test` suites; first build in the order of 4.3. Done when users sign in through Entra ID, the `proc` set ingests from SQS, the `ui` set serves the UI behind the ALB with sticky sessions, `clustercall.rpc` and `/datafeed` are refused at the ALB, and the proxy fetches receipt rules from Stroom with its API key and keeps receiving while Stroom is stopped.
5. **Operations**: version upgrade and node replacement runbooks, alarms (14), a dev test round like the proxy's (proxy design 15.1).
6. **Later**: Keycloak and Cognito presets tested, PrivateLink for the UI, `S3_V1` stream volumes.
