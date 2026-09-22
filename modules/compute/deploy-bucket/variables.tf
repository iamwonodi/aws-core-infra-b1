variable "project_name" {
  type        = string
  description = "Project name. Part of the bucket's name and the manifest parameter's path."
}

variable "environment" {
  type        = string
  description = "Environment name. Part of the bucket's name."
}

variable "force_destroy" {
  type        = bool
  default     = false
  description = "Allow the bucket to be deleted while it still holds objects. False outside development: the bucket holds what every host installs."
}

variable "fleet_update_script_path" {
  type        = string
  description = "Path to the deploy engine (update.sh) published under _platform/fleet/."
}
