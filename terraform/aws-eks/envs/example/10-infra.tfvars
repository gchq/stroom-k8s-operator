# Copy envs/example to envs/<env> and adjust.
aws_region = "eu-west-2"
name       = "stroom-proxy-example"

# --- network: a new 3-AZ VPC ---
vpc_cidr             = "10.40.0.0/16"
az_count             = 3
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
