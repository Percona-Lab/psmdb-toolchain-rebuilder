# VPC shape copied from buildbarn aws-fallback-vpc, re-regioned

resource "aws_vpc" "this" {
  cidr_block           = "10.112.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = var.name }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = var.name }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.112.0.0/20"
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.name}-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = var.name }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# egress only; nothing dials in
resource "aws_security_group" "worker" {
  name_prefix = "${var.name}-"
  vpc_id      = aws_vpc.this.id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = var.name }
}

data "aws_ssm_parameter" "ubuntu_arm64" {
  name = "/aws/service/canonical/ubuntu/server/${var.ubuntu_version}/stable/current/arm64/hvm/ebs-gp3/ami-id"
}

# ── artifacts bucket ────────────────────────────────────────────────
# unmanaged: it serves permanent URLs, so it must outlive any destroy.
# Create by hand: aws s3 mb s3://<bucket_name>
data "aws_s3_bucket" "out" {
  bucket = var.bucket_name
}

# account id for the Deny below, so none is hardcoded
data "aws_caller_identity" "current" {}

resource "aws_s3_bucket_public_access_block" "out" {
  bucket = data.aws_s3_bucket.out.id
  # ACLs blocked; only the policy below grants
  block_public_acls  = true
  ignore_public_acls = true
  # false, or the public policy is ignored
  block_public_policy     = false
  restrict_public_buckets = false
}

# bazel fetches unsigned: output/ must be anonymous.
# No ListBucket: keys are fetchable, not enumerable
resource "aws_s3_bucket_policy" "public_output" {
  bucket = data.aws_s3_bucket.out.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadOutput"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${data.aws_s3_bucket.out.arn}/output/*"
      },
      # Outsiders get output/* and nothing else, by explicit Deny:
      # code/ and logs/ then survive a future stray Allow.
      # Anonymous callers have no aws:PrincipalAccount, and a negated
      # condition matches a missing key, so they are covered too.
      {
        Sid         = "DenyEverythingElseToOutsiders"
        Effect      = "Deny"
        Principal   = "*"
        Action      = "s3:*"
        NotResource = ["${data.aws_s3_bucket.out.arn}/output/*"]
        Condition = {
          StringNotEquals = {
            "aws:PrincipalAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
    ]
  })
  depends_on = [aws_s3_bucket_public_access_block.out]
}

# ── state bucket ────────────────────────────────────────────────────
# also unmanaged, and separate from the artifacts: nothing public here,
# and the instance profile has no reach into it at all.
data "aws_s3_bucket" "state" {
  bucket = var.state_bucket_name
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = data.aws_s3_bucket.state.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

# lets a bad state operation be rolled back
resource "aws_s3_bucket_versioning" "state" {
  bucket = data.aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

# ── ephemeral per-job build volume ──────────────────────────────────
# outlives the instance, not the job: PERSIST
resource "aws_ebs_volume" "build" {
  availability_zone = var.availability_zone
  size              = var.build_volume_gb
  type              = "gp3"
  tags = {
    Name        = "${var.name}-build-${var.toolchain_id}"
    PerconaKeep = "True" # keep across the job; TF destroy removes it explicitly
  }
}

# ── launch template ─────────────────────────────────────────────────
resource "aws_launch_template" "rebuilder" {
  name_prefix   = "${var.name}-"
  image_id      = data.aws_ssm_parameter.ubuntu_arm64.value
  instance_type = var.instance_types[0] # ASG mixed-instances overrides this

  iam_instance_profile { arn = aws_iam_instance_profile.rebuilder.arn }
  vpc_security_group_ids = [aws_security_group.worker.id]

  instance_initiated_shutdown_behavior = "terminate"

  metadata_options {
    http_tokens   = "required" # IMDSv2
    http_endpoint = "enabled"
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size           = var.root_volume_gb
      volume_type           = "gp3"
      delete_on_termination = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/user_data.sh.tftpl", {
    region          = var.region
    bucket          = data.aws_s3_bucket.out.id
    volume_id       = aws_ebs_volume.build.id
    upstream_url    = var.upstream_url
    upstream_region = var.upstream_region
    scripts_key     = var.scripts_key
    asg_name        = var.name
  }))

  # default_tags are not merged; untagged gets reaped
  tag_specifications {
    resource_type = "instance"
    tags = {
      Name              = var.name
      PerconaKeep       = "True" # reaper lambdas skip in-flight builds
      "iit-billing-tag" = var.billing_tag
      project           = var.name
    }
  }

  tag_specifications {
    resource_type = "volume" # root volume
    tags = {
      Name              = var.name
      PerconaKeep       = "True"
      "iit-billing-tag" = var.billing_tag
      project           = var.name
    }
  }
}

# ── spot ASG (self-heal): desired=1, single AZ, diversified spot ─────
resource "aws_autoscaling_group" "rebuilder" {
  name             = var.name
  desired_capacity = 1
  # min 0, so the node scales down
  min_size                  = 0
  max_size                  = 1
  vpc_zone_identifier       = [aws_subnet.public.id]
  health_check_type         = "EC2"
  wait_for_capacity_timeout = "0"

  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = 0
      on_demand_percentage_above_base_capacity = 0
      spot_allocation_strategy                 = "capacity-optimized"
    }
    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.rebuilder.id
        version            = "$Latest"
      }
      dynamic "override" {
        for_each = var.instance_types
        content { instance_type = override.value }
      }
    }
  }

  tag {
    key                 = "Name"
    value               = var.name
    propagate_at_launch = true
  }
  tag {
    key                 = "PerconaKeep"
    value               = "True"
    propagate_at_launch = true
  }
  tag {
    key                 = "iit-billing-tag"
    value               = var.billing_tag
    propagate_at_launch = true
  }
  tag {
    key                 = "project"
    value               = var.name
    propagate_at_launch = true
  }

  # instances must die before the volume detaches
  depends_on = [aws_ebs_volume.build]
}
