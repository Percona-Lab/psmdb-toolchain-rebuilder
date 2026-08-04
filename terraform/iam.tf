# instance profile: bucket, job volume, own ASG

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "rebuilder" {
  name_prefix        = "${var.name}-"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

data "aws_iam_policy_document" "rebuilder" {
  statement {
    sid       = "S3Bucket"
    actions   = ["s3:ListBucket"]
    resources = [data.aws_s3_bucket.out.arn]
  }
  statement {
    sid       = "S3Objects"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${data.aws_s3_bucket.out.arn}/*"]
  }
  # Describe* cannot be resource-scoped
  statement {
    sid       = "EbsDescribe"
    actions   = ["ec2:DescribeVolumes"]
    resources = ["*"]
  }
  statement {
    sid     = "EbsAttach"
    actions = ["ec2:AttachVolume", "ec2:DetachVolume"]
    resources = [
      "arn:aws:ec2:${var.region}:*:volume/${aws_ebs_volume.build.id}",
      "arn:aws:ec2:${var.region}:*:instance/*",
    ]
  }
  # SSM sessions: log access without SSH ingress
  statement {
    sid = "SsmSession"
    actions = [
      "ssmmessages:CreateControlChannel", "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel", "ssmmessages:OpenDataChannel",
      "ssm:UpdateInstanceInformation", "ec2messages:GetMessages",
    ]
    resources = ["*"]
  }
  # self-scale to 0 when DONE
  statement {
    sid       = "AsgDescribe"
    actions   = ["autoscaling:DescribeAutoScalingInstances", "autoscaling:DescribeAutoScalingGroups"]
    resources = ["*"]
  }
  statement {
    sid       = "AsgScale"
    actions   = ["autoscaling:SetDesiredCapacity"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "autoscaling:ResourceTag/Name"
      values   = [var.name]
    }
  }
}

resource "aws_iam_role_policy" "rebuilder" {
  name_prefix = "${var.name}-"
  role        = aws_iam_role.rebuilder.id
  policy      = data.aws_iam_policy_document.rebuilder.json
}

resource "aws_iam_instance_profile" "rebuilder" {
  name_prefix = "${var.name}-"
  role        = aws_iam_role.rebuilder.name
}
