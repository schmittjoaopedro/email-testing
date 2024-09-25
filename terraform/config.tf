terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

locals {
  route53_zone = var.route53_zone
  root_domain  = var.route53_domain_name
  email_prefix = "email-testing"
  email_domain = "${local.email_prefix}.${local.root_domain}"
  api_domain   = "api-${local.email_prefix}.${local.root_domain}"
}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}