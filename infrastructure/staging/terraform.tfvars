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

# The database engines this environment runs, each on its own instance or
# cluster. Any of "postgres", "mysql" (RDS) and "mongodb" (DocumentDB). Empty
# runs none, and costs nothing.
database_engines = []

# When those instances run: "always_on" (continuously, as in production) or
# "working_hours" (only within the window below, to save the instance cost; while
# stopped, services cannot reach their databases).
database_schedule = "always_on"

# Used only with "working_hours". Days they start, start and stop (HH:MM, 24-hour,
# in the time zone). They are stopped at the stop time EVERY day.
database_working_hours = {
  days     = ["SAT", "SUN"]
  start    = "08:00"
  stop     = "19:00"
  timezone = "Africa/Lagos"
}

# The internal tier (its load balancer): off until an internal-tier
# service needs it, to save its cost.
internal_tier_enabled = false

# How private and internal hosts reach the internet: "gateway" (managed NAT
# Gateway) or "instance" (a small NAT instance, far cheaper, but outbound traffic
# stops for the minutes it is recovered or replaced).
nat_type = "instance"
