terraform {
  required_version = ">= 1.10" # backend s3 use_lockfile
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region

  # your profile assumes it; empty = ambient
  dynamic "assume_role" {
    for_each = var.assume_role_arn == "" ? [] : [1]
    content {
      role_arn     = var.assume_role_arn
      session_name = "psmdb-toolchain-rebuilder"
    }
  }

  default_tags {
    tags = {
      iit-billing-tag = var.billing_tag
      project         = "psmdb-toolchain-rebuilder"
    }
  }
}
