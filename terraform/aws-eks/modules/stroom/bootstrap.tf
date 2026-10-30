################################################################################
# Bootstrap Job (design 5.4): the first administrator, the proxy's user and
# API key, the S3 read-only volume for the data bucket, and the S3 event poll
# job. Volumes for written streams and indexes come from config.yml. Every
# step is idempotent; the Job is replaced, and so runs again, when its inputs
# change.
################################################################################

locals {
  processing_nodes = flatten([
    for k in sort(keys(var.node_sets)) : [
      for i in range(var.node_sets[k].count) : "${local.node_set_names[k]}-${i}"
    ] if var.node_sets[k].role == "Processing"
  ])
  first_processing_set = sort([for k, s in var.node_sets : k if s.role == "Processing"])[0]

  db_truststore_password = "db-truststore"
  jdbc_parameters        = "serverTimezone=UTC&useUnicode=yes&characterEncoding=UTF-8&sslMode=VERIFY_IDENTITY&trustCertificateKeyStoreUrl=file:/stroom/db-tls/truststore.p12&trustCertificateKeyStoreType=PKCS12&trustCertificateKeyStorePassword=${local.db_truststore_password}"

  bootstrap_env = {
    ADMIN_SUBJECT            = var.idp.first_admin.subject
    ADMIN_DISPLAY_NAME       = var.idp.first_admin.display_name
    API_BASE                 = "https://${local.http_services[local.frontend_node_set]}.${var.namespace}.svc:${local.ports.https}/api"
    CA_FILE                  = "/etc/stroom-ca/ca.crt"
    PROCESSING_NODES         = join(" ", local.processing_nodes)
    DATA_BUCKET              = var.ingest.bucket
    AWS_REGION               = var.aws_region
    PROXY_API_KEY_SECRET_ARN = var.proxy_api_key_secret_name == null ? "" : aws_secretsmanager_secret.proxy_api_key[0].arn

    # As the operator's API key Job: Stroom's CLI needs the node settings
    STROOM_JDBC_DRIVER_URL                   = "jdbc:mysql://${var.db.host}:${var.db.port}/stroom?${local.jdbc_parameters}"
    STROOM_JDBC_DRIVER_CLASS_NAME            = "com.mysql.cj.jdbc.Driver"
    STROOM_JDBC_DRIVER_USERNAME              = var.db.app_user
    STROOM_STATISTICS_JDBC_DRIVER_URL        = "jdbc:mysql://${var.db.host}:${var.db.port}/stats?${local.jdbc_parameters}"
    STROOM_STATISTICS_JDBC_DRIVER_CLASS_NAME = "com.mysql.cj.jdbc.Driver"
    STROOM_STATISTICS_JDBC_DRIVER_USERNAME   = var.db.app_user
    STROOM_TEMP                              = "/stroom/tmp"
    STROOM_OPERATOR_OPENID_CLIENT_ID         = var.idp.client_id
    STROOM_NODE                              = "${local.node_set_names[local.first_processing_set]}-0"
    POD_HOSTNAME                             = "${local.node_set_names[local.first_processing_set]}-0"
    POD_SUBDOMAIN                            = "${local.headless_services[local.first_processing_set]}.${var.namespace}.svc.cluster.local"
    API_GATEWAY_HOST                         = var.hostname
    JAVA_OPTS                                = "-Xms128m -Xmx1g"
  }
  bootstrap_secret_env = {
    STROOM_JDBC_DRIVER_PASSWORD            = { name = local.db_secret_name, key = var.db.app_user }
    STROOM_STATISTICS_JDBC_DRIVER_PASSWORD = { name = local.db_secret_name, key = var.db.app_user }
    STROOM_OPERATOR_OPENID_CLIENT_SECRET   = { name = local.oidc_secret_name, key = "client-secret" }
    STROOM_KEYSTORE_PASSWORD               = { name = local.keystore_password_name, key = "password" }
  }

  bootstrap_script = file("${path.module}/scripts/bootstrap.sh")
  bootstrap_hash = substr(sha256(jsonencode([
    local.bootstrap_env, local.bootstrap_script, local.stroom_config, local.image,
  ])), 0, 8)
}

resource "kubernetes_service_account_v1" "bootstrap" {
  metadata {
    name      = local.bootstrap_service_account
    namespace = kubernetes_namespace_v1.stroom.metadata[0].name
  }
  automount_service_account_token = false
}

resource "kubernetes_config_map_v1" "bootstrap" {
  metadata {
    name      = "stroom-bootstrap"
    namespace = kubernetes_namespace_v1.stroom.metadata[0].name
  }
  data = {
    "bootstrap.sh" = local.bootstrap_script
  }
}

resource "kubernetes_job_v1" "bootstrap" {
  metadata {
    name      = "stroom-bootstrap-${local.bootstrap_hash}"
    namespace = kubernetes_namespace_v1.stroom.metadata[0].name
  }

  spec {
    backoff_limit           = 3
    active_deadline_seconds = 7200

    template {
      metadata {
        labels = { "app.kubernetes.io/name" = "stroom-bootstrap" }
      }
      spec {
        restart_policy                  = "Never"
        service_account_name            = kubernetes_service_account_v1.bootstrap.metadata[0].name
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
          run_as_user     = 1000
          run_as_group    = 1000
          fs_group        = 1000
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        # The RDS CA as a PKCS12 truststore for the JDBC driver, as the
        # operator's init container makes it for the nodes
        init_container {
          name    = "create-db-truststore"
          image   = local.image
          command = ["sh", "-c", "openssl pkcs12 -export -nokeys -in /opt/db-ca/ca.pem -out /data/truststore.p12 -passout pass:${local.db_truststore_password} -jdktrust anyExtendedKeyUsage && chmod 0444 /data/truststore.p12"]
          volume_mount {
            name       = "db-ca"
            mount_path = "/opt/db-ca"
            read_only  = true
          }
          volume_mount {
            name       = "db-truststore"
            mount_path = "/data"
          }
          security_context {
            allow_privilege_escalation = false
            capabilities {
              drop = ["ALL"]
            }
          }
        }

        container {
          name    = "bootstrap"
          image   = local.image
          command = ["bash", "/opt/bootstrap/bootstrap.sh"]

          dynamic "env" {
            for_each = local.bootstrap_env
            content {
              name  = env.key
              value = env.value
            }
          }
          dynamic "env" {
            for_each = local.bootstrap_secret_env
            content {
              name = env.key
              value_from {
                secret_key_ref {
                  name = env.value.name
                  key  = env.value.key
                }
              }
            }
          }

          volume_mount {
            name       = "bootstrap"
            mount_path = "/opt/bootstrap"
            read_only  = true
          }
          volume_mount {
            name       = "config"
            mount_path = "/stroom/config/config.yml"
            sub_path   = local.config_configmap_key
            read_only  = true
          }
          volume_mount {
            name       = "internal-ca"
            mount_path = "/etc/stroom-ca"
            read_only  = true
          }
          volume_mount {
            name       = "db-truststore"
            mount_path = "/stroom/db-tls"
            read_only  = true
          }
          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }
          volume_mount {
            name       = "stroom-tmp"
            mount_path = "/stroom/tmp"
          }
          volume_mount {
            name       = "stroom-logs"
            mount_path = "/stroom/logs"
          }

          security_context {
            allow_privilege_escalation = false
            capabilities {
              drop = ["ALL"]
            }
          }

          resources {
            requests = { cpu = "500m", memory = "1Gi" }
            limits   = { memory = "1536Mi" }
          }
        }

        volume {
          name = "bootstrap"
          config_map {
            name = kubernetes_config_map_v1.bootstrap.metadata[0].name
          }
        }
        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map_v1.config.metadata[0].name
          }
        }
        volume {
          name = "internal-ca"
          config_map {
            name = var.internal_ca.configmap_name
            items {
              key  = var.internal_ca.configmap_key
              path = "ca.crt"
            }
          }
        }
        volume {
          name = "db-ca"
          config_map {
            name = kubernetes_config_map_v1.db_ca.metadata[0].name
          }
        }
        volume {
          name = "db-truststore"
          empty_dir {}
        }
        volume {
          name = "tmp"
          empty_dir {}
        }
        volume {
          name = "stroom-tmp"
          empty_dir {}
        }
        volume {
          name = "stroom-logs"
          empty_dir {}
        }
      }
    }
  }

  # Waits for the nodes to start (up to an hour, for the first start's
  # migrations), then for the steps
  wait_for_completion = true
  timeouts {
    create = "120m"
    update = "120m"
  }

  depends_on = [
    kubernetes_manifest.stroom_cluster,
    time_sleep.pod_identity_propagation,
    aws_iam_role_policy.bootstrap,
  ]
}
