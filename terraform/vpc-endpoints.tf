# vpc-endpoints.tf

# S3 Gateway Endpoint — free, used regardless of the NAT decision (ADR 0001).
resource "aws_vpc_endpoint" "s3" {
  vpc_endpoint_type = "Gateway"
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_id            = module.vpc.vpc_id

  route_table_ids = module.vpc.private_route_table_ids

  tags = {
    Name = "${var.cluster_name}-vpc-endpoint-s3"
  }
}

# --------------------------------------------------------------------------
# Interface endpoints below are NOT applied. ADR 0001 chose a single NAT
# Gateway over this approach for this project's cost/risk profile.
# Kept as corrected reference in case that decision is revisited.
# NOTE: incomplete as a full alternative — sts, ec2, and
# elasticloadbalancing endpoints would also be needed; see ADR 0001.
# --------------------------------------------------------------------------

# resource "aws_vpc_endpoint" "ecr_api" {
#   vpc_endpoint_type   = "Interface"
#   service_name        = "com.amazonaws.${var.aws_region}.ecr.api"
#   vpc_id              = module.vpc.vpc_id
#   private_dns_enabled = true
#   subnet_ids          = module.vpc.private_subnets
#   security_group_ids  = [aws_security_group.vpc_endpoints_sg.id]
#
#   tags = {
#     Name = "${var.cluster_name}-vpc-endpoint-ecr-api"
#   }
# }
#
# resource "aws_vpc_endpoint" "ecr_dkr" {
#   vpc_endpoint_type   = "Interface"
#   service_name        = "com.amazonaws.${var.aws_region}.ecr.dkr"
#   vpc_id              = module.vpc.vpc_id
#   private_dns_enabled = true
#   subnet_ids          = module.vpc.private_subnets
#   security_group_ids  = [aws_security_group.vpc_endpoints_sg.id]
#
#   tags = {
#     Name = "${var.cluster_name}-vpc-endpoint-ecr-dkr"
#   }
# }
#
# resource "aws_vpc_endpoint" "logs" {
#   vpc_endpoint_type   = "Interface"
#   service_name        = "com.amazonaws.${var.aws_region}.logs"
#   vpc_id              = module.vpc.vpc_id
#   private_dns_enabled = true
#   subnet_ids          = module.vpc.private_subnets
#   security_group_ids  = [aws_security_group.vpc_endpoints_sg.id]
#
#   tags = {
#     Name = "${var.cluster_name}-vpc-endpoint-logs"
#   }
# }
#
# resource "aws_security_group" "vpc_endpoints_sg" {
#   name        = "${var.cluster_name}-vpc-endpoints-sg"
#   description = "Allow HTTPS from EKS nodes to VPC interface endpoints"
#   vpc_id      = module.vpc.vpc_id
#
#   ingress {
#     from_port       = 443
#     to_port         = 443
#     protocol        = "tcp"
#     security_groups = [aws_security_group.eks_node_sg.id]  # created in eks.tf, Step 3
#   }
#
#   egress {
#     from_port   = 0
#     to_port     = 0
#     protocol    = "-1"
#     cidr_blocks = ["0.0.0.0/0", "::/0"]
#   }
# }