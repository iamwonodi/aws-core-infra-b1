variable "project_name" {
  type        = string
  description = "Project name, used in the delegation set's reference name."

  validation {
    condition     = trimspace(var.project_name) != ""
    error_message = "project_name must not be empty."
  }
}

variable "environment" {
  type        = string
  description = "Environment name, used in the delegation set's reference name."

  validation {
    condition     = trimspace(var.environment) != ""
    error_message = "environment must not be empty."
  }
}
