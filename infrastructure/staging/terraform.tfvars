project_name = "core"

aws_region = "af-south-1"

domain_name    = "CHANGE_ME"
private_domain = "CHANGE_ME"

# Staging deliberately mirrors production's stricter settings rather than
# development's -- staging exists to rehearse what production will
# actually do, so it shouldn't silently allow data loss production is
# protected against.
assets_force_destroy                      = false
assets_noncurrent_version_expiration_days = 90

# Private address space, distinct per environment (development 10.10, staging
# 10.20, production 10.30) so the VPCs can be peered or connected through a
# Transit Gateway later without renumbering. network/validations.tf rejects
# public ranges and overlapping tier CIDRs.
vpc_cidr = "10.20.0.0/16"

public_subnet_cidrs   = ["10.20.1.0/24", "10.20.2.0/24", "10.20.3.0/24"]
private_subnet_cidrs  = ["10.20.17.0/24", "10.20.18.0/24", "10.20.19.0/24"]
internal_subnet_cidrs = ["10.20.33.0/24", "10.20.34.0/24", "10.20.35.0/24"]
isolated_subnet_cidrs = ["10.20.49.0/24", "10.20.50.0/24", "10.20.51.0/24"]

public_summary_cidr   = "10.20.0.0/20"
private_summary_cidr  = "10.20.16.0/20"
internal_summary_cidr = "10.20.32.0/20"
isolated_summary_cidr = "10.20.48.0/20"
