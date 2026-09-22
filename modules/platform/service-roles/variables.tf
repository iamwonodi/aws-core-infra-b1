variable "project_name" {
  type        = string
  description = "Project name. Appears in resource names, which is what the generated permissions are scoped by."
}

variable "environment" {
  type        = string
  description = "Environment name (development, staging, production)."
}

variable "aws_region" {
  type        = string
  description = "AWS Region the permissions apply to."
}

variable "account_id" {
  type        = string
  description = "AWS account ID the permissions apply to."

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12-digit AWS account ID."
  }
}

variable "subject_format" {
  type        = string
  default     = "immutable"
  description = "OIDC subject format GitHub emits for the service repositories: \"immutable\" (numeric IDs, required for repositories created on or after 15 July 2026) or \"classic\"."
}

variable "entries" {
  type = map(object({
    service_name  = string
    kind          = string
    tier          = string
    owner_id      = optional(string)
    repository_id = optional(string)
    description   = optional(string)
  }))
  default     = {}
  description = "One entry per repository, keyed by OWNER/REPOSITORY. A service has two: kind \"infra\" (the repository holding its Terraform) and kind \"app\" (the repository that builds and deploys it). Normally decoded from data/service-roles.json."
}

variable "hosting_model" {
  type        = string
  default     = "shared"
  description = "How services are hosted in this environment. \"shared\": services run on the shared tier fleets (development). \"dedicated\": each service's infrastructure repository creates its own hosts, security group and configuration bucket (staging and production), which is what the permissions boundary is for."

  validation {
    condition     = contains(["shared", "dedicated"], var.hosting_model)
    error_message = "hosting_model must be \"shared\" or \"dedicated\"."
  }
}

variable "permissions_boundary_arn" {
  type        = string
  default     = null
  description = "ARN of the boundary policy every role a service's infrastructure repository creates must carry (see the service-boundary module). Required for a dedicated environment with any infra entry."
}

variable "tiers" {
  type = map(object({
    listener_arn      = string
    asg_arn           = optional(string)
    security_group_id = optional(string)
  }))
  default     = {}
  description = "The shared resources of each tier a service can be placed in. listener_arn (the HTTPS listener its ALB rule attaches to) is always needed. asg_arn and security_group_id are the shared fleet's ASG and security group, needed only for hosting_model \"shared\"."
}

variable "deploy_bucket_name" {
  type        = string
  default     = null
  description = "Shared fleet deploy bucket, where each service publishes <tier>/<service>/. Required for hosting_model \"shared\"; a dedicated service has its own configuration bucket."
}

variable "assets_bucket_name" {
  type        = string
  default     = null
  description = "Assets bucket, where each service publishes static/<service>/. Required once there is at least one entry."
}

variable "state_bucket_name" {
  type        = string
  default     = null
  description = "Terraform state bucket. Each service's infra repository keeps its state under <state_prefix>/<service>/. Required once there is at least one entry."
}

variable "state_prefix" {
  type        = string
  default     = "services"
  description = "Key prefix, inside the state bucket, under which each service's infra repository keeps its state."
}

variable "database_provision_document_name" {
  type        = string
  default     = null
  description = "SSM document that creates one service's database and user on the database host. A service's infra repository may send this document, and nothing else, to that host. Null in an environment without an EC2 database host."
}

variable "database_provision_function_arns" {
  type        = list(string)
  default     = []
  description = "Lambdas that create a service's database and user on the managed databases, one per engine. A service's infra repository may invoke these functions, and nothing else. Empty in an environment whose database is the EC2 host, or that runs no managed database."
}

variable "database_service_name" {
  type        = string
  default     = "database-hub"
  description = "Value of the Service tag on the database host. The provisioning document may only be sent to an instance carrying it."
}

variable "fleet_update_document_name" {
  type        = string
  default     = null
  description = "SSM document that redeploys a shared fleet host. A service's app repository may send this document and nothing else. Required for hosting_model \"shared\"."
}
