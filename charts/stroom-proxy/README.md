# stroom-proxy Helm chart

Runs [Stroom-Proxy](https://github.com/gchq/stroom) 7.14 as a StatefulSet, for
use behind an AWS load balancer (ALB) with blue/green upgrades. It is written
for the Terraform in [`terraform/aws-eks-proxy`](../../terraform/aws-eks-proxy),
which renders its values; the design is in
[`design/proxy-eks-terraform-design.md`](../../design/proxy-eks-terraform-design.md).

## What it creates

One release is one **colour** of a blue/green deployment (`colour`, e.g.
`blue`). Resource names are suffixed with it, so a second release (`green`)
can run beside the first in the same namespace.

* A **StatefulSet** of `replicas` proxies, one per node (pod anti-affinity),
  spread across zones, pinned to nodes labelled `stroom-proxy/colour=<colour>`
  and tolerating the proxy nodes' taint. Each pod gets its own data volume
  (`persistence`), kept when pods or the release are removed, so unsent data
  survives.
* A **ClusterIP Service** (`https`, `admin`) for the load balancer's
  `TargetGroupBinding`, and a headless Service for the StatefulSet.
* A **ConfigMap** with the proxy's `config.yml`, a **PodDisruptionBudget** and
  a **ServiceAccount** (for EKS Pod Identity).

The pod runs as the image's `proxy` user (uid 1000) and meets the `restricted`
Pod Security Standard.

### Containers

| Container | What it does |
|---|---|
| `tls` (init) | Generates a self-signed certificate for the HTTPS connectors, in a memory-backed `emptyDir`. The ALB doesn't verify target certificates; this only encrypts the hop inside the VPC. |
| `dfk-sync-init` (init, optional) | Downloads the data feed key files from S3 before the proxy starts. |
| `dfk-sync` (native sidecar, optional) | Re-syncs them every `dfkSync.intervalSeconds`. Files are renamed into place, never written in place, and the proxy reloads them without a restart. |
| `stroom-proxy` | The proxy. |
| `log-sender` (optional, off) | The non-root stroom-log-sender, posting the rolled logs to `https://localhost:<ports.local>/datafeed`. Off until a released image exists. |

### Ports

| Port | Purpose |
|---|---|
| `8443` (`ports.https`) | HTTPS from the load balancer. Sender addresses come from `X-Forwarded-For`. |
| `8444` (`ports.local`) | HTTPS bound to `127.0.0.1`, for in-pod callers. |
| `8091` (`ports.admin`) | Admin: health checks and metrics, plain HTTP. |

## Configuration

`proxyConfig` is the `proxyConfig` section of the proxy's own `config.yml`, in
the proxy's own keys (see the 7.14 configuration reference). Maps are merged
with the chart's defaults; lists replace them. The chart sets the paths
(`path.*`, `contentDir`, `receive.dataFeedIdentitiesDir`) and turns off the
directory scanner, whatever `proxyConfig` says. Values may refer to
environment variables as `${NAME}`; supply them with `extraEnv` or
`extraEnvFrom` (e.g. from a Secret).

The chart also checks that at least one forward destination is enabled (the
proxy refuses to start without one), and marks every destination
`enabled: true` unless it says otherwise. Without that, the proxy treats a
file or S3 destination with no `enabled` key as disabled, unlike an HTTP one.

Example (S3 forwarding, as the Terraform renders it):

```yaml
colour: blue
replicas: 3
image:
  digest: sha256:f729b691b7001dbf7d2b99fcae9d6c150c99fddd0840f4f3375f43edb34ff68f
serviceAccount:
  name: stroom-proxy
dfkSync:
  enabled: true
  bucket: my-receipt-config-bucket
  prefix: dfk/
proxyConfig:
  proxyId: prod
  forwardS3Destinations:
    - name: data-bucket
      client:
        region: eu-west-2
        bucketName: my-data-bucket
        # Must contain ${uuid} (or ${receiptId}): the proxy's default key
        # template doesn't give unique keys.
        keyPattern: ${type}/${year}/${month}/${day}/${feed}/${uuid}.zip
        multipart: true
```

### Notes for 7.14

* **Health checks**: `healthCheckPath` excludes, in one comma-separated `deny`
  list, the checks that call a downstream Stroom or the identity provider, so
  pods stay ready while those are down. Each name must be a registered check,
  or the endpoint answers 500.
* **SNI host check** is off on the HTTPS connectors. Requests carry the load
  balancer's host name, which the pod's self-signed certificate never matches,
  and Jetty would otherwise answer every request with `400 Invalid SNI`.
* **Client certificates** are checked by the ALB, which passes the subject DN
  in `X-Stroom-Mtls-Subject`. The proxy trusts that header from whoever sends
  it, so **only the ALB may reach port 8443**, and the ALB must strip or reject
  the header on its non-mTLS listener (see section 5.3 of the design).

## Draining

When a pod stops, the `preStop` hook sleeps for
`drain.deregistrationDelaySeconds` + `drain.preStopExtraSeconds`, so the pod
keeps serving while the load balancer deregisters it. Jetty then gets
`drain.shutdownGracePeriodSeconds` to finish in-flight requests.
`terminationGracePeriodSeconds` covers both. Set
`drain.deregistrationDelaySeconds` to the target group's deregistration delay.

## Testing

`hack/validate-stroom-proxy-chart.sh` (run in CI) renders the chart with each
values file in `ci/`, checks the generated `config.yml` with the proxy image's
own `check` command (which rejects unknown keys), and boots the proxy with the
default values: the health check must pass and an unauthenticated POST to
`/datafeed` must be refused. It needs Helm, Docker, curl and Python 3.

```sh
hack/validate-stroom-proxy-chart.sh                       # image from the chart's appVersion
hack/validate-stroom-proxy-chart.sh gchq/stroom-proxy@sha256:...
```

## Licence

MIT, like the rest of this repository. Written from scratch for this
repository: it is not derived from other Stroom-Proxy charts.
