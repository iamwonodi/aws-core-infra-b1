variable "project_name" {
  type        = string
  description = "Project name used to identify every resource this project blueprint module creates."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,14}[a-z0-9]$", var.project_name))
    error_message = "project_name must be 3-16 lowercase letters, digits or hyphens, starting with a letter. It appears in bucket and resource names, some of which AWS limits to 32 characters."
  }
}


variable "aws_region" {
  type        = string
  description = "AWS region this environment's resources are deployed into. Also used directly by provider.tf, and independently by backend.tf (which cannot reference variables -- keep both in sync manually)."

  validation {
    condition     = trimspace(var.aws_region) != ""
    error_message = "aws_region must not be empty."
  }
}

variable "vpc_cidr" {
  type        = string
  description = "The primary IPv4 CIDR block allocated to the VPC. Must be in valid CIDR block notation."

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "The vpc_cidr value must be a valid IPv4 CIDR address block (e.g., 10.0.0.0/16)."
  }
}


##################################################################################################################################################################################
# Large CIDRs VARIABLE DECLARATION FOR DIFFERENT SUBNET ENVIRONMENTS (Used for stateless traffic filtration rules)
##################################################################################################################################################################################

# 1. PUBLIC TIER CONFIGURATION
# ------------------------------------------------------------------------------
variable "public_subnet_cidrs" {
  type        = list(string)
  description = "Active public subnets across your AZs."
}
variable "public_summary_cidr" {
  type        = string
  description = "The single summary block covering all current and future public subnets"
}

# 2. PRIVATE TIER CONFIGURATION
# ------------------------------------------------------------------------------
variable "private_subnet_cidrs" {
  type        = list(string)
  description = "Active private subnets across your AZs."
}
variable "private_summary_cidr" {
  type        = string
  description = "The single summary block covering all current and future private subnets"
}

# 3. INTERNAL TIER CONFIGURATION
# ------------------------------------------------------------------------------
variable "internal_subnet_cidrs" {
  type        = list(string)
  description = "Active internal subnets for internal backends and services across your AZs."
}
variable "internal_summary_cidr" {
  type        = string
  description = "The single summary block covering all current and future internal subnets"
}


# 4. ISOLATED TIER CONFIGURATION
# ------------------------------------------------------------------------------
variable "isolated_subnet_cidrs" {
  type        = list(string)
  description = "Active isolated subnets for isolated databases across your AZs."
}
variable "isolated_summary_cidr" {
  type        = string
  description = "The single summary block covering all current and future isolated subnets"
}


variable "github_repository" {
  description = "GitHub repository that deploys this environment, in OWNER/REPOSITORY format. Not set in terraform.tfvars: CI passes it from the GitHub context (TF_VAR_github_repository) so a clone of this blueprint needs no edit."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$", var.github_repository))
    error_message = "github_repository must be in OWNER/REPOSITORY format."
  }
}

variable "github_owner_id" {
  description = "Numeric GitHub ID of the repository owner. Passed by CI (TF_VAR_github_owner_id); required when oidc_subject_format is \"immutable\"."
  type        = string
  default     = null
}

variable "github_repository_id" {
  description = "Numeric GitHub ID of the repository. Passed by CI (TF_VAR_github_repository_id); required when oidc_subject_format is \"immutable\"."
  type        = string
  default     = null
}

variable "oidc_subject_format" {
  description = "OIDC subject format GitHub emits for the repositories: \"immutable\" (numeric IDs; repositories created, renamed or transferred on or after 15 July 2026) or \"classic\" (names only)."
  type        = string
  default     = "immutable"
}


# 5. DOMAIN & SUBDOMAIN CONFIGURATION
# ------------------------------------------------------------------------------

variable "domain_name" {
  type        = string
  description = "The fully qualified domain name for this environment."

  validation {
    condition     = can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", var.domain_name))
    error_message = "domain_name must be a valid lowercase domain name. If it is still the CHANGE_ME placeholder, set it to the domain this environment serves (scripts/init-project.sh does this)."
  }
}

variable "private_domain" {
  type        = string
  description = "This domain is used by services within the private subnet to access services in the internal or isolated subnet."

  validation {
    condition     = can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", var.private_domain))
    error_message = "private_domain must be a valid lowercase domain name. If it is still the CHANGE_ME placeholder, set it to the domain this environment serves (scripts/init-project.sh does this)."
  }
}

variable "assets_path" {
  description = "Path to the checked-out assets directory that aws_s3_object resources read from and upload to S3. Supplied via -var by the CI workflow (terraform-plan.yml / terraform-apply.yml) — there is deliberately no default, so a manual local plan/apply without -var fails loudly rather than silently using an unintended path."
  type        = string

  validation {
    condition     = trimspace(var.assets_path) != ""
    error_message = "assets_path must not be empty."
  }
}

variable "assets_force_destroy" {
  type        = bool
  description = "Whether the assets bucket can be destroyed while it still contains objects. This environment deliberately mirrors production's stricter setting rather than development's -- see this environment's README."
  default     = false
}

variable "assets_noncurrent_version_expiration_days" {
  type        = number
  description = "Days after which a noncurrent object version in the assets bucket expires."
  default     = 90

  validation {
    condition     = var.assets_noncurrent_version_expiration_days >= 1
    error_message = "assets_noncurrent_version_expiration_days must be at least 1."
  }
}

################################################################################
# MANAGED DATABASE
################################################################################

variable "database_engines" {
  type        = list(string)
  default     = []
  description = "The database engines this environment runs, each on its own instance: any of \"postgres\", \"mysql\" and \"mongodb\". Empty runs none. Set per environment by scripts/init-project.sh."

  validation {
    condition     = alltrue([for engine in var.database_engines : contains(["postgres", "mysql", "mongodb"], engine)])
    error_message = "database_engines may contain only \"postgres\", \"mysql\" and \"mongodb\"."
  }

  validation {
    condition     = length(distinct(var.database_engines)) == length(var.database_engines)
    error_message = "database_engines lists an engine more than once."
  }

  validation {
    condition     = !contains(var.database_engines, "mongodb")
    error_message = "mongodb runs on Amazon DocumentDB, and its module does not exist yet. Remove it from database_engines until it does."
  }
}

variable "database_instance_class" {
  type        = string
  default     = "db.t4g.medium"
  description = "RDS instance class for each of this environment's database instances."
}

variable "database_multi_az" {
  type        = bool
  default     = true
  description = "Run a standby in a second availability zone. The standby serves no reads: it exists to fail over to, and doubles the instance cost."
}

variable "database_allocated_storage" {
  type        = number
  default     = 50
  description = "Storage in GiB. It grows automatically up to database_max_allocated_storage."
}

variable "database_max_allocated_storage" {
  type        = number
  default     = 500
  description = "Upper bound for storage autoscaling. 0 turns autoscaling off, which means a full disk stops the database."
}

variable "database_backup_retention_days" {
  type        = number
  default     = 30
  description = "Days of automated backups."
}

################################################################################
# GOLDEN IMAGE
################################################################################

variable "ubuntu_parent_image" {
  type        = string
  default     = null
  description = "Ubuntu AMI the golden image is built from. Leave unset to use Canonical's current Ubuntu 24.04 LTS (amd64) image."

  validation {
    condition     = var.ubuntu_parent_image == null || can(regex("^ami-[0-9a-f]{8,17}$", coalesce(var.ubuntu_parent_image, "x")))
    error_message = "ubuntu_parent_image must be an AMI ID (ami-...) or null."
  }
}
