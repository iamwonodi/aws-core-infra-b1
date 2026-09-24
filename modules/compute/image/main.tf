# ------------------------------------------------------------------------------
# GOLDEN AMI
#
# One image per environment, built by CORE and used by every host in it: the
# shared fleets in development, and each service's own hosts in staging and
# production.
#
# Core owns it rather than each service building its own, because patching is
# the argument that decides it: a CVE fix is then one rebuild, not one per
# service, and the image nobody remembers to rebuild is the one that stays
# vulnerable. Nothing in the image varies per service either -- it is a container
# host, and the application arrives as a container.
#
# The AMI ID is published as an SSM parameter rather than handed out as a value.
# A service's launch template reads the parameter, so core rebuilding the image
# gives that service a new launch template version on its next plan. A value
# copied once would freeze every service on whatever was current that day.
# ------------------------------------------------------------------------------

module "ubuntu_ami_profile" {
  source = "git::https://github.com/iamwonodi/terraform-aws-profile.git?ref=v1.1.1"

  project_name = var.project_name
  environment  = var.environment
  service_name = "ubuntu-ami"

  enable_ssm_access = true
}

module "ubuntu_ami" {
  source = "git::https://github.com/iamwonodi/terraform-aws-ubuntu-ami.git?ref=v2.0.0"

  project_name = var.project_name
  environment  = var.environment

  parent_image = var.parent_image

  enable_predefined_packages = var.enable_predefined_packages
  enable_docker              = var.enable_docker
  enable_aws_cli             = var.enable_aws_cli
  enable_python              = var.enable_python

  custom_build_commands    = var.custom_build_commands
  custom_validate_commands = var.custom_validate_commands

  component_version = var.component_version
  recipe_version    = var.recipe_version

  root_volume_size = var.root_volume_size
  root_volume_type = var.root_volume_type

  instance_types = var.instance_types

  # The subnet must provide outbound internet access (via NAT) for this build to
  # succeed: apt-get, Docker and AWS CLI installs in the build commands all need
  # it, so the internal tier rather than the isolated one.
  subnet_id          = var.subnet_id
  security_group_ids = var.security_group_ids

  instance_profile_name = module.ubuntu_ami_profile.instance_profile_name

  build_image   = var.build_image
  build_trigger = var.build_trigger

  ami_description = var.ami_description

  enable_pipeline            = var.enable_pipeline
  pipeline_schedule          = var.pipeline_schedule
  enable_image_tests         = var.enable_image_tests
  image_test_timeout_minutes = var.image_test_timeout_minutes
}

resource "aws_ssm_parameter" "ami_id" {
  name        = local.parameter_name
  description = "AMI ID of the golden image for ${var.environment}. Read it; do not copy it: it changes when the image is rebuilt."
  type        = "String"
  value       = module.ubuntu_ami.ami_id

  tags = var.tags
}
