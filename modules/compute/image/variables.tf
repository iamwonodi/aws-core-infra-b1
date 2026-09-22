variable "project_name" {
  type        = string
  description = "Project name. Part of the image's names."
}

variable "environment" {
  type        = string
  description = "Environment name. Part of the image's names."
}

variable "parent_image" {
  type        = string
  description = "AMI the golden image is built from."
}

variable "subnet_id" {
  type        = string
  description = "Subnet the build instance runs in. It needs outbound internet access, so the internal tier rather than the isolated one."
}

variable "security_group_ids" {
  type        = list(string)
  description = "Security groups for the build instance."
}

variable "instance_types" {
  type        = list(string)
  description = "Instance types the build may use."
  default     = ["t3.medium"]
}

variable "build_trigger" {
  type        = string
  default     = null
  description = "Change this to force a rebuild without changing the recipe."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to the SSM parameter this module creates."
}

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

variable "build_image" {
  type        = bool
  description = "Whether Terraform should create an Image Builder image resource and immediately start an AMI build."
  default     = false
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
