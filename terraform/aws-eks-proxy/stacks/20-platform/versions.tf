terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.71"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.4"
    }
  }
}

provider "aws" {
  region = local.infra.aws_region

  default_tags {
    tags = local.tags
  }
}

# A fresh token from the AWS CLI each time the providers connect, with the
# same credentials as the aws provider (AWS_PROFILE etc.). Not
# aws_eks_cluster_auth: its token is read at plan time, saved in the plan and
# valid for 15 minutes, so applying a saved plan later fails with
# "Unauthorized". The Kubernetes API must be reachable from the machine
# running Terraform (see api_allowed_cidrs in 10-infra).
provider "kubernetes" {
  host                   = local.infra.cluster_endpoint
  cluster_ca_certificate = base64decode(local.infra.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.infra.cluster_name, "--region", local.infra.aws_region]
  }
}

provider "helm" {
  kubernetes = {
    host                   = local.infra.cluster_endpoint
    cluster_ca_certificate = base64decode(local.infra.cluster_certificate_authority_data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", local.infra.cluster_name, "--region", local.infra.aws_region]
    }
  }
}
