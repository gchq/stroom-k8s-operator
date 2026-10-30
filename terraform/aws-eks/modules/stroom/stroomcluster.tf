################################################################################
# The StroomCluster spec and Stroom's config.yml
################################################################################

locals {
  stroom_config = templatefile("${path.module}/templates/stroom-config.yaml.tftpl", {
    aws_region         = var.aws_region
    queue_url          = var.ingest.queue_url
    dlq_url            = var.ingest.dlq_url
    open_id            = trimspace(yamlencode(local.open_id))
    stream_volume_path = local.stream_volume_path
    index_volume_path  = local.index_volume_path
    extra_app_config   = ""
  })

  # Every Stroom pod runs as the stroom user (uid 1000) from the start, so the
  # namespace can enforce the restricted Pod Security level (operator change
  # 10.2.5). fsGroup makes the volumes writable.
  pod_security_context = {
    runAsNonRoot        = true
    runAsUser           = 1000
    runAsGroup          = 1000
    fsGroup             = 1000
    fsGroupChangePolicy = "OnRootMismatch"
  }
  container_security_context = {
    allowPrivilegeEscalation = false
    capabilities             = { drop = ["ALL"] }
  }

  node_set_specs = [
    for k in sort(keys(var.node_sets)) : {
      name  = k
      count = var.node_sets[k].count
      role  = var.node_sets[k].role

      # gp3 per node: index shards, analytic and Plan B state, logs (design 5.1)
      localDataVolumeClaim = {
        accessModes      = ["ReadWriteOnce"]
        storageClassName = var.storage_class_name
        resources        = { requests = { storage = "${var.node_sets[k].data_volume_gb}Gi" } }
      }
      # Rebuildable and temporary directories on the node's NVMe RAID0
      directories = {
        tmp                  = { emptyDir = { sizeLimit = "${var.node_sets[k].nvme.tmp_gib}Gi" } }
        referenceData        = { emptyDir = { sizeLimit = "${var.node_sets[k].nvme.reference_data_gib}Gi" } }
        referenceStagingData = { emptyDir = {} }
        searchResults        = { emptyDir = { sizeLimit = "${var.node_sets[k].nvme.search_results_gib}Gi" } }
        lmdbLibrary          = { emptyDir = {} }
      }
      # Index volumes on the data volume, at a path the bootstrap Job registers
      extraVolumeMounts = [{ name = "data", subPath = "index", mountPath = local.index_volume_path }]

      resources = {
        requests = { cpu = tostring(var.node_sets[k].cpu), memory = "${var.node_sets[k].memory_gib}Gi" }
        limits   = { cpu = tostring(var.node_sets[k].cpu), memory = "${var.node_sets[k].memory_gib}Gi" }
      }
      # A whole percentage of the limit, rounded up so the heap is at least heap_gib
      memoryOptions = {
        initialPercentage = ceil(var.node_sets[k].heap_gib * 100 / var.node_sets[k].memory_gib)
        maxPercentage     = ceil(var.node_sets[k].heap_gib * 100 / var.node_sets[k].memory_gib)
      }

      ingressEnabled = false
      # Migrations run under a cluster-wide lock on the first start after an
      # upgrade, so allow up to an hour (S14)
      startupProbeTimings = { periodSeconds = 10, failureThreshold = 360 }
      # The CloudWatch add-on mustn't inject its Java agent (proxy design F22)
      podAnnotations = { "instrumentation.opentelemetry.io/inject-java" = "false" }

      podSecurityContext = local.pod_security_context
      securityContext    = local.container_security_context

      nodeSelector = { (local.node_labels[k].key) = local.node_labels[k].value }
      tolerations = [{
        key      = var.stroom_node_taint.key
        operator = "Equal"
        value    = var.stroom_node_taint.value
        effect   = var.stroom_node_taint.effect
      }]
      # One Stroom pod per node, spread over the AZs like the node groups
      affinity = {
        podAntiAffinity = {
          requiredDuringSchedulingIgnoredDuringExecution = [{
            topologyKey   = "kubernetes.io/hostname"
            labelSelector = { matchLabels = { "stroom/cluster" = var.cluster_resource_name } }
          }]
        }
      }
      topologySpreadConstraints = [{
        maxSkew           = 1
        topologyKey       = "topology.kubernetes.io/zone"
        whenUnsatisfiable = "DoNotSchedule"
      }]
      podDisruptionBudget = { maxUnavailable = 1 }
    }
  ]

  stroom_cluster_spec = {
    image = {
      repository = var.stroom_image.repository
      tag        = var.stroom_image.digest == null ? var.stroom_image.tag : "${var.stroom_image.tag}@${var.stroom_image.digest}"
    }
    nodeNamePrefix     = var.node_name_prefix
    preventNodeRemoval = true
    stopped            = var.stopped

    databaseServerRef = {
      userName = var.db.app_user
      serverAddress = {
        host       = var.db.host
        port       = var.db.port
        secretName = local.db_secret_name
        tls = {
          mode           = "VerifyIdentity"
          caCertificates = { configMapName = local.db_ca_configmap_name, key = "ca.pem" }
        }
      }
    }

    identityProviderType = "EXTERNAL_IDP"
    openId = {
      clientId     = var.idp.client_id
      clientSecret = { secretName = local.oidc_secret_name, key = "client-secret" }
    }
    configMapRef = { name = local.config_configmap_name, itemName = local.config_configmap_key }

    https = {
      tlsSecretName             = local.tls_secret_name
      tlsKeystorePasswordSecret = { secretName = local.keystore_password_name, key = "password" }
    }
    # The operator's Ingress isn't used (design 9); the ALB is in front
    ingress = { hostName = var.hostname }

    # Long enough for a node's preStop drain
    nodeTerminationPeriodSecs = 600

    extraJvmOpts = var.extra_jvm_opts
    extraVolumes = [{
      name                  = "stream"
      persistentVolumeClaim = { claimName = local.stream_volume_pvc_name }
    }]
    extraVolumeMounts = [{ name = "stream", mountPath = local.stream_volume_path }]

    nodeSets = local.node_set_specs
  }
}
