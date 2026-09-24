variable "project_name" {
  type        = string
  description = "Project name. Part of the pool's, the function's and the sign-in domain's names."
}

variable "environment" {
  type        = string
  description = "Environment name. Part of the pool's, the function's and the sign-in domain's names."
}

variable "account_id" {
  type        = string
  description = "AWS account ID. Makes the sign-in domain prefix unique (Cognito prefixes are shared by every account in a Region), and limits who may invoke the function to this account's bucket."
}

variable "deploy_bucket_name" {
  type        = string
  description = "The deploy bucket, which holds the declarations under front-door/. This module owns its S3 event notifications."
}

variable "platform_emails" {
  type        = list(string)
  default     = []
  description = "The platform list's email addresses (core's people.json), declared as front-door/_platform.json."

  validation {
    condition     = alltrue([for email in var.platform_emails : can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", email))])
    error_message = "Each platform email must be an email address."
  }
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to the pool, the function and its role and logs."
}
