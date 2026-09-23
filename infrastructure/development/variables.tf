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
  description = "Active public subnets across your AZs (Leaves room up to .15.255)"
}
variable "public_summary_cidr" {
  type        = string
  description = "The single summary block covering all current and future public subnets"
}

# 2. PRIVATE TIER CONFIGURATION
# ------------------------------------------------------------------------------
variable "private_subnet_cidrs" {
  type        = list(string)
  description = "Active private subnets across your AZs (Leaves room up to .31.255)"
}
variable "private_summary_cidr" {
  type        = string
  description = "The single summary block covering all current and future private subnets"
}

# 3. INTERNAL TIER CONFIGURATION
# ------------------------------------------------------------------------------
variable "internal_subnet_cidrs" {
  type        = list(string)
  description = "Active internal subnets for internal backends and services across your AZs (Leaves room up to .47.255)"
}
variable "internal_summary_cidr" {
  type        = string
  description = "The single summary block covering all current and future internal subnets"
}


# 3. ISOLATED TIER CONFIGURATION
# ------------------------------------------------------------------------------
variable "isolated_subnet_cidrs" {
  type        = list(string)
  description = "Active isolated subnets for isolated databases across your AZs (Leaves room up to .47.255)"
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

variable "database_engines_repository" {
  description = "The platforms team's repository (OWNER/REPOSITORY), which publishes the database engines and opens their ports. Leave null until it exists: nothing is granted."
  type        = string
  default     = null

  validation {
    condition     = var.database_engines_repository == null || can(regex("^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$", coalesce(var.database_engines_repository, "x")))
    error_message = "database_engines_repository must be in OWNER/REPOSITORY format, or null."
  }
}

variable "database_engines_repository_owner_id" {
  description = "Numeric GitHub ID of that repository's owner. Required when oidc_subject_format is \"immutable\"."
  type        = string
  default     = null
}

variable "database_engines_repository_id" {
  description = "Numeric GitHub ID of that repository. Required when oidc_subject_format is \"immutable\"."
  type        = string
  default     = null
}


# 3. DOMAIN & SUBDOMAIN CONFIGURATION
# ------------------------------------------------------------------------------

variable "domain_name" {
  type        = string
  description = "The fully qualified domain name for the project development environment."

  validation {
    condition     = can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", var.domain_name))
    error_message = "domain_name must be a valid lowercase domain name. If it is still the CHANGE_ME placeholder, set it to the domain this environment serves (scripts/init-project.sh does this)."
  }
}

variable "private_domain" {
  type        = string
  description = "This domain is used by services within the private subnet to access services in the internal or isolated development subnet."

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
  description = "Whether the assets bucket can be destroyed while it still contains objects. Development churns fastest and has the least need for historical retention, so this environment sets it true; staging deliberately mirrors production's stricter (false) setting, since staging exists to rehearse what production will actually do."
  default     = false
}

variable "assets_noncurrent_version_expiration_days" {
  type        = number
  description = "Days after which a noncurrent object version in the assets bucket expires. Development uses a shorter window than staging/production for the same reason as assets_force_destroy above."
  default     = 90

  validation {
    condition     = var.assets_noncurrent_version_expiration_days >= 1
    error_message = "assets_noncurrent_version_expiration_days must be at least 1."
  }
}


################################################################################
# UBUNTU AMI CONFIGURATION
################################################################################


# UBUNTU BASE IMAGE


variable "ubuntu_parent_image" {
  type        = string
  default     = null
  description = "Ubuntu AMI ID used as the parent image for the golden AMI. Leave unset to use Canonical's current Ubuntu 24.04 LTS (amd64) image."

  validation {
    condition     = var.ubuntu_parent_image == null || can(regex("^ami-[0-9a-f]{8,17}$", coalesce(var.ubuntu_parent_image, "x")))
    error_message = "ubuntu_parent_image must be an AMI ID (ami-...) or null."
  }
}


# SOFTWARE COMPONENTS


variable "enable_predefined_packages" {
  type        = bool
  description = "Whether to install the predefined base packages provided by the Ubuntu AMI module."
  default     = false
}

variable "enable_docker" {
  type        = bool
  description = "Whether to install and configure Docker."
  default     = false
}

variable "enable_aws_cli" {
  type        = bool
  description = "Whether to install AWS CLI v2."
  default     = false
}

variable "enable_python" {
  type        = bool
  description = "Whether to install Python and its associated package-management tooling."
  default     = false
}


# CUSTOM SOFTWARE COMMANDS


variable "custom_build_commands" {
  type        = list(string)
  description = "Additional shell commands supplied by the caller and executed during the AMI build."
  default     = []

  validation {
    condition = alltrue([
      for command in var.custom_build_commands :
      trimspace(command) != ""
    ])

    error_message = "custom_build_commands must contain only non-empty commands."
  }
}

variable "custom_validate_commands" {
  type        = list(string)
  description = "Additional shell commands supplied by the caller and executed during AMI validation."
  default     = []

  validation {
    condition = alltrue([
      for command in var.custom_validate_commands :
      trimspace(command) != ""
    ])

    error_message = "custom_validate_commands must contain only non-empty commands."
  }
}


# IMAGE VERSIONING

variable "component_version" {
  type        = string
  description = "Semantic version of the Image Builder component."
  default     = "1.0.0"

  validation {
    condition = can(regex(
      "^[0-9]+\\.[0-9]+\\.[0-9]+$",
      var.component_version
    ))

    error_message = "component_version must use semantic versioning in the form X.Y.Z."
  }
}

variable "recipe_version" {
  type        = string
  description = "Semantic version of the Image Builder recipe."
  default     = "1.0.0"

  validation {
    condition = can(regex(
      "^[0-9]+\\.[0-9]+\\.[0-9]+$",
      var.recipe_version
    ))

    error_message = "recipe_version must use semantic versioning in the form X.Y.Z."
  }
}


# AMI STORAGE


variable "root_volume_size" {
  type        = number
  description = "Root EBS volume size in GiB for the resulting AMI."
  default     = 24

  validation {
    condition     = var.root_volume_size >= 8
    error_message = "root_volume_size must be at least 8 GiB."
  }
}

variable "root_volume_type" {
  type        = string
  description = "Root EBS volume type for the resulting AMI."
  default     = "gp3"

  validation {
    condition = contains(
      ["gp2", "gp3"],
      lower(var.root_volume_type)
    )

    error_message = "root_volume_type must be either gp2 or gp3."
  }
}


# IMAGE BUILDER BUILD INFRASTRUCTURE


variable "instance_types" {
  type        = list(string)
  description = "EC2 instance types that Image Builder may use while constructing the AMI."
  default     = ["t3.medium"]

  validation {
    condition = (
      length(var.instance_types) > 0 &&
      alltrue([
        for instance_type in var.instance_types :
        trimspace(instance_type) != ""
      ])
    )

    error_message = "instance_types must contain at least one non-empty EC2 instance type."
  }
}




# AMI BUILD

variable "build_image" {
  type        = bool
  description = "Whether Terraform should create an Image Builder image resource and immediately start an AMI build."
  default     = false
}

variable "ami_build_trigger" {
  type        = string
  description = "Caller-controlled value used to explicitly request another AMI build when build_image is enabled."
  default     = ""
}

variable "ami_description" {
  type        = string
  description = "Description assigned to the resulting Ubuntu AMI."
  default     = "Reusable Ubuntu compute AMI."

  validation {
    condition     = trimspace(var.ami_description) != ""
    error_message = "ami_description must not be empty."
  }
}


# IMAGE BUILDER PIPELINE


variable "enable_pipeline" {
  type        = bool
  description = "Whether to create the recurring Image Builder pipeline."
  default     = false
}

variable "pipeline_schedule" {
  type        = string
  description = "EventBridge cron or rate expression controlling the Image Builder pipeline schedule."
  default     = "cron(0 3 ? * SUN *)"

  validation {
    condition     = trimspace(var.pipeline_schedule) != ""
    error_message = "pipeline_schedule must not be empty."
  }
}

variable "enable_image_tests" {
  type        = bool
  description = "Whether Image Builder runs its built-in tests against the generated AMI."
  default     = true
}

variable "image_test_timeout_minutes" {
  type        = number
  description = "Maximum number of minutes allowed for Image Builder AMI tests."
  default     = 60

  validation {
    condition     = var.image_test_timeout_minutes >= 1
    error_message = "image_test_timeout_minutes must be at least 1 minute."
  }
}




################################################################################
# DATABASE CONFIGURATION VARIABLES
################################################################################


# DB COMPUTE
variable "db_instance_type" {
  type        = string
  description = "EC2 instance type used for the database host."
  default     = "t3.medium"
}

variable "db_root_volume_size" {
  type        = number
  description = "Size of the encrypted root EBS volume in GiB."
  default     = 15

  validation {
    condition     = var.db_root_volume_size >= 15
    error_message = "DB root_volume_size must be at least 15 GiB."
  }
}

variable "db_associate_public_ip_address" {
  type        = bool
  description = "Whether to associate a public IPv4 address with the DB instance."
  default     = false
}

# ROUTE 53 / IAM
variable "db_enable_route53_write_access" {
  type        = bool
  description = "Whether the database host receives IAM permission to modify the supplied Route 53 hosted zone."
  default     = false
}


variable "db_enable_ecr_read_access" {
  type        = bool
  description = "Whether the database host receives IAM permission to pull images from Amazon ECR."
  default     = false
}


# PRIVATE DNS / SERVICE DISCOVERY
variable "db_enable_private_dns_registration" {
  type        = bool
  description = "Whether the database host registers its private IP in the supplied Route 53 private hosted zone."
  default     = false
}




# DATABASE SECONDARY DATA VOLUME
variable "db_enable_data_volume_mount" {
  type        = bool
  description = "Whether the database host should mount the secondary persistent EBS volume."
  default     = false
}

variable "db_data_volume_device" {
  type        = string
  description = "Linux device name of the secondary EBS volume attached to the database host."
  default     = "/dev/sdb"
}

variable "db_data_volume_size" {
  type        = number
  description = "Size of the DB secondary EBS volume in GiB."

  default = 30

  validation {
    condition     = var.db_data_volume_size >= 1
    error_message = "data_volume_size must be at least 1 GiB."
  }
}

variable "db_data_volume_mount_path" {
  type        = string
  description = "Filesystem path where the secondary EBS volume is mounted. An empty value uses the database workspace."
  default     = ""
}


variable "internal_tier_enabled" {
  type        = bool
  default     = false
  description = "Run the internal tier: its load balancer (about $21 a month) and its shared fleet. Off until an internal-tier service needs it; while off, the contract offers no internal tier and a service asking for it fails its plan."
}

variable "nat_type" {
  type        = string
  default     = "instance"
  description = "How private and internal hosts reach the internet: \"gateway\" (managed NAT Gateway) or \"instance\" (a NAT instance: far cheaper, but outbound traffic stops while it is recovered or replaced)."
}
