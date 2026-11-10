resource "aws_vpc_peering_connection" "app_db" {
  vpc_id      = aws_vpc.app.id
  peer_vpc_id = aws_vpc.db.id
  auto_accept = true
  tags        = { Name = "${var.project}-app-to-db" }
}

# makes the RDS/ElastiCache/MQ DNS names resolve to private IPs from the app VPC
resource "aws_vpc_peering_connection_options" "dns" {
  vpc_peering_connection_id = aws_vpc_peering_connection.app_db.id
  requester { allow_remote_vpc_dns_resolution = true }
  accepter { allow_remote_vpc_dns_resolution = true }
}

resource "aws_route" "backend_to_db" {
  route_table_id            = aws_route_table.backend.id
  destination_cidr_block    = var.db_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.app_db.id
}

resource "aws_route" "db_to_backend" {
  route_table_id            = aws_route_table.db.id
  destination_cidr_block    = var.app_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.app_db.id
}