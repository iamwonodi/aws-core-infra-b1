variable "project_name" {
  type        = string
  description = "Project name. Part of the secret's and the user pool's names."
}

variable "environment" {
  type        = string
  description = "Environment name. Part of the secret's and the user pool's names."
}

variable "account_id" {
  type        = string
  description = "AWS account ID. Makes the sign-in domain prefix unique, since Cognito prefixes are shared by every account in a Region."
}

variable "people" {
  type = map(object({
    email  = string
    access = string
  }))
  default     = {}
  description = "The team members who get a database login (agent_<name>) and, where there is a front door, a sign-in. Keyed by a short name: 2 to 20 lowercase letters and digits, starting with a letter. access is \"read\" or \"write\"."

  validation {
    condition     = alltrue([for name in keys(var.people) : can(regex("^[a-z][a-z0-9]{1,19}$", name))])
    error_message = "Each person's name must be 2 to 20 lowercase letters and digits, starting with a letter: it becomes the database user agent_<name>, which every engine accepts unquoted."
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
  description = "Refuse \"write\" for everyone. Set in production, where no one changes data from a GUI."
}

variable "front_door" {
  type        = bool
  default     = false
  description = "Create the Cognito sign-in the team tools' web addresses sit behind, with one user per person. Off in production, which is reached only through a private tunnel."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to the secret and the user pool."
}
