variable "vpc_id" {
  description = "ID of the VPC where the NACLs will be created."
  type        = string
}

variable "project_name" {
  description = "Project name used for resource naming."
  type        = string
}

variable "environment" {
  description = "Deployment environment."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs."
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "Private subnet IDs."
  type        = list(string)
}

variable "internal_subnet_ids" {
  description = "Internal subnet IDs."
  type        = list(string)
}

variable "isolated_subnet_ids" {
  description = "Isolated subnet IDs."
  type        = list(string)
}



variable "public_cidr_block" {
  description = "CIDR block representing the public subnet tier."
  type        = string
}

variable "private_cidr_block" {
  description = "CIDR block representing the private subnet tier."
  type        = string
}

variable "internal_cidr_block" {
  description = "CIDR block representing the internal subnet tier."
  type        = string
}

variable "isolated_cidr_block" {
  description = "CIDR block representing the isolated subnet tier."
  type        = string
}