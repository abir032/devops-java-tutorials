output "agent_private_ip" {
  value = aws_instance.agent.private_ip
}

output "ecr_backend_url" {
  value = aws_ecr_repository.app["backend"].repository_url
}

output "ecr_frontend_url" {
  value = aws_ecr_repository.app["frontend"].repository_url
}

output "ssh_via_jenkins" {
  value = "ssh -J ubuntu@<JENKINS-PUBLIC-IP> ubuntu@${aws_instance.agent.private_ip}"
}
