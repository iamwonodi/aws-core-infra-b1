variable "github_repository" {
  type        = string
  description = "GitHub repository in OWNER/REPOSITORY form."

  validation {
    condition     = can(regex("^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$", var.github_repository))
    error_message = "github_repository must be in OWNER/REPOSITORY form."
  }
}

variable "github_owner_id" {
  type        = string
  default     = null
  description = "Numeric GitHub ID of the repository owner. Required when subject_format is \"immutable\"."
}

variable "github_repository_id" {
  type        = string
  default     = null
  description = "Numeric GitHub ID of the repository. Required when subject_format is \"immutable\"."
}

variable "subject_format" {
  type        = string
  default     = "immutable"
  description = "OIDC subject format GitHub emits for the repository. \"immutable\" embeds the numeric owner and repository IDs (repos created, renamed or transferred on or after 15 July 2026); \"classic\" uses names only."

  validation {
    condition     = contains(["immutable", "classic"], var.subject_format)
    error_message = "subject_format must be \"immutable\" or \"classic\"."
  }
}

variable "environment" {
  type        = string
  description = "GitHub Environment name the workflows use for applies (for example development). Plan jobs use the same name with -plan appended."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.environment)) && !endswith(var.environment, "-plan")
    error_message = "environment must be lowercase letters, digits and hyphens, and must not already end in -plan."
  }
}
