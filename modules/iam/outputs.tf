output "aws_iam_instance_profile" {
  value = aws_iam_instance_profile.vault.name
}

data "aws_caller_identity" "current" {}

output "aws_iam_role_arn" {
  value = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${aws_iam_instance_profile.vault.role}"
}
