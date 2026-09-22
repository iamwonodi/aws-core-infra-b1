################################################################################
# FLEET CONFIG BUCKET
#
# Holds team-provided compose files and env files (one <service>-compose.yml
# and one <service>.env per service). Every fleet instance -- new or
# existing -- syncs this down before deploying anything, which is what
# makes a scale-out event work correctly: a brand-new instance gets the
# identical set of files as every other instance, rather than starting
# with nothing.
#
# Deliberately S3, not EBS: an EBS volume can only be attached to one
# instance at a time, which is the right shape for the database's
# single-host persistent storage but the wrong shape here -- every fleet
# instance needs to read the SAME shared files simultaneously. S3 is a
# shared, multi-reader resource by nature, which is exactly the property
# this needs.
################################################################################

module "bucket" {
  source = "git::https://github.com/iamwonodi/terraform-aws-s3.git?ref=v1.0.0"

  bucket_name = local.bucket_name

  force_destroy      = var.force_destroy
  versioning_enabled = true

  object_ownership = "BucketOwnerEnforced"

  block_public_access = {
    block_public_acls       = true
    block_public_policy     = true
    ignore_public_acls      = true
    restrict_public_buckets = true
  }

  encryption = {
    type = "SSE-S3"
  }

  tags = {
    Project     = var.project_name
    Environment = var.environment
    Purpose     = "deploy"
  }
}

################################################################################
# PLATFORM SCRIPTS
#
# The deploy library and fleet update script live in the deploy bucket under the
# reserved _platform/ prefix (never mirrored into a service directory, since each
# tier syncs only its own prefix). Their checksums are published in an SSM
# manifest that every host verifies before installing anything.
################################################################################

module "platform_scripts" {
  source = "../../platform/host-scripts"
}

resource "aws_s3_object" "deploy_lib" {
  bucket = module.bucket.bucket_id
  key    = local.deploy_lib_key
  source = module.platform_scripts.deploy_lib_path
  etag   = filemd5(module.platform_scripts.deploy_lib_path)
}

resource "aws_s3_object" "fleet_update" {
  bucket = module.bucket.bucket_id
  key    = local.fleet_update_key
  source = var.fleet_update_script_path
  etag   = filemd5(var.fleet_update_script_path)
}

resource "aws_ssm_parameter" "scripts_manifest" {
  name        = local.scripts_manifest_parameter
  description = "SHA-256 of every platform script the fleet hosts install, keyed by S3 object."
  type        = "String"
  value       = jsonencode(local.scripts_manifest)

  # The objects must exist before a manifest promises their checksums.
  depends_on = [aws_s3_object.deploy_lib, aws_s3_object.fleet_update]
}
