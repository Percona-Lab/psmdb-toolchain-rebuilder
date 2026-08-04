terraform {
  # VPC/IAM outlive a job; workspaces do not.
  # The assumed role comes from backend.hcl, which is not
  # committed: blocks take no variables and the ARN has
  # an account id in it. See backend.hcl.example.
  #   terraform init -backend-config=backend.hcl
  backend "s3" {
    bucket       = "psmdb-arm64-toolchains-state"
    key          = "state/terraform.tfstate"
    region       = "us-west-2"
    encrypt      = true
    use_lockfile = true # S3-native lock, needs tf >= 1.10
  }
}
