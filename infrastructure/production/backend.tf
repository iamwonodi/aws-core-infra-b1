terraform {
  backend "s3" {
    bucket       = "core-production-tfstate" # <project>-production-tfstate: scripts/init-project.sh sets it
    key          = "core/terraform.tfstate"  # Folder path inside your bucket
    region       = "af-south-1"              # backend blocks cannot use variables: scripts/init-project.sh sets it with aws_region
    encrypt      = true                      # Forces encryption on upload
    use_lockfile = true                      # Native S3 locking, no DynamoDB
  }
}
