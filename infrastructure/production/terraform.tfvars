project_name = "core"

aws_region = "af-south-1"

domain_name    = "CHANGE_ME"
private_domain = "CHANGE_ME"

# Production is the strictest environment -- no force_destroy, and the
# longest retention window, since this environment protects against real
# data loss rather than optimizing for fast iteration.
assets_force_destroy                      = false
assets_noncurrent_version_expiration_days = 90

# Private address space, distinct per environment (development 10.10, staging
# 10.20, production 10.30) so the VPCs can be peered or connected through a
# Transit Gateway later without renumbering. network/validations.tf rejects
# public ranges and overlapping tier CIDRs.
vpc_cidr = "10.30.0.0/16"

public_subnet_cidrs   = ["10.30.1.0/24", "10.30.2.0/24", "10.30.3.0/24"]
private_subnet_cidrs  = ["10.30.17.0/24", "10.30.18.0/24", "10.30.19.0/24"]
internal_subnet_cidrs = ["10.30.33.0/24", "10.30.34.0/24", "10.30.35.0/24"]
isolated_subnet_cidrs = ["10.30.49.0/24", "10.30.50.0/24", "10.30.51.0/24"]

public_summary_cidr   = "10.30.0.0/20"
private_summary_cidr  = "10.30.16.0/20"
internal_summary_cidr = "10.30.32.0/20"
isolated_summary_cidr = "10.30.48.0/20"

# The database engines this environment runs, each on its own instance or
# cluster. Any of "postgres", "mysql" (RDS) and "mongodb" (DocumentDB). Empty
# runs none, and costs nothing.
database_engines = []
