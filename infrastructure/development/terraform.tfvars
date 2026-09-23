project_name = "core"

aws_region = "af-south-1"

domain_name    = "CHANGE_ME"
private_domain = "CHANGE_ME"

# Development churns fastest and has the least need for historical
# retention -- matches this environment's original hardcoded values before
# the edge domain module made them caller-configurable.
assets_force_destroy                      = true
assets_noncurrent_version_expiration_days = 14

# Private address space, distinct per environment (development 10.10, staging
# 10.20, production 10.30) so the VPCs can be peered or connected through a
# Transit Gateway later without renumbering. network/validations.tf rejects
# public ranges and overlapping tier CIDRs.
vpc_cidr = "10.10.0.0/16"

public_subnet_cidrs   = ["10.10.1.0/24", "10.10.2.0/24", "10.10.3.0/24"]
private_subnet_cidrs  = ["10.10.17.0/24", "10.10.18.0/24", "10.10.19.0/24"]
internal_subnet_cidrs = ["10.10.33.0/24", "10.10.34.0/24", "10.10.35.0/24"]
isolated_subnet_cidrs = ["10.10.49.0/24", "10.10.50.0/24", "10.10.51.0/24"]

public_summary_cidr   = "10.10.0.0/20"
private_summary_cidr  = "10.10.16.0/20"
internal_summary_cidr = "10.10.32.0/20"
isolated_summary_cidr = "10.10.48.0/20"


################################################################################
# UBUNTU AMI configuration values
################################################################################

# ubuntu_parent_image is unset: the golden AMI is built from Canonical's current
# Ubuntu 24.04 LTS image. Set it to an AMI ID (ami-...) only to pin a specific one.

# Predefined package set:
# git, jq, unzip, tar, gzip, curl, wget, nano, ca-certificates,
# gnupg, and lsb-release.
enable_predefined_packages = true
enable_docker              = true # Installs Docker Engine, Docker CLI, containerd, Buildx, and Compose.
enable_aws_cli             = true # Installs AWS CLI v2.
enable_python              = true # Installs Python and the standard Python tooling configured by the module.


custom_build_commands = [] # Additional commands supplied by the caller.
custom_validate_commands = [
  "test -d /opt",
  "python3 --version",
] # Additional validation commands supplied by the caller.


component_version          = "1.0.0"
recipe_version             = "1.0.0"
root_volume_size           = 24
root_volume_type           = "gp3"
instance_types             = ["t3.medium"]
build_image                = true
ami_build_trigger          = ""
ami_description            = "Reusable Ubuntu compute AMI."
enable_pipeline            = false
pipeline_schedule          = "cron(0 3 ? * SUN *)" # Every Sunday at 03:00 UTC when the pipeline is enabled.
enable_image_tests         = true
image_test_timeout_minutes = 60


################################################################################
# DATABASE COMPUTE & STORAGE configuration values
################################################################################

db_instance_type                   = "t3.medium"
db_associate_public_ip_address     = false
db_root_volume_size                = 24
db_enable_route53_write_access     = true
db_enable_ecr_read_access          = true
db_enable_private_dns_registration = true
db_enable_data_volume_mount        = true
db_data_volume_device              = "/dev/sdb"
db_data_volume_size                = 50
db_data_volume_mount_path          = ""

# The internal tier (its load balancer and shared fleet): off until an internal-tier
# service needs it, to save its cost.
internal_tier_enabled = false
