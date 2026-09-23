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

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private-tier subnet IDs. The private-tier fleet is launched here."

  validation {
    condition     = length(var.private_subnet_ids) > 0
    error_message = "private_subnet_ids must contain at least one subnet ID."
  }
}

variable "internal_subnet_ids" {
  type        = list(string)
  description = "Internal-tier subnet IDs. The internal-tier fleet is launched here, and the first entry is also used as the temporary build subnet for the Ubuntu AMI."

  validation {
    condition     = length(var.internal_subnet_ids) > 0
    error_message = "internal_subnet_ids must contain at least one subnet ID."
  }
}

variable "private_security_group_id" {
  type        = string
  description = "Security group ID for the private tier. Attached to the private-tier fleet's launch template."

  validation {
    condition     = trimspace(var.private_security_group_id) != ""
    error_message = "private_security_group_id must not be empty."
  }
}

variable "internal_security_group_id" {
  type        = string
  description = "Security group ID for the internal tier. Attached to the internal-tier fleet's launch template, and to the temporary Ubuntu AMI build instance."

  validation {
    condition     = trimspace(var.internal_security_group_id) != ""
    error_message = "internal_security_group_id must not be empty."
  }
}

################################################################################
# UBUNTU AMI - BASE IMAGE
################################################################################

variable "ubuntu_parent_image" {
  type        = string
  default     = null
  description = "Ubuntu AMI ID used as the parent image for the golden AMI shared by both fleets. Leave null to use Canonical's current Ubuntu 24.04 LTS (amd64) image, which Canonical publishes as a public SSM parameter; AMI IDs differ per Region and go stale, so an explicit ID is only needed to pin one."

  validation {
    condition     = var.ubuntu_parent_image == null || can(regex("^ami-[0-9a-f]{8,17}$", coalesce(var.ubuntu_parent_image, "x")))
    error_message = "ubuntu_parent_image must be an AMI ID (ami-...) or null."
  }
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

################################################################################
# UBUNTU AMI - SOFTWARE COMPONENTS
################################################################################

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

################################################################################
# UBUNTU AMI - IMAGE VERSIONING
################################################################################

variable "component_version" {
  type        = string
  description = "Semantic version of the Image Builder component."
  default     = "1.0.0"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.component_version))
    error_message = "component_version must use semantic versioning in the form X.Y.Z."
  }
}

variable "recipe_version" {
  type        = string
  description = "Semantic version of the Image Builder recipe."
  default     = "1.0.0"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.recipe_version))
    error_message = "recipe_version must use semantic versioning in the form X.Y.Z."
  }
}

################################################################################
# UBUNTU AMI - STORAGE
################################################################################

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
    condition     = contains(["gp2", "gp3"], lower(var.root_volume_type))
    error_message = "root_volume_type must be either gp2 or gp3."
  }
}

################################################################################
# UBUNTU AMI - BUILD INFRASTRUCTURE
#
# Named ami_instance_types (rather than the generic instance_types) since
# this module also has per-fleet capacity settings below -- an unqualified
# name here would be ambiguous about which thing it sizes.
################################################################################

variable "ami_instance_types" {
  type        = list(string)
  description = "EC2 instance types that Image Builder may use while constructing the Ubuntu AMI."
  default     = ["t3.medium"]

  validation {
    condition = (
      length(var.ami_instance_types) > 0 &&
      alltrue([
        for instance_type in var.ami_instance_types :
        trimspace(instance_type) != ""
      ])
    )

    error_message = "ami_instance_types must contain at least one non-empty EC2 instance type."
  }
}

################################################################################
# UBUNTU AMI - BUILD TRIGGER
################################################################################

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

################################################################################
# UBUNTU AMI - IMAGE BUILDER PIPELINE
################################################################################

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
# FLEETS - SHARED
################################################################################

variable "deploy_bucket_force_destroy" {
  type        = bool
  description = "Whether the fleet config bucket (team-provided compose/env files) can be destroyed while it still contains objects. Matches the same per-environment reasoning as the edge domain module's assets_force_destroy -- development sets this true, staging/production should not."
  default     = false
}

################################################################################
# PRIVATE-TIER FLEET CAPACITY
################################################################################

variable "private_fleet_min_size" {
  type        = number
  description = "Minimum instance count for the private-tier fleet."
  default     = 1

  validation {
    condition     = var.private_fleet_min_size >= 0
    error_message = "private_fleet_min_size must be greater than or equal to 0."
  }
}

variable "private_fleet_desired_capacity" {
  type        = number
  description = "Desired instance count for the private-tier fleet."
  default     = 1

  validation {
    condition     = var.private_fleet_desired_capacity >= 0
    error_message = "private_fleet_desired_capacity must be greater than or equal to 0."
  }
}

variable "private_fleet_max_size" {
  type        = number
  description = "Maximum instance count for the private-tier fleet."
  default     = 2

  validation {
    condition     = var.private_fleet_max_size >= 0
    error_message = "private_fleet_max_size must be greater than or equal to 0."
  }
}

################################################################################
# INTERNAL-TIER FLEET CAPACITY
################################################################################

variable "internal_fleet_min_size" {
  type        = number
  description = "Minimum instance count for the internal-tier fleet."
  default     = 1

  validation {
    condition     = var.internal_fleet_min_size >= 0
    error_message = "internal_fleet_min_size must be greater than or equal to 0."
  }
}

variable "internal_fleet_desired_capacity" {
  type        = number
  description = "Desired instance count for the internal-tier fleet."
  default     = 1

  validation {
    condition     = var.internal_fleet_desired_capacity >= 0
    error_message = "internal_fleet_desired_capacity must be greater than or equal to 0."
  }
}

variable "internal_fleet_max_size" {
  type        = number
  description = "Maximum instance count for the internal-tier fleet."
  default     = 2

  validation {
    condition     = var.internal_fleet_max_size >= 0
    error_message = "internal_fleet_max_size must be greater than or equal to 0."
  }
}

variable "database_service_name" {
  type        = string
  default     = "database-hub"
  description = "Service name the database module gives its secret vault. The fleet's secret read policy explicitly denies that secret, so this must match the service name the database module uses for that vault."

  validation {
    condition     = trimspace(var.database_service_name) != ""
    error_message = "database_service_name must not be empty."
  }
}

variable "internal_fleet_enabled" {
  type        = bool
  default     = true
  description = "Run the internal-tier fleet. False holds it at zero instances (the group itself remains, costing nothing) until an internal-tier service needs it."
}
