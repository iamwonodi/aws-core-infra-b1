################################################################################
# VPC, SUBNETS, AND INTERNET GATEWAY
#
# Creates the four-tier VPC this project's entire architecture is built on:
# public (IGW/NAT only), private (frontend, backend API, DB GUI client),
# internal (stateless internal applications), and isolated (databases,
# never scaled).
################################################################################

module "vpc_base" {
  source = "git::https://github.com/iamwonodi/terraform-aws-vpc-base.git?ref=v1.0.0"

  project_name = var.project_name
  environment  = var.environment

  vpc_cidr              = var.vpc_cidr
  public_subnet_cidrs   = var.public_subnet_cidrs
  private_subnet_cidrs  = var.private_subnet_cidrs
  internal_subnet_cidrs = var.internal_subnet_cidrs
  isolated_subnet_cidrs = var.isolated_subnet_cidrs
}

################################################################################
# NAT GATEWAY
#
# Gives the private, internal, and vpc-endpoint tiers' resources outbound
# internet access (software installs, API calls to AWS services outside
# the VPC endpoints below, and so on) without exposing them directly. The
# isolated tier intentionally has no route through this NAT gateway at all.
################################################################################

module "nat_gateway" {
  source = "git::https://github.com/iamwonodi/terraform-aws-nat-gateway.git?ref=v1.0.0"

  project_name = var.project_name
  environment  = var.environment

  nat_gateway_strategy = "single"
  public_subnet_ids    = module.vpc_base.public_subnet_ids
}

################################################################################
# ROUTE TABLES
#
# Wires each tier's subnets to the right target: the public tier routes to
# the Internet Gateway directly; private/internal/vpc-endpoint route
# outbound traffic through the NAT gateway above; isolated has no default
# route out at all, and only reaches AWS services through the VPC
# endpoints created later in this file.
################################################################################

module "route_tables" {
  source = "git::https://github.com/iamwonodi/terraform-aws-routing.git?ref=v1.0.0"

  project_name = var.project_name
  environment  = var.environment

  vpc_id              = module.vpc_base.vpc_id
  internet_gateway_id = module.vpc_base.internet_gateway_id

  public_subnet_ids   = module.vpc_base.public_subnet_ids
  private_subnet_ids  = module.vpc_base.private_subnet_ids
  internal_subnet_ids = module.vpc_base.internal_subnet_ids
  isolated_subnet_ids = module.vpc_base.isolated_subnet_ids

  nat_gateway_ids      = module.nat_gateway.nat_gateway_ids
  nat_gateway_strategy = module.nat_gateway.nat_gateway_strategy
}

################################################################################
# NETWORK ACCESS CONTROL LISTS
#
# Subnet-level (stateless) perimeter firewalling, on top of the
# security-group (stateful) rules below -- a second layer of defense per
# tier, not a replacement for the security groups.
################################################################################

module "nacl_security" {
  source = "./nacl-security"

  vpc_id       = module.vpc_base.vpc_id
  project_name = var.project_name
  environment  = var.environment

  public_subnet_ids   = module.vpc_base.public_subnet_ids
  private_subnet_ids  = module.vpc_base.private_subnet_ids
  internal_subnet_ids = module.vpc_base.internal_subnet_ids
  isolated_subnet_ids = module.vpc_base.isolated_subnet_ids

  public_cidr_block   = var.public_summary_cidr
  private_cidr_block  = var.private_summary_cidr
  internal_cidr_block = var.internal_summary_cidr
  isolated_cidr_block = var.isolated_summary_cidr
}

################################################################################
# TIER SECURITY GROUPS
#
# One baseline security group per tier, plus one for VPC endpoints. Each
# starts with no ingress rules of its own -- ingress is added by whatever
# domain module actually needs to open a specific port (e.g. the edge
# domain module's ALB ingress rules), keeping "what's allowed in" defined
# next to whatever resource actually needs it, not centralized here.
################################################################################

module "public_sg" {
  source = "git::https://github.com/iamwonodi/terraform-aws-security-group.git?ref=v1.0.0"

  project_name = var.project_name
  environment  = var.environment
  vpc_id       = module.vpc_base.vpc_id
  sg_name      = local.public_sg_name
  description  = local.public_sg_description
}

module "private_sg" {
  source = "git::https://github.com/iamwonodi/terraform-aws-security-group.git?ref=v1.0.0"

  project_name = var.project_name
  environment  = var.environment
  vpc_id       = module.vpc_base.vpc_id
  sg_name      = local.private_sg_name
  description  = local.private_sg_description
}

module "internal_sg" {
  source = "git::https://github.com/iamwonodi/terraform-aws-security-group.git?ref=v1.0.0"

  project_name = var.project_name
  environment  = var.environment
  vpc_id       = module.vpc_base.vpc_id
  sg_name      = local.internal_sg_name
  description  = local.internal_sg_description
}

module "isolated_sg" {
  source = "git::https://github.com/iamwonodi/terraform-aws-security-group.git?ref=v1.0.0"

  project_name = var.project_name
  environment  = var.environment
  vpc_id       = module.vpc_base.vpc_id
  sg_name      = local.isolated_sg_name
  description  = local.isolated_sg_description
}

module "vpc_endpoint_sg" {
  source = "git::https://github.com/iamwonodi/terraform-aws-security-group.git?ref=v1.0.0"

  project_name = var.project_name
  environment  = var.environment
  vpc_id       = module.vpc_base.vpc_id
  sg_name      = local.endpoint_sg_name
  description  = local.endpoint_sg_description
}

################################################################################
# OUTBOUND (EGRESS) RULES
#
# A single unrestricted outbound rule for public, private, internal, and
# the vpc-endpoint security groups -- outbound traffic isn't the primary
# control point in this architecture (inbound rules and subnet routing
# are), so this stays permissive by design. The isolated tier deliberately
# receives no egress rule at all here: it has no NAT route to use one
# with anyway, and reaches AWS services only through the VPC endpoints
# below.
################################################################################

module "global_outbound_routing" {
  source = "git::https://github.com/iamwonodi/terraform-aws-sg-egress-rule.git?ref=v1.0.0"

  for_each = toset([
    module.public_sg.security_group_id,
    module.private_sg.security_group_id,
    module.internal_sg.security_group_id,
    module.vpc_endpoint_sg.security_group_id,
  ])

  security_group_id = each.value
  description       = "Allow outbound connection pathways"

  ip_protocol = "-1"
  cidr_ipv4   = local.all_network
}

################################################################################
# VPC ENDPOINTS FOR THE ISOLATED TIER
#
# Lets isolated-tier resources (the database) reach AWS services --
# S3, ECR, SSM, Secrets Manager, KMS -- privately, entirely within the
# VPC, without ever needing a route through the NAT gateway.
################################################################################

module "endpoint_ingress_rule" {
  source = "git::https://github.com/iamwonodi/terraform-aws-sg-ingress-rule.git?ref=v1.2.0"

  # for_each requires a set of strings, not numbers -- endpoint_ingress_ports
  # is a list of numbers (locals.tf), so each value is converted to a string
  # here and back to a number below for from_port/to_port, which the
  # sg-ingress-rule module expects as numbers.
  for_each = toset([for port in local.endpoint_ingress_ports : tostring(port)])

  security_group_id            = module.vpc_endpoint_sg.security_group_id
  description                  = "Allow isolated workloads to access VPC endpoints on port: ${each.value}"
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.value)
  to_port                      = tonumber(each.value)
  referenced_security_group_id = module.isolated_sg.security_group_id # Open safely to the isolated subnet
}

module "isolated_vpc_endpoints" {
  source = "git::https://github.com/iamwonodi/terraform-aws-vpc-endpoints.git?ref=v1.0.0"

  project_name = var.project_name
  environment  = var.environment

  vpc_id = module.vpc_base.vpc_id

  interface_subnet_ids = module.vpc_base.isolated_subnet_ids

  deploy_interface_endpoints_across_azs = false

  gateway_route_table_ids = module.route_tables.isolated_route_table_id

  interface_security_group_ids = [
    module.vpc_endpoint_sg.security_group_id
  ]

  # S3 is reached via a gateway endpoint (no ENI, no hourly cost) since
  # AWS offers S3 that way; everything else below requires an interface
  # endpoint (an ENI per AZ, with an hourly cost each).
  gateway_endpoints = {
    s3 = {}
  }

  interface_endpoints = {
    "ecr.api"      = {} # Pull container image manifests
    "ecr.dkr"      = {} # Pull container image layers
    ssm            = {} # Systems Manager (Session Manager access, no SSH/bastion needed)
    ssmmessages    = {} # Systems Manager Agent communication channel
    ec2messages    = {} # EC2 instance communication channel used by SSM
    secretsmanager = {} # Fetch secrets (e.g. database credentials) at boot
    kms            = {} # Decrypt secrets and EBS volumes
    logs           = {} # CloudWatch Logs: without it anything running in this tier writes no logs at all
  }
}
