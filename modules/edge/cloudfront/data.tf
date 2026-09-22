################################################################################
# AWS MANAGED CACHE POLICIES
################################################################################

# Optimized caching policy for static/media/error content.
data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

# Recommended policy for dynamic application requests.
data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}


# Managed origin request policy that forwards all viewer headers
data "aws_cloudfront_origin_request_policy" "all_viewer" {
  name = "Managed-AllViewer"
}



################################################################################
# S3 BUCKET POLICY
################################################################################
#
# IMPORTANT:
#
# The CloudFront module creates the OAC, but the S3 bucket policy remains the
# responsibility of the caller.
#
# This keeps the CloudFront module composable and avoids coupling the S3
# lifecycle to the CloudFront lifecycle.
#
# The policy grants CloudFront permission to read objects from the private
# bucket only when the request originates from this CloudFront distribution.
################################################################################

data "aws_iam_policy_document" "cloudfront_s3" {
  statement {
    sid    = "AllowCloudFrontReadObjects"
    effect = "Allow"

    principals {
      type = "Service"

      identifiers = [
        "cloudfront.amazonaws.com"
      ]
    }

    actions = [
      "s3:GetObject"
    ]

    resources = [
      "${var.s3_bucket_arn}/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"

      values = [
        module.cloudfront.arn
      ]
    }
  }
}
