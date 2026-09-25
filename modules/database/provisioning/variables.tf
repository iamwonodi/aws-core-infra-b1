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

variable "agents_write_needs_approval" {
  type        = bool
  default     = false
  description = "A service's agents (<service>.<name>) may write only if their login is in write_exceptions. On in production. Core's own platform list is not affected: it is core-approved."
}

variable "write_exceptions" {
  type        = list(string)
  default     = []
  description = "Service agents' logins (<service>.<name>) that core approves to write where agents_write_needs_approval is on."

  validation {
    condition     = alltrue([for login in var.write_exceptions : can(regex("^[a-z][a-z0-9_]{1,21}\\.[a-z][a-z0-9]{1,19}$", login)) && length(login) <= 32])
    error_message = "Each write exception is a service agent's login, <service>.<name>, at most 32 characters."
  }
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

variable "isolated_security_group_id" {
  type        = string
  description = "The isolated tier's security group, which the function also wears: the Secrets Manager endpoint admits it, and its outbound rules let the function reach the database and the endpoint."
}

variable "connection_limits" {
  type = object({
    service_default    = number
    person             = number
    service_exceptions = map(number)
  })
  description = "How many connections each login may hold open at once on this function's engine: service_default for each service's own login, person for each person's (agents and the platform list, each counted separately), and service_exceptions, { <service_name> = number }, for services core approves to differ. From the environment's data/connection-limits.json. PostgreSQL and MySQL enforce them; MongoDB (DocumentDB) has no per-login limit. The administrator is never capped."

  validation {
    condition = alltrue([
      for limit in concat([var.connection_limits.service_default, var.connection_limits.person], values(var.connection_limits.service_exceptions)) :
      limit == floor(limit) && limit >= 1 && limit <= 10000
    ])
    error_message = "Every connection limit is a whole number from 1 to 10000: 0 would lock the login out."
  }

  validation {
    condition     = alltrue([for service in keys(var.connection_limits.service_exceptions) : can(regex("^[a-z][a-z0-9-]{1,20}[a-z0-9]$", service))])
    error_message = "Each key of service_exceptions is a service name: 3-22 lowercase letters, digits and hyphens."
  }
}
