infra_state = {
  bucket = "REPLACE_ME-terraform-state"
  key    = "stroom-proxy/dev/10-infra.tfstate"
  region = "eu-west-2"
}

gp3_iops           = 3000
gp3_throughput     = 125
log_retention_days = 14
