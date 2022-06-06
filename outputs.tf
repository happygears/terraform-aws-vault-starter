output "vault_lb_dns_name" {
  description = "DNS name of Vault load balancer"
  value       = module.loadbalancer.vault_lb_dns_name
}

output "vault_lb_zone_id" {
  description = "Zone ID of Vault load balancer"
  value       = module.loadbalancer.vault_lb_zone_id
}

output "vault_lb_arn" {
  description = "ARN of Vault load balancer"
  value       = module.loadbalancer.vault_lb_arn
}

output "vault_target_group_arn" {
  description = "Target group ARN to register Vault nodes with"
  value       = module.loadbalancer.vault_target_group_arn
}

output "vault_instance_role_arn" {
  value = module.iam.aws_iam_role_arn
}

output "vault_snapashots_bucket_id" {
  value = var.enable_snapshots ? module.snapshots.s3_bucket_id : ""
}

output "lb_listener_port" {
  value = var.lb_listener_port
}
