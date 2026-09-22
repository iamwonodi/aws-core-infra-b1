variable "project_name" {
  type        = string
  description = "Project name."
}

variable "environment" {
  type        = string
  description = "Environment name."
}

variable "instances" {
  type = map(object({
    id  = string
    arn = string
  }))
  default     = {}
  description = "The RDS instances to start and stop, by engine: each one's identifier and ARN."
}

variable "clusters" {
  type = map(object({
    id  = string
    arn = string
  }))
  default     = {}
  description = "The DocumentDB clusters to start and stop, by engine: each one's identifier and ARN. A cluster starts and stops as a whole, instances included."
}

variable "days" {
  type        = list(string)
  default     = ["SAT", "SUN"]
  description = "Days the instances run, as three-letter names (MON ... SUN)."

  validation {
    condition     = length(var.days) > 0 && alltrue([for day in var.days : contains(["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"], day)])
    error_message = "days must list one or more of MON, TUE, WED, THU, FRI, SAT, SUN."
  }

  validation {
    condition     = length(distinct(var.days)) == length(var.days)
    error_message = "days lists a day more than once."
  }
}

variable "start" {
  type        = string
  default     = "08:00"
  description = "Time the instances start on each running day, HH:MM in the time zone."

  validation {
    condition     = can(regex("^([01][0-9]|2[0-3]):[0-5][0-9]$", var.start))
    error_message = "start must be HH:MM, 24-hour."
  }
}

variable "stop" {
  type        = string
  default     = "19:00"
  description = "Time the instances stop, every day, HH:MM in the time zone."

  validation {
    condition     = can(regex("^([01][0-9]|2[0-3]):[0-5][0-9]$", var.stop))
    error_message = "stop must be HH:MM, 24-hour."
  }
}

variable "timezone" {
  type        = string
  default     = "Africa/Lagos"
  description = "IANA time zone the start and stop times are in."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags for the scheduler's role."
}
