################################################################################
# Namespace and network policy (design section 13)
################################################################################

resource "kubernetes_namespace_v1" "stroom" {
  metadata {
    name = var.namespace
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
      # Pods are only Ready once healthy in the ALB target group
      "elbv2.k8s.aws/pod-readiness-gate-inject" = "enabled"
      # trust-manager writes the in-cluster CA's certificate here
      (var.internal_ca.namespace_label.key) = var.internal_ca.namespace_label.value
    }
  }
}

# Stroom's HTTPS port from the ALB, the other Stroom nodes, the bootstrap Job
# and the proxy; its admin port (health checks) from the ALB and the other
# Stroom nodes. Nothing reaches 8080, which only the in-pod lifecycle scripts
# use.
resource "kubernetes_network_policy_v1" "stroom" {
  metadata {
    name      = "stroom-ingress"
    namespace = kubernetes_namespace_v1.stroom.metadata[0].name
  }

  spec {
    # The operator labels each Stroom pod with its cluster and node set only
    pod_selector {
      match_labels = { "stroom/cluster" = var.cluster_resource_name }
    }
    policy_types = ["Ingress"]

    ingress {
      dynamic "from" {
        for_each = var.lb_subnet_cidrs
        content {
          ip_block {
            cidr = from.value
          }
        }
      }
      from {
        pod_selector {
          match_labels = { "stroom/cluster" = var.cluster_resource_name }
        }
      }
      ports {
        protocol = "TCP"
        port     = tostring(local.ports.https)
      }
      ports {
        protocol = "TCP"
        port     = tostring(local.ports.admin)
      }
    }

    # The bootstrap Job (design 5.4) uses Stroom's API on the Frontend Service
    ingress {
      from {
        pod_selector {
          match_labels = local.bootstrap_pod_labels
        }
      }
      ports {
        protocol = "TCP"
        port     = tostring(local.ports.https)
      }
    }

    dynamic "ingress" {
      for_each = var.proxy_namespace == null ? [] : [var.proxy_namespace]
      content {
        from {
          namespace_selector {
            match_labels = { "kubernetes.io/metadata.name" = ingress.value }
          }
        }
        ports {
          protocol = "TCP"
          port     = tostring(local.ports.https)
        }
      }
    }
  }
}

################################################################################
# Secrets, from Secrets Manager through External Secrets (20-platform)
################################################################################

resource "kubernetes_manifest" "secret_store" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "SecretStore"
    metadata = {
      name      = local.secrets_manager_store
      namespace = kubernetes_namespace_v1.stroom.metadata[0].name
    }
    spec = {
      provider = {
        aws = {
          service = "SecretsManager"
          region  = var.aws_region
          # Stroom's own role (iam.tf), which reads Stroom's secrets only
          role = aws_iam_role.external_secrets.arn
        }
      }
    }
  }

  depends_on = [aws_iam_role_policy.external_secrets, time_sleep.pod_identity_propagation]
}

# The Stroom database user's password, in the form the operator expects: the
# key is the user name. A second key carries the password's generation, so the
# database init Job can wait until External Secrets has fetched the new
# password; changing it changes the spec, so External Secrets fetches at once.
resource "kubernetes_manifest" "db_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = local.db_secret_name
      namespace = kubernetes_namespace_v1.stroom.metadata[0].name
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef  = { name = local.secrets_manager_store, kind = "SecretStore" }
      target = {
        name           = local.db_secret_name
        creationPolicy = "Owner"
        template = {
          engineVersion = "v2"
          data = {
            (var.db.app_user)               = "{{ .password }}"
            (local.db_password_version_key) = tostring(var.db.app_user_password_version)
          }
        }
      }
      data = [{
        secretKey = "password"
        remoteRef = { key = var.db.app_user_secret_name }
      }]
    }
  }

  depends_on = [kubernetes_manifest.secret_store]
}

# The RDS-managed master credentials, for the database init Job only. RDS
# rotates them, so the annotation makes External Secrets fetch them again
# whenever the init Job is about to run again.
resource "kubernetes_manifest" "db_master_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = local.db_master_secret_name
      namespace = kubernetes_namespace_v1.stroom.metadata[0].name
      annotations = {
        "stroom.gchq.github.io/refresh-for" = "stroom-db-init-${local.db_init_hash}"
      }
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef  = { name = local.secrets_manager_store, kind = "SecretStore" }
      target          = { name = local.db_master_secret_name, creationPolicy = "Owner" }
      data = [
        { secretKey = "username", remoteRef = { key = var.db.master_user_secret_arn, property = "username" } },
        { secretKey = "password", remoteRef = { key = var.db.master_user_secret_arn, property = "password" } },
      ]
    }
  }

  depends_on = [kubernetes_manifest.secret_store]
}

resource "kubernetes_manifest" "oidc_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = local.oidc_secret_name
      namespace = kubernetes_namespace_v1.stroom.metadata[0].name
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef  = { name = local.secrets_manager_store, kind = "SecretStore" }
      target          = { name = local.oidc_secret_name, creationPolicy = "Owner" }
      data = [{
        secretKey = "client-secret"
        remoteRef = { key = "${var.secrets_name_prefix}${var.idp.client_secret_name}" }
      }]
    }
  }

  depends_on = [kubernetes_manifest.secret_store]
}

# The password of each node's keystore and truststore, generated in the cluster
# once, so it is never in Terraform state
resource "kubernetes_manifest" "keystore_password_generator" {
  manifest = {
    apiVersion = "generators.external-secrets.io/v1alpha1"
    kind       = "Password"
    metadata = {
      name      = local.generator_name
      namespace = kubernetes_namespace_v1.stroom.metadata[0].name
    }
    spec = {
      length      = 32
      digits      = 8
      symbols     = 0
      noUpper     = false
      allowRepeat = true
    }
  }
}

resource "kubernetes_manifest" "keystore_password" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = local.keystore_password_name
      namespace = kubernetes_namespace_v1.stroom.metadata[0].name
    }
    spec = {
      refreshPolicy = "CreatedOnce"
      target        = { name = local.keystore_password_name, creationPolicy = "Owner" }
      dataFrom = [{
        sourceRef = {
          generatorRef = {
            apiVersion = "generators.external-secrets.io/v1alpha1"
            kind       = "Password"
            name       = local.generator_name
          }
        }
      }]
    }
  }

  depends_on = [kubernetes_manifest.keystore_password_generator]
}

# The RDS CA bundle: the operator and Stroom verify the database's certificate
resource "kubernetes_config_map_v1" "db_ca" {
  metadata {
    name      = local.db_ca_configmap_name
    namespace = kubernetes_namespace_v1.stroom.metadata[0].name
  }
  data = {
    "ca.pem" = var.db.ca_bundle_pem
  }
}

################################################################################
# The nodes' certificate (design 9.1): one certificate for every node set's
# Services and pods, from the in-cluster CA. cert-manager keeps the key in the
# cluster; the operator turns it into each node's keystore when the node
# starts, so a renewed certificate is only used after a restart.
#
# Renewal: cert-manager renews the certificate renewBefore (90 days) ahead of
# its expiry and raises status.revision. Terraform reads the revision at plan
# time and puts it in a pod annotation, so the next apply after a renewal
# restarts the nodes one at a time with the new certificate. Until then the
# nodes keep serving the old one, which is still valid: an apply is needed
# within the 90 days (design 9.1 runbook).
################################################################################

resource "kubernetes_manifest" "tls_certificate" {
  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = local.tls_secret_name
      namespace = kubernetes_namespace_v1.stroom.metadata[0].name
    }
    spec = {
      secretName  = local.tls_secret_name
      duration    = "8760h"
      renewBefore = "2160h"
      privateKey  = { algorithm = "RSA", size = 2048, rotationPolicy = "Always" }
      dnsNames = flatten([
        for k, n in local.node_set_names : [
          "*.${local.headless_services[k]}.${var.namespace}.svc.cluster.local",
          "${local.http_services[k]}.${var.namespace}.svc",
          "${local.http_services[k]}.${var.namespace}.svc.cluster.local",
        ]
      ])
      issuerRef = {
        group = "cert-manager.io"
        kind  = "ClusterIssuer"
        name  = var.internal_ca.cluster_issuer
      }
    }
  }

  # Issued before the nodes start, and before its revision is read
  wait {
    condition {
      type   = "Ready"
      status = "True"
    }
  }

  timeouts {
    create = "10m"
    update = "10m"
  }
}

# The certificate's current revision. Read after the Certificate is created or
# changed, so a reissue in the same apply restarts the nodes in that apply.
data "kubernetes_resource" "tls_certificate" {
  api_version = "cert-manager.io/v1"
  kind        = "Certificate"
  metadata {
    name      = local.tls_secret_name
    namespace = var.namespace
  }

  depends_on = [kubernetes_manifest.tls_certificate]
}

locals {
  # 1 until cert-manager reports a revision
  tls_revision = try(coalesce(data.kubernetes_resource.tls_certificate.object.status.revision, 1), 1)
}

################################################################################
# Stroom's configuration (the operator mounts it as config.yml)
################################################################################

resource "kubernetes_config_map_v1" "config" {
  metadata {
    name      = local.config_configmap_name
    namespace = kubernetes_namespace_v1.stroom.metadata[0].name
  }
  data = {
    (local.config_configmap_key) = local.stroom_config
  }
}

################################################################################
# Database init Job (design section 6): the two schemas and the Stroom user,
# before the StroomCluster exists. Idempotent; replaced, and so run again,
# when its inputs change, including the password's generation: a new password
# (modules/stroom-db) is set with ALTER USER, keeping the previous one valid as
# MySQL's secondary password, so the running nodes can still connect while
# they restart with the new one (restart_annotations). The next rotation drops
# the previous password; to drop it sooner, run
# ALTER USER '<user>'@'%' DISCARD OLD PASSWORD once every node has restarted.
################################################################################

locals {
  db_password_version_key = "password-version"

  db_init_sql = <<-EOT
    CREATE DATABASE IF NOT EXISTS stroom CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
    CREATE DATABASE IF NOT EXISTS stats CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
    CREATE USER IF NOT EXISTS '${var.db.app_user}'@'%' IDENTIFIED BY '$APP_PASSWORD' REQUIRE SSL;
    ALTER USER '${var.db.app_user}'@'%' IDENTIFIED BY '$APP_PASSWORD' RETAIN CURRENT PASSWORD REQUIRE SSL;
    GRANT ALL PRIVILEGES ON stroom.* TO '${var.db.app_user}'@'%';
    GRANT ALL PRIVILEGES ON stats.* TO '${var.db.app_user}'@'%';
  EOT
  db_init_hash = substr(sha256(jsonencode([
    local.db_init_sql, var.db.host, var.db.app_user_secret_name, var.db.app_user_password_version,
  ])), 0, 8)
}

resource "kubernetes_job_v1" "db_init" {
  metadata {
    name      = "stroom-db-init-${local.db_init_hash}"
    namespace = kubernetes_namespace_v1.stroom.metadata[0].name
  }

  spec {
    backoff_limit              = 6
    active_deadline_seconds    = 1800
    ttl_seconds_after_finished = null

    template {
      metadata {
        labels = { "app.kubernetes.io/name" = "stroom-db-init" }
      }
      spec {
        restart_policy                  = "Never"
        automount_service_account_token = false
        node_selector                   = { (local.node_labels[local.frontend_node_set].key) = local.node_labels[local.frontend_node_set].value }
        toleration {
          key      = var.stroom_node_taint.key
          operator = "Equal"
          value    = var.stroom_node_taint.value
          effect   = var.stroom_node_taint.effect
        }

        security_context {
          run_as_non_root = true
          run_as_user     = 999
          run_as_group    = 999
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name  = "db-init"
          image = "mysql:8.4"
          # The password goes in SQL through the environment, never in
          # arguments. It's read from the Secret's volume, which the kubelet
          # updates, once External Secrets has fetched this generation.
          command = ["bash", "-ec", <<-EOT
            for _ in $(seq 1 120); do
              [ "$(cat /etc/stroom-db/${local.db_password_version_key} 2>/dev/null)" = "${var.db.app_user_password_version}" ] && break
              echo "Waiting for generation ${var.db.app_user_password_version} of the Stroom user's password"
              sleep 5
            done
            [ "$(cat /etc/stroom-db/${local.db_password_version_key})" = "${var.db.app_user_password_version}" ]
            APP_PASSWORD=$(cat "/etc/stroom-db/${var.db.app_user}")
            mysql --host="${var.db.host}" --port=${var.db.port} --user="$MASTER_USER" \
              --ssl-mode=VERIFY_IDENTITY --ssl-ca=/etc/db-ca/ca.pem <<SQL
            ${indent(2, local.db_init_sql)}
            SQL
            echo "Stroom database and user ready"
          EOT
          ]

          env {
            name = "MASTER_USER"
            value_from {
              secret_key_ref {
                name = local.db_master_secret_name
                key  = "username"
              }
            }
          }
          env {
            name = "MYSQL_PWD"
            value_from {
              secret_key_ref {
                name = local.db_master_secret_name
                key  = "password"
              }
            }
          }
          volume_mount {
            name       = "db-ca"
            mount_path = "/etc/db-ca"
            read_only  = true
          }
          volume_mount {
            name       = "stroom-db"
            mount_path = "/etc/stroom-db"
            read_only  = true
          }

          security_context {
            allow_privilege_escalation = false
            capabilities {
              drop = ["ALL"]
            }
          }

          resources {
            requests = { cpu = "100m", memory = "128Mi" }
            limits   = { memory = "256Mi" }
          }
        }

        volume {
          name = "db-ca"
          config_map {
            name = kubernetes_config_map_v1.db_ca.metadata[0].name
          }
        }
        volume {
          name = "stroom-db"
          secret {
            secret_name = local.db_secret_name
          }
        }
      }
    }
  }

  wait_for_completion = true
  timeouts {
    create = "30m"
    update = "30m"
  }

  depends_on = [terraform_data.input_checks, kubernetes_manifest.db_secret, kubernetes_manifest.db_master_secret]
}

################################################################################
# The Frontend node set's pods in the ALB target group
################################################################################

resource "kubernetes_manifest" "target_group_binding" {
  manifest = {
    apiVersion = "elbv2.k8s.aws/v1beta1"
    kind       = "TargetGroupBinding"
    metadata = {
      name      = local.http_services[local.frontend_node_set]
      namespace = kubernetes_namespace_v1.stroom.metadata[0].name
    }
    spec = {
      targetGroupARN = aws_lb_target_group.ui.arn
      targetType     = "ip"
      serviceRef = {
        name = local.http_services[local.frontend_node_set]
        port = local.ports.https
      }
    }
  }
}

################################################################################
# The StroomCluster (design sections 10 and 11)
################################################################################

resource "kubernetes_manifest" "stroom_cluster" {
  manifest = {
    apiVersion = "stroom.gchq.github.io/v1"
    kind       = "StroomCluster"
    metadata = {
      name      = var.cluster_resource_name
      namespace = kubernetes_namespace_v1.stroom.metadata[0].name
    }
    spec = local.stroom_cluster_spec
  }

  # The operator's defaults fill in fields Terraform doesn't set
  computed_fields = ["metadata.annotations", "metadata.labels", "spec"]

  field_manager {
    force_conflicts = true
  }

  timeouts {
    create = "60m"
    update = "60m"
  }

  depends_on = [
    terraform_data.input_checks,
    kubernetes_job_v1.db_init,
    kubernetes_manifest.oidc_secret,
    kubernetes_manifest.keystore_password,
    kubernetes_manifest.tls_certificate,
    kubernetes_manifest.target_group_binding,
    kubernetes_network_policy_v1.stroom,
    kubernetes_persistent_volume_claim_v1.stream,
    aws_lb_listener.https,
    aws_iam_role_policy.stroom,
    time_sleep.pod_identity_propagation,
  ]
}
