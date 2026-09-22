variable "project_name" {
  type        = string
  description = "Project name."
}

variable "environment" {
  type        = string
  description = "Environment name (development, staging, production)."
}

variable "aws_region" {
  type        = string
  description = "AWS Region of the environment."
}

variable "account_id" {
  type        = string
  description = "AWS account ID of the environment."

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12-digit AWS account ID."
  }
}

variable "domain_name" {
  type        = string
  description = "Public domain the environment serves."
}

variable "private_domain" {
  type        = string
  description = "Domain of the VPC-only DNS zone."
}

variable "vpc_id" {
  type        = string
  description = "VPC ID."
}

variable "hosting_model" {
  type        = string
  default     = "shared"
  description = "How services are hosted here: \"shared\" (services run on shared tier fleets) or \"dedicated\" (each service's infrastructure creates its own hosts). Tells a service which pieces of the contract apply."

  validation {
    condition     = contains(["shared", "dedicated"], var.hosting_model)
    error_message = "hosting_model must be \"shared\" or \"dedicated\"."
  }
}

variable "service_boundary_arn" {
  type        = string
  default     = null
  description = "ARN of the permissions boundary every IAM role a service's infrastructure creates must carry. Set in a dedicated environment, null otherwise."
}

variable "deploy_bucket_name" {
  type        = string
  default     = null
  description = "Shared fleet deploy bucket, where a service publishes <tier>/<service>/. Null in a dedicated environment, where each service has its own configuration bucket."
}

variable "ami_parameter_name" {
  type        = string
  default     = null
  description = "SSM parameter holding the golden AMI's ID. A service that creates its own hosts reads the PARAMETER, so core rebuilding the image reaches it on the next plan; a copied ID would freeze it on one image."
}

variable "scripts_manifest_parameter" {
  type        = string
  default     = null
  description = "SSM parameter holding the SHA-256 of every platform script. A host verifies what it downloads from the deploy bucket's _platform/ prefix against this."
}

variable "assets_bucket_name" {
  type        = string
  description = "Assets bucket: where a service publishes static/<service>/."
}

variable "fleet_update_document_name" {
  type        = string
  default     = null
  description = "SSM document a service sends to redeploy its shared tier's hosts. Null in a dedicated environment, where each service has its own update document."
}

variable "database_provision_document_name" {
  type        = string
  default     = null
  description = "SSM document a service's infrastructure repository sends to create its database and user. Null where there is no database host to provision on."
}

variable "database_provision_function_name" {
  type        = string
  default     = null
  description = "Lambda a service's infrastructure repository invokes to create its database and user on a managed database. Null where provisioning is done on an EC2 database host instead (development)."
}

variable "database_update_document_name" {
  type        = string
  default     = null
  description = "SSM document the platforms team's pipeline sends to apply the database engines it published. Null where there is no EC2 database host (a managed database runs no published engines)."
}

variable "database_engines" {
  type = map(object({
    host               = string
    port               = number
    provision_function = optional(string)
  }))
  default     = {}
  description = "The managed database instances, one per active engine: where each is and which Lambda provisions a service's database on it (null until the function speaks that engine). Empty in development, whose engines run on the EC2 host and publish their ports as SSM parameters."

  validation {
    condition     = alltrue([for engine in keys(var.database_engines) : contains(["postgres", "mysql", "mongodb"], engine)])
    error_message = "database_engines may be keyed only by postgres, mysql and mongodb."
  }
}

variable "isolated_security_group_id" {
  type        = string
  default     = null
  description = "Security group of the isolated tier, where the databases live."
}

variable "database_host" {
  type        = string
  default     = null
  description = "Address of the database host, or null when the environment has none."
}

variable "tiers" {
  type = map(object({
    listener_arn          = string
    alb_security_group_id = string
    security_group_id     = optional(string)
    asg_name              = optional(string)
    subnet_ids            = optional(list(string))
  }))
  description = "The resources of each tier a service can be placed in. listener_arn and alb_security_group_id are always present; security_group_id and asg_name are the shared fleet's, present only when hosting_model is \"shared\"; subnet_ids are where a service's own hosts go when it is \"dedicated\"."

  validation {
    condition     = alltrue([for name in keys(var.tiers) : contains(["private", "internal"], name)])
    error_message = "tiers may only contain \"private\" and \"internal\"."
  }
}
