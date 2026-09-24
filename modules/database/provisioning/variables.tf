variable "project_name" {
  type        = string
  description = "Project name. Part of the function's name."
}

variable "environment" {
  type        = string
  description = "Environment name. Part of the function's name."
}

variable "name" {
  type        = string
  default     = null
  description = "Distinguishes this function from another in the same environment. Defaults to the database's engine, so two databases with different engines do not collide."
}

variable "engine" {
  type        = string
  default     = "postgres"
  description = "The database's engine: \"postgres\", \"mysql\" or \"mongodb\" (DocumentDB). Another engine needs a driver adding to lambda/vendor/."

  validation {
    condition     = contains(["postgres", "mysql", "mongodb"], var.engine)
    error_message = "The provisioning function speaks PostgreSQL, MySQL and MongoDB (DocumentDB). For another engine, add its driver to lambda/vendor/ and teach provision.py to use it."
  }
}

variable "database_host" {
  type        = string
  description = "Hostname of the database the function provisions."
}

variable "database_port" {
  type        = number
  description = "Port the database listens on."
}

variable "admin_database" {
  type        = string
  default     = "postgres"
  description = "Database the function connects to before a service's own database exists. PostgreSQL always has one called \"postgres\"; a MySQL instance has only the one created with it."
}

variable "admin_secret_arn" {
  type        = string
  description = "ARN of the administrator credential. The function reads username and password from it."
}

variable "people_secret_arn" {
  type        = string
  default     = null
  description = "ARN of the people secret: every team member's password and access level. With it, the function brings the engine's agent_<name> logins in line with that secret on {\"action\": \"people\"} and after every service it provisions. Null: no people."
}

variable "service_secret_pattern" {
  type        = string
  default     = null
  description = "Name of a service's secret, with {service} standing for the service's name. Defaults to core's convention, <project>-{service}-<environment>-secret-vault. The function builds the name itself, so a caller cannot point it at another service's secret."
}

variable "vpc_id" {
  type        = string
  description = "VPC the function runs in. It needs a route to the database, which is why it is placed in the VPC at all."
}

variable "subnet_ids" {
  type        = list(string)
  description = "Subnets the function runs in: the same isolated subnets as the database. They must reach Secrets Manager, KMS and CloudWatch Logs, which without a NAT gateway means interface endpoints."

  validation {
    condition     = length(var.subnet_ids) >= 1
    error_message = "subnet_ids must name at least one subnet."
  }
}

variable "database_security_group_id" {
  type        = string
  description = "The database's security group. An ingress rule is added to it so the function can connect."
}

variable "log_retention_days" {
  type        = number
  default     = 30
  description = "Days to keep the function's logs. Without a retention they are kept, and billed for, for ever."
}

variable "timeout_seconds" {
  type        = number
  default     = 60
  description = "How long the function may run. Creating a database is quick; connecting to an instance that is still starting is not."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to every resource this module creates."
}
