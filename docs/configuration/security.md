# Security

## Pod security

Unless a node set, `DatabaseServer` or log sender sets them otherwise, the operator gives the pods it creates:

- `allowPrivilegeEscalation: false` on each container, except where a setting such as `privileged` requires it.
- The container runtime's default seccomp profile (`seccompProfile.type: RuntimeDefault`).
- No service account token (`automountServiceAccountToken: false`), as none of them use the Kubernetes API.

Capabilities and the user aren't changed. The Stroom and MySQL images start as root to set up their volumes, then
switch to an unprivileged user, so dropping every capability or requiring `runAsNonRoot` stops them starting as
they are. If your cluster enforces the Kubernetes `restricted` Pod Security Standard, set the node sets' security
contexts so the pods run as the `stroom` user (uid 1000) from the start:

```yaml
    - name: data
      podSecurityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000                       # makes the volumes writable by the stroom user
        fsGroupChangePolicy: OnRootMismatch # skips the ownership change once done, as volumes can hold many files
      securityContext:
        capabilities:
          drop: [ALL]
```

The Stroom image supports this: its entrypoint only changes volume ownership and user when it starts as root. The
node set's settings also apply to the Stroom pods' init containers (the HTTPS keystore and the database truststore)
and, for the first node set, to the API key Job, so all of them meet the same level. The operator's tests create
these pods in a namespace that enforces `restricted`. Leave the [log sender](log-shipping.md) off, or give it
settings of its own that meet the level.

## Operator permissions

The operator runs with a ClusterRole, as it manages resources in any namespace. It can `get` and `create`
Secrets, but not list, watch, change or delete them: it reads only the database password Secrets it uses, and
creates the generated `DatabaseServer` password Secret.

## Database connections

The operator and Stroom connect to MySQL with TLS when the server supports it, which MySQL 8 does by default. By
default neither verifies the server's certificate; for an external server, `serverAddress.tls` makes both verify it.
See [External database](../database/external-database.md#4-verify-the-servers-certificate-optional).

`DatabaseServer.spec.additionalConfig` can't set the options the operator sets, or options that give access to
the server's files or bypass authentication. See [Operator-managed DatabaseServer](../database/database-server.md).

## Network policies

The operator doesn't create NetworkPolicies, as which pods need to reach Stroom depends on your cluster: where your
Ingress controller runs, and whether data senders run inside it.
[`samples/operator-database/network-policies.yaml`](https://github.com/gradata-systems/stroom-k8s-operator/blob/master/samples/operator-database/network-policies.yaml)
is a starting point. It denies connections to pods in the Stroom namespace except:

- between the nodes of a `StroomCluster`,
- from the Ingress controller to the nodes' application ports (8080 and 8443),
- to the database server from the cluster's nodes, its backup jobs and the operator.

The nodes' admin port (8081), which serves health checks, is left reachable only from within the node's own pod and
by the kubelet's probes, which most network plugins allow regardless of NetworkPolicies; check yours does.
NetworkPolicies need a network plugin that enforces them.
