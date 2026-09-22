terraform {
  backend "s3" {
    bucket       = "core-development-tfstate" # Remember to change the core in "core-development-tfstate" to the name of the project that own this service/application.
    key          = "core/terraform.tfstate"   # Folder path inside your bucket
    region       = "af-south-1"               # backend blocks cannot reference var.aws_region, since they're evaluated before any variables exist. Keep this in sync with terraform.tfvars's aws_region by hand.
    encrypt      = true                       # Forces encryption on upload
    use_lockfile = true                       # Native S3 locking, no DynamoDB
  }
}