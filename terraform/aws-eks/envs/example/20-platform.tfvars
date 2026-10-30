# Copy envs/example to envs/<env> and adjust.

# Must match envs/<env>/backend-10-infra.hcl.
infra_state = {
  bucket = "my-terraform-state-bucket"
  key    = "stroom-proxy/example/10-infra.tfstate"
  region = "eu-west-2"
}

# --- AWS Load Balancer Controller (TargetGroupBinding only) ---
lb_controller_chart_version = "3.6.2" # update modules/platform/lb-controller-iam-policy.json with it

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
# The operator's charts and image. {} = this repository's charts and the
# gchq/stroom-k8s-operator image of the chart's appVersion.
stroom_operator = {
  # chart_repository = "oci://ghcr.io/gchq/helm-charts"
  # chart_version    = "2.1.0"
  # image_repository = "123456789012.dkr.ecr.eu-west-2.amazonaws.com/stroom-k8s-operator"
  # image_tag        = "stroom-eks-abc1234"
}
