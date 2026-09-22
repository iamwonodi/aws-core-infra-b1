locals {

  cloudfront_header = "X-CloudFront-Secret"
  cloudfront_token  = random_password.cloudfront_token.result


  # Shared behaviors that aren't tied to a specific service.
  shared_path_behaviors = {
    errors = "/errors/*"
    media  = "/media/*"
    static = "/static/*"
  }

  # The shared paths are the only S3 behaviors. Services do not get a behavior
  # of their own: each publishes under a prefix inside a shared path
  # (static/<service>/ for static files), so onboarding a service never needs a
  # CloudFront change.
  s3_asset_path_patterns = local.shared_path_behaviors
}
