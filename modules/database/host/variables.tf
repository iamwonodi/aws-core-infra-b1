################################################################################
# CORE IDENTIFICATION
################################################################################

variable "project_name" {
  type        = string
  description = "Project name used to identify every resource this module creates."

  validation {
    condition     = trimspace(var.project_name) != ""
    error_message = "project_name must not be empty."
  }
}

variable "environment" {
  type        = string
  description = "Deployment environment used to identify every resource this module creates."

  validation {
    condition     = trimspace(var.environment) != ""
    error_message = "environment must not be empty."
  }
}

################################################################################
# NETWORK PLACEMENT
#
# Supplied by the network domain module's outputs -- this module owns no
# networking resources of its own.
################################################################################

variable "isolated_subnet_ids" {
  type        = list(string)
  description = "Isolated-tier subnet IDs. The database host is launched into the first entry -- databases in this project are intentionally not scaled across multiple subnets/instances."

  validation {
    condition     = length(var.isolated_subnet_ids) > 0
    error_message = "isolated_subnet_ids must contain at least one subnet ID."
  }
}

variable "isolated_security_group_id" {
  type        = string
  description = "Security group ID for the isolated tier. Attached to the database host."

  validation {
    condition     = trimspace(var.isolated_security_group_id) != ""
    error_message = "isolated_security_group_id must not be empty."
  }
}

################################################################################
# CROSS-DOMAIN INPUTS
################################################################################

variable "ami_id" {
  type        = string
  description = "AMI ID the database host runs. Supplied by the compute domain module's output, so the database runs the same base image as both fleets."

  validation {
    condition     = trimspace(var.ami_id) != ""
    error_message = "ami_id must not be empty."
  }
}

variable "private_zone_id" {
  type        = string
  description = "Private Route 53 hosted zone ID, supplied by the edge domain module's output. Used for the database's IAM Route 53 write permission scope and, when enabled, its own private DNS registration."

  validation {
    condition     = trimspace(var.private_zone_id) != ""
    error_message = "private_zone_id must not be empty."
  }
}

variable "private_domain" {
  type        = string
  description = "Internal domain name the database's own private DNS record is registered under, as db.<private_domain>."

  validation {
    condition     = trimspace(var.private_domain) != ""
    error_message = "private_domain must not be empty."
  }
}

################################################################################
# DATABASE COMPUTE
################################################################################

variable "db_instance_type" {
  type        = string
  description = "EC2 instance type used for the database host."
  default     = "t3.medium"

  validation {
    condition     = trimspace(var.db_instance_type) != ""
    error_message = "db_instance_type must not be empty."
  }
}

variable "db_root_volume_size" {
  type        = number
  description = "Size of the database host's encrypted root EBS volume, in GiB."
  default     = 15

  validation {
    condition     = var.db_root_volume_size >= 15
    error_message = "db_root_volume_size must be at least 15 GiB."
  }
}

variable "db_associate_public_ip_address" {
  type        = bool
  description = "Whether to associate a public IPv4 address with the database host. The isolated tier has no route to an Internet Gateway, so this should stay false outside of exceptional debugging scenarios."
  default     = false
}

################################################################################
# DATABASE IAM
################################################################################

variable "db_enable_route53_write_access" {
  type        = bool
  description = "Whether the database host receives IAM permission to modify the private Route 53 hosted zone directly. No longer needed for private DNS registration itself -- that is now a Terraform-managed aws_route53_record (see db_enable_private_dns_registration), not a runtime action the instance performs. Left available for any other Route 53 write need the instance might have; defaults false and should generally stay false."
  default     = false
}

variable "db_enable_ecr_read_access" {
  type        = bool
  description = "Whether the database host receives IAM permission to pull images from Amazon ECR."
  default     = false
}

################################################################################
# DATABASE PRIVATE DNS / SERVICE DISCOVERY
################################################################################

variable "db_enable_private_dns_registration" {
  type        = bool
  description = "Whether a Terraform-managed A record is created for the database host in the private Route 53 hosted zone, as db.<private_domain>. Resolves to module.database_host.private_ip directly -- no runtime registration by the instance itself."
  default     = false
}

################################################################################
# DATABASE SECONDARY DATA VOLUME
################################################################################

variable "db_enable_data_volume_mount" {
  type        = bool
  description = "Whether the database host should mount a secondary persistent EBS volume."
  default     = false
}

variable "db_data_volume_device" {
  type        = string
  description = "Linux device name of the secondary EBS volume attached to the database host."
  default     = "/dev/sdb"

  validation {
    condition     = trimspace(var.db_data_volume_device) != ""
    error_message = "db_data_volume_device must not be empty."
  }
}

variable "db_data_volume_size" {
  type        = number
  description = "Size of the database host's secondary EBS volume, in GiB."
  default     = 30

  validation {
    condition     = var.db_data_volume_size >= 1
    error_message = "db_data_volume_size must be at least 1 GiB."
  }
}

variable "db_data_volume_mount_path" {
  type        = string
  description = "Filesystem path where the secondary EBS volume is mounted. An empty value uses the database workspace path instead."
  default     = ""
}

################################################################################
# DATABASE BACKUPS
################################################################################

variable "db_enable_automated_backups" {
  type        = bool
  description = "Whether a DLM lifecycle policy takes automated daily snapshots of the database's persistent data volume. Only meaningful when db_enable_data_volume_mount is also true -- there is nothing to snapshot otherwise."
  default     = true
}

variable "db_backup_retention_days" {
  type        = number
  description = "How many daily snapshots to retain before the oldest is automatically deleted. Development defaults to a short window (data here is reproducible and lower-value than production data); revisit this alongside a genuinely different strategy if this pattern is ever extended to staging or production -- see the data module's README."
  default     = 7

  validation {
    condition     = var.db_backup_retention_days >= 1
    error_message = "db_backup_retention_days must be at least 1."
  }
}

# -----------------------------------------------------------------------------
# Deploy bucket (owned by the compute module)
# -----------------------------------------------------------------------------

variable "deploy_bucket_name" {
  type        = string
  description = "Name of the fleet deploy bucket, created by the compute module. Holds this host's scripts under _platform/ and the platforms team's engine definitions under database/."

  validation {
    condition     = trimspace(var.deploy_bucket_name) != ""
    error_message = "deploy_bucket_name must not be empty."
  }
}

variable "deploy_bucket_arn" {
  type        = string
  description = "ARN of the fleet deploy bucket."

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:s3:::[^/]+$", var.deploy_bucket_arn))
    error_message = "deploy_bucket_arn must be an S3 bucket ARN (arn:aws:s3:::bucket-name)."
  }
}

variable "db_require_ecr_images" {
  type        = bool
  default     = true
  description = "Whether engines may only use images from this account's ECR registry. Leave true while the database host sits in the isolated tier, which has no internet path to pull public images; the deploy fails fast with a clear message instead of timing out on a pull."
}
