# S3 backend with native S3 locking. The bucket, key and region are supplied
# per environment at init time:
#
#   terraform init -backend-config=../../envs/<env>/backend-10-infra.hcl
terraform {
  backend "s3" {
    use_lockfile = true
    encrypt      = true
  }
}
