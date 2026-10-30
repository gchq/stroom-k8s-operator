# Copy envs/example to envs/<env> and adjust.

# Must match envs/<env>/backend-10-infra.hcl.
infra_state = {
  bucket = "my-terraform-state-bucket"
  key    = "stroom-proxy/example/10-infra.tfstate"
  region = "eu-west-2"
}

# --- AWS Load Balancer Controller (TargetGroupBinding only) ---
lb_controller_chart_version = "3.6.2" # update modules/platform/lb-controller-iam-policy.json with it
# "full" (upstream policy) or "target_group_binding" (describe and
# register/deregister targets only; verify on your cluster before relying on it)
lb_controller_iam_policy = "full"

# --- default gp3 StorageClass (also used for proxy data volumes) ---
gp3_iops        = 3000
gp3_throughput  = 250 # MiB/s, at most gp3_iops / 4
ebs_kms_key_arn = null

# --- CloudWatch (Container Insights, Fluent Bit container logs) ---
cloudwatch_addon_version = null # null = the cluster's default when first created
log_retention_days       = 90
log_kms_key_arn          = null

# --- External Secrets Operator ---
external_secrets_chart_version = "2.14.0"
secrets_name_prefix            = null # null = "stroom-proxy/<name>/"

# --- Stroom (installed only when 10-infra has stroom_node_sets) ---
cert_manager_chart_version   = "v1.21.3"
trust_manager_chart_version  = "v0.26.0"
metrics_server_chart_version = "3.14.0"
# The operator's charts and image. Without chart_repository the charts come
# from this repository's charts directory, and then image_repository and
# image_tag are required: an operator image built from the same commit. (The
# charts' default image, gchq/stroom-k8s-operator:2.0.0, is older than their
# CRDs and ignores nodeNamePrefix, so Stroom's node names would be wrong for
# good.) Only needed when 10-infra has stroom_node_sets.
stroom_operator = {
  # chart_repository = "oci://ghcr.io/gchq/helm-charts"
  # chart_version    = "2.1.0"
  # image_repository = "123456789012.dkr.ecr.eu-west-2.amazonaws.com/stroom-k8s-operator"
  # image_tag        = "stroom-eks-abc1234"
}
# Extra CA certificates (PEM) in the in-cluster CA's trust bundle: only while
# rotating the root, the old CA certificate.
internal_ca_additional_trusted_certificates = ""
