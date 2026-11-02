resource "aws_instance" "web" {
  ami                         = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.frontend.id
  vpc_security_group_ids      = [aws_security_group.web.id]
  key_name                    = aws_key_pair.main.key_name
  user_data                   = file("${path.module}/server_user_data.sh")
  user_data_replace_on_change = true

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }
  metadata_options { http_tokens = "required" }
  lifecycle { ignore_changes = [ami] }
  tags = { Name = "${var.project}-web" }
}

resource "aws_instance" "backend" {
  count = 2

  ami                         = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type               = "t3.small" # Maven build + JVM do not fit well in 1 GB
  subnet_id                   = aws_subnet.backend.id
  private_ip                  = cidrhost(aws_subnet.backend.cidr_block, 11 + count.index) # .11, .12
  vpc_security_group_ids      = [aws_security_group.backend.id]
  key_name                    = aws_key_pair.main.key_name
  iam_instance_profile        = aws_iam_instance_profile.backend.name
  user_data                   = file("${path.module}/server_user_data.sh")
  user_data_replace_on_change = true

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }
  metadata_options { http_tokens = "required" }
  lifecycle { ignore_changes = [ami] }

  depends_on = [aws_route.backend_default] # the boot script needs the internet at once

  tags = { Name = "${var.project}-backend-${count.index + 1}" }
}