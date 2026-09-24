variable "project_name" {
  type        = string
  description = "Project name."
}

variable "environment" {
  type        = string
  description = "Environment name."
}

variable "aws_region" {
  type        = string
  description = "AWS Region the tools run in."
}

variable "account_id" {
  type        = string
  description = "AWS account ID."
}

variable "subject_format" {
  type        = string
  default     = "immutable"
  description = "OIDC subject format GitHub emits for the repository: \"immutable\" or \"classic\"."
}

variable "repository" {
  type = object({
    name          = string
    owner_id      = string
    repository_id = string
  })
  default     = null
  description = "The team-tools repository (OWNER/REPOSITORY and its numeric IDs). Null grants nothing."
}

variable "state_bucket_name" {
  type        = string
  default     = null
  description = "Core's state bucket; the repository keeps its state under state_prefix."
}

variable "state_prefix" {
  type        = string
  default     = "team-tools"
  description = "The repository's own prefix in the state bucket."
}

variable "permissions_boundary_arn" {
  type        = string
  default     = null
  description = "The boundary every role the repository creates must carry (core's service boundary). The tools' instance role, tagged Service=team-tools, gets only what the boundary allows that tag."
}

variable "ami_parameter_name" {
  type        = string
  default     = null
  description = "SSM parameter holding core's golden AMI ID, which the tools' launch template reads."
}

variable "listener_arn" {
  type        = string
  default     = null
  description = "The private tier load balancer's HTTPS listener, where the tools' rules go. Null where the tools have no web address (production)."
}

variable "user_pool_arn" {
  type        = string
  default     = null
  description = "The front door's Cognito user pool, where the repository creates its app client and managed login style. Null where there is no front door (production)."
}
