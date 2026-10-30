################################################################################
# For Stroom (40-stroom), only when the cluster has Stroom node sets
#
# cert-manager and trust-manager with an in-cluster CA (TLS between Stroom's
# nodes, and from the proxy to Stroom), metrics-server (for the Stroom
# operator's task autoscaler), and the Stroom operator with its CRDs. A
# proxy-only cluster gets none of these.
################################################################################

locals {
  cert_manager_namespace    = "cert-manager"
  stroom_operator_namespace = "stroom-operator"

  # Unless a chart repository is given, the operator charts come from this
  # repository's charts directory, which has changes not yet released.
  stroom_operator_local_charts = "${path.module}/../../../../charts"
  stroom_operator_from_local   = var.stroom_operator.chart_repository == null

  # A local chart keeps its version when its files change, so Helm wouldn't
  # upgrade the release. A checksum of the chart's files in the values (unused
  # by the chart) makes any change to them an upgrade, and nothing else does.
  internal_ca_chart = "${path.module}/charts/stroom-internal-ca"
  local_chart_checksums = {
    for name, dir in {
      internal_ca          = local.internal_ca_chart
      stroom_operator      = "${local.stroom_operator_local_charts}/stroom-operator"
      stroom_operator_crds = "${local.stroom_operator_local_charts}/stroom-operator-crds"
    } : name => sha256(join("\n", [for f in sort(fileset(dir, "**")) : "${f} ${filesha256("${dir}/${f}")}"]))
  }
}

resource "helm_release" "cert_manager" {
  count = var.stroom_enabled ? 1 : 0

  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.cert_manager_chart_version
  namespace        = local.cert_manager_namespace
  create_namespace = true

  wait    = true
  timeout = 600

  values = [yamlencode({
    crds = { enabled = true, keep = true }
    # Don't add Certificate and Issuer rights to the default edit and admin
    # roles: a namespace user could otherwise get certificates from the
    # cluster-wide internal CA. Only cluster admins create them.
    global = { rbac = { aggregateClusterRoles = false } }
    # Two replicas and a PDB, so a system node drain doesn't stop certificate
    # issuance or the webhook
    replicaCount        = 2
    podDisruptionBudget = { enabled = true, maxUnavailable = 1 }
    nodeSelector        = local.system_node_selector
    webhook = {
      replicaCount        = 2
      podDisruptionBudget = { enabled = true, maxUnavailable = 1 }
      nodeSelector        = local.system_node_selector
    }
    cainjector      = { nodeSelector = local.system_node_selector }
    startupapicheck = { nodeSelector = local.system_node_selector }
  })]
}

resource "helm_release" "trust_manager" {
  count = var.stroom_enabled ? 1 : 0

  name       = "trust-manager"
  repository = "https://charts.jetstack.io"
  chart      = "trust-manager"
  version    = var.trust_manager_chart_version
  namespace  = local.cert_manager_namespace

  wait    = true
  timeout = 600

  values = [yamlencode({
    crds         = { enabled = true }
    nodeSelector = local.system_node_selector
    # The CA's Secret is in cert-manager's namespace, which is trust-manager's
    # trust namespace by default. It only reads Secrets as sources there.
    app            = { trust = { namespace = local.cert_manager_namespace } }
    secretTargets  = { enabled = false }
    defaultPackage = { enabled = false }
  })]

  depends_on = [helm_release.cert_manager]
}

# trust-manager's pods are ready before cert-manager's cainjector has put the
# CA bundle into trust-manager's webhook configuration, so creating the Bundle
# straight away can fail with an x509 error. Wait briefly the first time.
resource "time_sleep" "trust_manager_webhook" {
  count = var.stroom_enabled ? 1 : 0

  create_duration = "30s"

  depends_on = [helm_release.trust_manager]
}

resource "helm_release" "internal_ca" {
  count = var.stroom_enabled ? 1 : 0

  name      = "stroom-internal-ca"
  chart     = local.internal_ca_chart
  namespace = local.cert_manager_namespace

  wait    = true
  timeout = 300

  values = [yamlencode({
    caNamespace                   = local.cert_manager_namespace
    name                          = var.internal_ca_name
    namespaceLabel                = var.internal_ca_namespace_label
    additionalTrustedCertificates = var.internal_ca_additional_trusted_certificates
    chartChecksum                 = local.local_chart_checksums["internal_ca"]
  })]

  depends_on = [time_sleep.trust_manager_webhook]
}

resource "helm_release" "metrics_server" {
  count = var.stroom_enabled ? 1 : 0

  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = var.metrics_server_chart_version
  namespace  = "kube-system"

  wait    = true
  timeout = 600

  values = [yamlencode({
    replicas            = 2
    podDisruptionBudget = { enabled = true, maxUnavailable = 1 }
    nodeSelector        = local.system_node_selector
  })]
}

# The CRDs are a chart of their own, so they're upgraded with it (Helm never
# upgrades a chart's crds/ directory) and removing the operator doesn't
# delete every StroomCluster.
resource "helm_release" "stroom_operator_crds" {
  count = var.stroom_enabled ? 1 : 0

  name             = "stroom-operator-crds"
  repository       = var.stroom_operator.chart_repository
  chart            = local.stroom_operator_from_local ? "${local.stroom_operator_local_charts}/stroom-operator-crds" : "stroom-operator-crds"
  version          = var.stroom_operator.chart_version
  namespace        = local.stroom_operator_namespace
  create_namespace = true

  wait    = true
  timeout = 300

  values = local.stroom_operator_from_local ? [yamlencode({ chartChecksum = local.local_chart_checksums["stroom_operator_crds"] })] : []
}

resource "helm_release" "stroom_operator" {
  count = var.stroom_enabled ? 1 : 0

  name       = "stroom-operator"
  repository = var.stroom_operator.chart_repository
  chart      = local.stroom_operator_from_local ? "${local.stroom_operator_local_charts}/stroom-operator" : "stroom-operator"
  version    = var.stroom_operator.chart_version
  namespace  = local.stroom_operator_namespace

  wait    = true
  timeout = 600

  values = [yamlencode(merge(
    { nodeSelector = local.system_node_selector },
    local.stroom_operator_from_local ? { chartChecksum = local.local_chart_checksums["stroom_operator"] } : {},
    var.stroom_operator.image_repository == null ? {} : { registry = var.stroom_operator.image_repository },
    var.stroom_operator.image_tag == null ? {} : { image = { tag = var.stroom_operator.image_tag } },
  ))]

  depends_on = [helm_release.stroom_operator_crds]
}
