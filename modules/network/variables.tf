################################################################################
# CORE IDENTIFICATION
################################################################################

variable "project_name" {
  type        = string
  description = "Project name used to identify every resource this module creates."

  validation {
    condition     = trimspace(var.project_name) != ""
    error_message = "project_name must not be empty."
  }
}

variable "environment" {
  type        = string
  description = "Deployment environment used to identify every resource this module creates."

  validation {
    condition     = trimspace(var.environment) != ""
    error_message = "environment must not be empty."
  }
}

################################################################################
# VPC AND SUBNET CIDRS
################################################################################

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the VPC as a whole."

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block."
  }
}

variable "public_subnet_cidrs" {
  type        = list(string)
  description = "CIDR blocks for the public tier's subnets. Holds only the Internet Gateway and NAT Gateway."

  validation {
    condition = (
      length(var.public_subnet_cidrs) > 0 &&
      alltrue([for cidr in var.public_subnet_cidrs : can(cidrnetmask(cidr))])
    )

    error_message = "public_subnet_cidrs must contain at least one valid IPv4 CIDR block."
  }
}

variable "private_subnet_cidrs" {
  type        = list(string)
  description = "CIDR blocks for the private tier's subnets. Runs the frontend, backend API, and DB GUI client."

  validation {
    condition = (
      length(var.private_subnet_cidrs) > 0 &&
      alltrue([for cidr in var.private_subnet_cidrs : can(cidrnetmask(cidr))])
    )

    error_message = "private_subnet_cidrs must contain at least one valid IPv4 CIDR block."
  }
}

variable "internal_subnet_cidrs" {
  type        = list(string)
  description = "CIDR blocks for the internal tier's subnets. Runs stateless internal applications such as payment and notifications."

  validation {
    condition = (
      length(var.internal_subnet_cidrs) > 0 &&
      alltrue([for cidr in var.internal_subnet_cidrs : can(cidrnetmask(cidr))])
    )

    error_message = "internal_subnet_cidrs must contain at least one valid IPv4 CIDR block."
  }
}

variable "isolated_subnet_cidrs" {
  type        = list(string)
  description = "CIDR blocks for the isolated tier's subnets. Runs the database, which is never scaled and has no route out of the VPC."

  validation {
    condition = (
      length(var.isolated_subnet_cidrs) > 0 &&
      alltrue([for cidr in var.isolated_subnet_cidrs : can(cidrnetmask(cidr))])
    )

    error_message = "isolated_subnet_cidrs must contain at least one valid IPv4 CIDR block."
  }
}

################################################################################
# NACL SUMMARY CIDRS
#
# A single CIDR per tier, standing in for "every subnet in this tier" for
# the NACL module's rules. See validations.tf for the cross-variable check
# ensuring each of these is at least broad enough to cover its tier's real
# subnet CIDRs -- and its documented limitation.
################################################################################

variable "public_summary_cidr" {
  type        = string
  description = "Single CIDR block covering every public-tier subnet, used by the NACL module."

  validation {
    condition     = can(cidrnetmask(var.public_summary_cidr))
    error_message = "public_summary_cidr must be a valid IPv4 CIDR block."
  }
}

variable "private_summary_cidr" {
  type        = string
  description = "Single CIDR block covering every private-tier subnet, used by the NACL module."

  validation {
    condition     = can(cidrnetmask(var.private_summary_cidr))
    error_message = "private_summary_cidr must be a valid IPv4 CIDR block."
  }
}

variable "internal_summary_cidr" {
  type        = string
  description = "Single CIDR block covering every internal-tier subnet, used by the NACL module."

  validation {
    condition     = can(cidrnetmask(var.internal_summary_cidr))
    error_message = "internal_summary_cidr must be a valid IPv4 CIDR block."
  }
}

variable "isolated_summary_cidr" {
  type        = string
  description = "Single CIDR block covering every isolated-tier subnet, used by the NACL module."

  validation {
    condition     = can(cidrnetmask(var.isolated_summary_cidr))
    error_message = "isolated_summary_cidr must be a valid IPv4 CIDR block."
  }
}
