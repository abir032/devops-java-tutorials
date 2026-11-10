resource "aws_instance" "nat" {
  ami                    = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.frontend.id
  vpc_security_group_ids = [aws_security_group.nat.id]
  source_dest_check      = false

  user_data = templatefile("${path.module}/nat_user_data.sh.tftpl", {
    backend_cidr = var.app_vpc_cidr
  })
  user_data_replace_on_change = true

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
  }
  metadata_options { http_tokens = "required" }
  lifecycle { ignore_changes = [ami] }
  tags = { Name = "${var.project}-nat" }
}

resource "aws_route" "backend_default" {
  route_table_id         = aws_route_table.backend.id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.nat.primary_network_interface_id
}