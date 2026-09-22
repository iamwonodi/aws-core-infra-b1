output "ami_id" {
  description = "The golden AMI's ID. Prefer parameter_name: a copied ID freezes the caller on one image."
  value       = module.ubuntu_ami.ami_id
}

output "parameter_name" {
  description = "SSM parameter holding the AMI ID. A service's launch template reads this, so a rebuild reaches it on the next plan."
  value       = aws_ssm_parameter.ami_id.name
}

output "image_arn" {
  description = "ARN of the Image Builder image."
  value       = module.ubuntu_ami.image_arn
}

output "pipeline_arn" {
  description = "ARN of the Image Builder pipeline, when one is enabled."
  value       = module.ubuntu_ami.pipeline_arn
}

output "instance_profile_name" {
  description = "Instance profile the build instance runs as."
  value       = module.ubuntu_ami_profile.instance_profile_name
}
