# Changelog

## Unreleased

- `spec.nodeNamePrefix` sets the prefix of the NodeSets' StatefulSet, Service and so Stroom node names, in place of
  `stroom-<cluster>-node`: prefix `stroom-prod` and NodeSet `proc` give nodes `stroom-prod-proc-0`, …. It can't be
  added, changed or removed once the StroomCluster exists. Unset, names are as before.
- `spec.preventNodeRemoval` refuses any update that lowers a NodeSet's count or removes or renames a NodeSet, as Stroom
  nodes own their index shards. It applies to the update that turns it off as well, so removing a node takes two
  updates.
- `spec.stopped` scales every NodeSet to zero, each node draining first, without changing the counts, for example for
  a Stroom version upgrade. PVCs are kept while stopped, whatever the `volumeClaimDeletePolicy`.
- NodeSets can set `topologySpreadConstraints` (a constraint without a label selector selects the NodeSet's own Pods)
  and `podDisruptionBudget` (`maxUnavailable`, default 1), which creates a PodDisruptionBudget for the NodeSet. The
  operator's ClusterRole gains PodDisruptionBudget permissions.
- NodeSet names are limited to 30 characters and a StroomCluster to 20 NodeSets, to keep the API server's validation
  cost bounded. Existing longer names are kept while unchanged.

## 2.0.0

This is the `gchq/stroom-k8s-operator` fork. It merges upstream `gradata-systems/stroom-k8s-operator` 1.2.0-beta.1
(below) into the fork's 2.0.0, with these differences from upstream:

- The operator image stays on Docker Hub as `gchq/stroom-k8s-operator`, and the charts are published to
  `oci://ghcr.io/gchq/helm-charts`, by the fork's own release workflows. Upstream's tag-driven `release.yml` and
  `RELEASING.md` are not used.
- The Helm chart's `registry` value is the full image repository, as in the fork's 2.0.0
  (e.g. `my-registry.example.com/gchq/stroom-k8s-operator`); it replaces `image.repository`. Upstream's note about
  `<registry>/gradata-systems/stroom-k8s-operator` below doesn't apply.
- The operator provisions and renews a Stroom API key for its node lifecycle scripts when `spec.identityProviderType`
  is `INTERNAL_IDP` (Stroom 7.13 or later). This fixes the known issue listed under upstream 1.2.0-beta.1.

### Upgrade notes for 2.0.0

1. Upgrade to Stroom 7.13 or later. Earlier versions are not supported.
2. Remove any manually-configured API key from your `StroomCluster` resources (e.g. `extraEnv`, or `extraVolumes` /
   `extraVolumeMounts` at `/stroom/api-key`). The operator now provisions the key itself.
3. If you set `IDENTITY_PROVIDER_TYPE` via `extraEnv`, remove it and set `spec.identityProviderType` instead.
4. If you use an external identity provider, set `spec.identityProviderType: EXTERNAL_IDP` and set `spec.openId`.
5. If you install from a private registry, set `registry` to the full image repository.
6. Also read the upstream 1.2.0-beta.1 upgrade notes below: every node set and DatabaseServer rolls once.

## 1.2.0-beta.1

### Upgrade notes

Read these before upgrading. See [Upgrading](https://gradata-systems.github.io/stroom-k8s-operator/operations/upgrading/)
for details.

- **The operator image moves to `ghcr.io/gradata-systems/stroom-k8s-operator`.** Releases up to 1.1.5 remain on
  Docker Hub. The Helm chart's `registry` value now replaces the registry in the new `image.repository` value, so
  mirrors are expected at `<registry>/gradata-systems/stroom-k8s-operator`.
- **The all-in-one manifest is no longer published.** Install and upgrade with the Helm charts. An operator
  installed from the manifest moves to Helm without stopping Stroom, by labelling its resources for Helm to adopt;
  see [Upgrading](https://gradata-systems.github.io/stroom-k8s-operator/operations/upgrading/#from-the-all-in-one-manifest).
- **Every node set rolls once**, as the Stroom node probes and security settings change.
- **Database servers restart once**, as their Pod is now updated to match the `DatabaseServer`.
- **Liveness and readiness probes filter Stroom's health checks** (#62). Liveness runs only the `deadlocks` check, and
  readiness runs every check except the external identity provider's, so an identity provider outage no longer
  restarts every node, and nodes keep receiving data. Set `allow: []` or `deny: []` to run every check.
- **Node sets that omit probe timings now get the CRD defaults**, rather than Kubernetes' probe defaults.
- **Existing `StroomCluster`s keep a startup `failureThreshold` of 10**, which the API server stored when they were
  created. Remove it, or set it to 24, to use the new default of about two minutes.
- **Scaling a node set rolls it**, when its pods start in parallel (`podManagementPolicy: Parallel`), as the startup
  probe allows more time the more nodes there are.
- **Stricter validation.** Database names, `DatabaseServer.spec.additionalConfig`, node `role` and
  `volumeClaimDeletePolicy` are now validated. A resource with an invalid value can't be changed until it's fixed.
- **Ingress TLS follows `ingress.secretName`**, rather than `spec.https`. Without a Secret, the Ingresses have no TLS
  section, where they previously had an empty one.
- **The operator can no longer list, watch, change or delete Secrets**, only get and create them.

### Fixed

- Liveness and readiness probes ignored `periodSeconds`, taking the period from `initialDelaySeconds`.
- Nodes waiting on the Stroom bootstrap lock, held while another node upgrades the database, were restarted. The
  startup probe now allows `lockWaitAllowanceSeconds` (default 30) for each additional node starting in parallel.
- A `StroomCluster` without a log sender was never deployed, as the operator couldn't add its finalizer.
- Database backups didn't run on Kubernetes 1.25 and later, as the CronJob was looked up with `batch/v1beta1`.
  Changes to a `DatabaseBackup` are now applied. A backup whose dump failed reported success and left an empty
  archive; it now fails the Job, and removes the archive. A backup in an image without `gzip`, such as
  `mysql/mysql-server`, now fails with a message saying so; use the official `mysql:8.4` image.
- Changes to a `DatabaseServer` were never applied, and its `podAnnotations` were ignored. Now that they are, the
  nodes of a `StroomCluster` aren't created or changed while its `DatabaseServer`'s Pod is being replaced, as a node
  stopping then couldn't drain.
- A `DatabaseServer`'s readiness probe always succeeded, before MySQL accepted connections.
- A `DatabaseServer` whose name differed from its `StroomCluster`'s couldn't be used, as the claim recorded the wrong
  name.
- Deleting a `StroomCluster` disabled jobs on other clusters' nodes whose names started the same way, and waited for
  tasks on every node in the database. A `StroomCluster` whose nodes had never started couldn't be deleted, as the
  database had no Stroom tables to drain it with.
- A node stopped without draining if its task count couldn't be retrieved.
- The datafeed Ingress failed with `spec.https`, as it had no HTTPS backend protocol, and an omitted `className` was
  sent as an empty class.
- Task autoscaling divided by zero without a CPU limit, and autoscalers for the same cluster interfered with each
  other.
- Stroom failed to start with the bundled configuration unless `spec.https` was set, as the configuration always had
  an HTTPS connector. It now only has one with `spec.https`.
- Stroom failed to start with `spec.https`, as the key store init container created the key store and trust store
  readable only by root, and the Stroom image runs Stroom as the `stroom` user. They're now given to that user.
- After a node set was changed to run as the `stroom` user, the node lifecycle scripts couldn't write the logs they
  had created as root. They now give their logs to that user, and log to stderr, which appears in the probe or
  hook's failure event, when a log can't be written.

### Security

- Database names were interpolated into SQL run as root, and into the backup job's shell command.
- With images other than `mysql/mysql-server`, the MySQL root password was the path `/etc/mysql/password/root`.
- The OpenID client secret was visible in the node container's process list, and the key store password in the key
  store init container's, and the database password in the backup job's.
- `DatabaseServer.spec.additionalConfig` could set any server option, including those giving file access or
  bypassing authentication.
- The operator could read and change every Secret in the cluster.
- The operator connected to MySQL without TLS.
- Pods now disallow privilege escalation, use the runtime's default seccomp profile, and don't mount a service
  account token, unless set otherwise.
- Built with Go 1.26.10, and updated golang.org/x/net and golang.org/x/text, fixing vulnerabilities reported by
  govulncheck. Base images are pinned by digest.

### Added

- Documentation, published at https://gradata-systems.github.io/stroom-k8s-operator/, with a CRD reference.
- Example deployments in `samples/`, applied with `kubectl apply -k`: with an operator-managed database, with an
  external database, and a custom Stroom configuration for Keycloak that both include. They include backups, task
  autoscaling and NetworkPolicies.
- Unit, envtest and end-to-end tests, run against Stroom 7.13 with Keycloak, and releases published from GitHub
  releases.

### Known issues

- With Stroom 7.13's internal identity provider, the node lifecycle scripts can't obtain a token, so nodes never
  become ready. Use an external identity provider.
