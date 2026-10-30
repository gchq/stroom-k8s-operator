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

resource "helm_release" "internal_ca" {
  count = var.stroom_enabled ? 1 : 0

  name      = "stroom-internal-ca"
  chart     = "${path.module}/charts/stroom-internal-ca"
  namespace = local.cert_manager_namespace

  wait    = true
  timeout = 300

  values = [yamlencode({
    caNamespace    = local.cert_manager_namespace
    name           = var.internal_ca_name
    namespaceLabel = var.internal_ca_namespace_label
  })]

  depends_on = [helm_release.trust_manager]
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
  chart            = var.stroom_operator.chart_repository == null ? "${local.stroom_operator_local_charts}/stroom-operator-crds" : "stroom-operator-crds"
  version          = var.stroom_operator.chart_version
  namespace        = local.stroom_operator_namespace
  create_namespace = true

  wait    = true
  timeout = 300
}

resource "helm_release" "stroom_operator" {
  count = var.stroom_enabled ? 1 : 0

  name       = "stroom-operator"
  repository = var.stroom_operator.chart_repository
  chart      = var.stroom_operator.chart_repository == null ? "${local.stroom_operator_local_charts}/stroom-operator" : "stroom-operator"
  version    = var.stroom_operator.chart_version
  namespace  = local.stroom_operator_namespace

  wait    = true
  timeout = 600

  values = [yamlencode(merge(
    { nodeSelector = local.system_node_selector },
    var.stroom_operator.image_repository == null ? {} : { registry = var.stroom_operator.image_repository },
    var.stroom_operator.image_tag == null ? {} : { image = { tag = var.stroom_operator.image_tag } },
  ))]

  depends_on = [helm_release.stroom_operator_crds]
}
