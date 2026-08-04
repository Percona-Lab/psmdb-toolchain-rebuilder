output "bucket" {
  value = data.aws_s3_bucket.out.id
}

output "asg_name" {
  value = aws_autoscaling_group.rebuilder.name
}

output "build_volume_id" {
  value = aws_ebs_volume.build.id
}

output "output_prefix" {
  description = "Where the arm64 artifacts + DONE marker land."
  value       = "s3://${data.aws_s3_bucket.out.id}/output/${var.toolchain_id}/"
}

output "done_marker" {
  description = "Jenkins polls this key to know the rebuild finished."
  value       = "output/${var.toolchain_id}/DONE"
}
