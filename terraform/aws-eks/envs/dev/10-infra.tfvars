# Dev: small and cheap, but the same shape as production (3 AZs, a proxy
# node per AZ), so the tests exercise what production will run.
aws_region = "eu-west-2"
name       = "stroom-proxy-dev"

vpc_cidr = "10.40.0.0/16"
az_count = 3
# Pin the zones the cluster was built in (the availability_zones output), so
# an impaired zone can't shift the subnets on a later plan.
# azs = ["eu-west-2a", "eu-west-2b", "eu-west-2c"]
nat_gateway_mode     = "single" # dev: one NAT gateway is enough
enable_vpc_endpoints = false

cluster_version      = "1.37"
admin_principal_arns = [] # other people who need kubectl access, e.g. ["arn:aws:iam::<account>:role/<role>"]
# The machine running Terraform/kubectl must reach the Kubernetes API.
# "<its public IP>/32", or [] if it runs inside the VPC.
api_allowed_cidrs = ["REPLACE_ME/32"]
cluster_log_types = ["audit"]

# Proxy only. Adding stroom_node_sets needs bigger system nodes, e.g. t3.large.
system_node_instance_type = "t3.medium"
system_node_count         = 2

proxy_node_colours = {
  blue = {
    instance_types     = ["m6i.large"]
    nodes_per_az       = 1
    kubernetes_version = "1.37"
    root_volume_gb     = 30
  }
}
