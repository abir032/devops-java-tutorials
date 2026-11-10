output "alb_url" {
  value = "http://${aws_lb.main.dns_name}"
}

output "cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "log_group" {
  value = aws_cloudwatch_log_group.ecs.name
}

output "backend_target_group_arn" {
  value = aws_lb_target_group.backend.arn
}
