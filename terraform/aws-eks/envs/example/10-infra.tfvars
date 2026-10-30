# Copy envs/example to envs/<env> and adjust.
aws_region = "eu-west-2"
name       = "stroom-proxy-example"

# --- network: a new 3-AZ VPC ---
vpc_cidr = "10.40.0.0/16"
az_count = 3
# After the first apply, pin the zones from the availability_zones output, so
# an impaired zone can't shift the subnets on a later plan. Never reorder or
# remove entries (the node groups are keyed by position); only append.
# azs = ["eu-west-2a", "eu-west-2b", "eu-west-2c"]
nat_gateway_mode     = "one_per_az" # single | one_per_az
enable_vpc_endpoints = false

# Or use an existing VPC:
# existing_vpc_id             = "vpc-0123456789abcdef0"
# existing_private_subnet_ids = ["subnet-aaa", "subnet-bbb", "subnet-ccc"]
# existing_public_subnet_ids  = []
# existing_lb_subnet_ids      = ["subnet-ddd", "subnet-eee", "subnet-fff"] # ALB/NLBs only, /27 or larger

# --- cluster ---
cluster_version      = "1.37"
admin_principal_arns = [] # e.g. ["arn:aws:iam::123456789012:role/PlatformAdmin"]
api_allowed_cidrs    = [] # empty = private API endpoint only; e.g. ["198.51.100.0/24"]
cluster_log_types    = [] # e.g. ["api", "audit", "authenticator"]

# --- system node group (cluster services) ---
# Proxy only: 2 × t3.medium. With stroom_node_sets the system nodes also run
# cert-manager, trust-manager, metrics-server, the EFS CSI controller and the
# Stroom operator, and t3.medium (17 pods) is refused: use e.g.
#   system_node_instance_type = "t3.large" # or "m6i.large"
#   system_node_count         = 2          # 3 for one per AZ
system_node_instance_type = "t3.medium"
system_node_count         = 2

# --- proxy node groups: one per AZ per colour (x86_64 only) ---
# Normally one colour. For a blue/green upgrade add the second colour (new
# version, AMI or instance type), switch the proxy over in 30-stroom-proxy,
# then remove the old colour once its proxies have drained.
proxy_node_colours = {
  blue = {
    instance_types      = ["m6i.xlarge"]
    capacity_type       = "ON_DEMAND"
    nodes_per_az        = 1
    kubernetes_version  = "1.37"
    ami_release_version = null # null = latest at creation, then fixed; or e.g. "1.37.4-20261020"
    root_volume_gb      = 50
  }
  # green = {
  #   instance_types     = ["m7i.xlarge"]
  #   kubernetes_version = "1.37"
  # }
}

# --- Stroom node groups (only with the 40-stroom stack) ---
# One entry per Stroom node set, with the same names and counts as 40-stroom.
# x86_64 types with instance-store NVMe only. Stroom nodes own their index
# shards, so only ever raise node_count (the plan refuses shrinking or moving
# a node group). For a Stroom-only cluster, also set proxy_node_colours = {}.
# Raise the system nodes too (see above).
#
# To change a set's AMI, Kubernetes version or instance types, go one AZ group
# at a time with az_overrides (all AZ groups at once would drain every Stroom
# node of the set together): override az1, apply, wait for its Stroom pod to
# be Ready; then az2; ...; finally set the new value on the set itself and
# remove the overrides (a no-op apply).
stroom_node_sets = {
  # proc = {
  #   instance_types      = ["r6id.8xlarge"]
  #   node_count          = 2 # spread over the AZs: az1, az2
  #   kubernetes_version  = "1.37"
  #   ami_release_version = null
  #   az_overrides = {
  #     # az1 = { ami_release_version = "1.37.5-20261115" }
  #   }
  # }
  # ui = {
  #   instance_types     = ["r6id.4xlarge"]
  #   node_count         = 1
  #   kubernetes_version = "1.37"
  # }
}
