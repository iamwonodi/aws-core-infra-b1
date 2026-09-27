terraform {
  backend "s3" {
    # <project>-production-tfstate: scripts/init-project.sh sets it.
    bucket = "core-production-tfstate"
    # Folder path inside the bucket.
    key = "core/terraform.tfstate"
    # Backend blocks cannot use variables: scripts/init-project.sh sets this
    # from aws_region.
    region = "af-south-1"
    # Forces encryption on upload.
    encrypt = true
    # Native S3 locking, no DynamoDB.
    use_lockfile = true
  }
}
