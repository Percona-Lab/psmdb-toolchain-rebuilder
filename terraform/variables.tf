variable "region" {
  type    = string
  default = "us-west-2"
}

variable "assume_role_arn" {
  description = "Dedicated narrow role TF assumes for all AWS calls (so your broad profile is only used to assume it). Empty = use ambient creds directly. Create it with iam-tf-role-trust.json (trust) + iam-admin-policy.json (permissions)."
  type        = string
  default     = ""
}

variable "availability_zone" {
  description = "Single AZ for the ASG + ephemeral build volume (EBS is AZ-bound)."
  type        = string
  default     = "us-west-2a"
}

variable "name" {
  description = "Stable name for the ASG / launch template / volume / profile."
  type        = string
  default     = "psmdb-toolchain-rebuilder"
}

variable "billing_tag" {
  type    = string
  default = "dev"
}

# ── the job ─────────────────────────────────────────────────────────
variable "toolchain_id" {
  description = "Upstream toolchain id (the <ID> in mongodbtoolchain-debian13-<ID>.tar.gz). Drives output naming and the S3 input/output prefixes."
  type        = string
}

variable "upstream_url" {
  description = "Full URL of the operator-chosen upstream tarball, e.g. s3://boxes.10gen.com/build/toolchain/mongodbtoolchain-debian13-<ID>.tar.gz. Public bucket, so the instance fetches it directly (unsigned). A bare key is read from our own bucket instead."
  type        = string
}

variable "upstream_region" {
  description = "Region of the upstream bucket (boxes.10gen.com lives in eu-west-1)."
  type        = string
  default     = "eu-west-1"
}

variable "scripts_key" {
  description = "S3 key (in this bucket) of the staged scripts bundle (tar.gz of scripts/)."
  type        = string
}

# ── compute ─────────────────────────────────────────────────────────
variable "instance_types" {
  description = "Diversified Graviton, non-metal, 64-96 vCPU. First is primary; ASG spot capacity-optimized falls back through the rest."
  type        = list(string)
  default     = ["c7g.16xlarge", "c8g.16xlarge", "m7g.16xlarge", "c8g.24xlarge", "m8g.24xlarge", "r7g.16xlarge"]
}

variable "root_volume_gb" {
  type    = number
  default = 50
}

variable "build_volume_gb" {
  description = "Ephemeral per-job build volume (state + sources + outputs before upload). ~9GB output per chain + src/state; 300G is comfortable."
  type        = number
  default     = 300
}

variable "ubuntu_version" {
  type    = string
  default = "24.04"
}

# ── output ──────────────────────────────────────────────────────────
variable "bucket_name" {
  type    = string
  default = "psmdb-arm64-toolchains"
}

# separate, so the rebuilder instance cannot reach the state
variable "state_bucket_name" {
  type    = string
  default = "psmdb-arm64-toolchains-state"
}

variable "repo_url" {
  description = "Fallback git URL for the scripts if scripts_key is empty (needs creds; prefer scripts_key from S3)."
  type        = string
  default     = ""
}
