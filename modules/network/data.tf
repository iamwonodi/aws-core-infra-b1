data "aws_region" "current" {}

# S3's address ranges in this Region, which the gateway endpoint routes: the
# isolated tier's security group allows HTTPS to them.
data "aws_ec2_managed_prefix_list" "s3" {
  name = "com.amazonaws.${data.aws_region.current.region}.s3"
}
