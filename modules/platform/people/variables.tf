variable "project_name" {
  type        = string
  description = "Project name. Part of the secret's name."
}

variable "environment" {
  type        = string
  description = "Environment name. Part of the secret's name."
}

variable "people" {
  type = map(object({
    email  = string
    access = string
  }))
  default     = {}
  description = "The team members who get a database login (platform.<name>) and, where there is a front door, a sign-in. Keyed by a short name: 2 to 20 lowercase letters and digits, starting with a letter. access is \"read\" or \"write\"."

  validation {
    condition     = alltrue([for name in keys(var.people) : can(regex("^[a-z][a-z0-9]{1,19}$", name))])
    error_message = "Each person's name must be 2 to 20 lowercase letters and digits, starting with a letter: it becomes the database login platform.<name>, and every engine's login names are at most 32 characters (MySQL)."
  }

  validation {
    condition     = alltrue([for person in values(var.people) : contains(["read", "write"], person.access)])
    error_message = "access must be \"read\" or \"write\"."
  }

  validation {
    condition     = alltrue([for person in values(var.people) : can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", person.email))])
    error_message = "Each person needs a valid email address: their sign-in, and where their invitation is sent."
  }

  validation {
    condition     = length(distinct([for person in values(var.people) : lower(person.email)])) == length(var.people)
    error_message = "Two people share an email address. Each sign-in is one email address."
  }
}

variable "read_only" {
  type        = bool
  default     = false
  description = "Refuse \"write\" for everyone on this list."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to the secret."
}
