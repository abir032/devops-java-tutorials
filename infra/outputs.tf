output "web_public_ip" { value = aws_instance.web.public_ip }
output "backend_private_ips" { value = aws_instance.backend[*].private_ip }
output "db_master_password" {
  value     = random_password.db_master.result
  sensitive = true
}

output "ssh_config" {
  value = <<EOT
Host orderdesk-web
  HostName ${aws_instance.web.public_ip}
  User ubuntu
  IdentityFile ~/.ssh/orderdesk-key
%{for i, b in aws_instance.backend~}
Host orderdesk-backend-${i + 1}
  HostName ${b.private_ip}
  User ubuntu
  IdentityFile ~/.ssh/orderdesk-key
  ProxyJump orderdesk-web
%{endfor~}
EOT
}