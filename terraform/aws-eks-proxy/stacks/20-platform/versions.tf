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

# Short-lived token from aws_eks_cluster_auth: no AWS CLI needed on the
# machine running Terraform. It is valid for 15 minutes, longer than an apply
# of this stack takes. The Kubernetes API must be reachable from that machine
# (see api_allowed_cidrs in 10-infra).
data "aws_eks_cluster_auth" "this" {
  name = local.infra.cluster_name
}

provider "kubernetes" {
  host                   = local.infra.cluster_endpoint
  cluster_ca_certificate = base64decode(local.infra.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes = {
    host                   = local.infra.cluster_endpoint
    cluster_ca_certificate = base64decode(local.infra.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}
