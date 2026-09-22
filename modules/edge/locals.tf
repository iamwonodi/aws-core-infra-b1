locals {
  private_alb_name           = "private-alb"
  private_alb_sg_description = "Security group for the private-tier ALB, which CloudFront routes application traffic to as a VPC origin."

  internal_alb_name           = "internal-alb"
  internal_alb_sg_description = "Security group for the internal-tier ALB, reached only from the private tier's backend API."

  cloudfront_aliases = [
    var.domain_name,
    "www.${var.domain_name}",
    "*.${var.domain_name}",
  ]

  # ==============================================================================
  # CONTENT TYPE MAP
  #
  # Maps a file extension (lowercase, leading dot included) to the
  # Content-Type each matching object is served with from S3.
  #
  # Anything not listed here falls back to "application/octet-stream" in
  # main.tf's lookup() call. That fallback isn't a silent no-op -- browsers
  # generally treat octet-stream as "download this" rather than "render
  # this", and are strict enough about font MIME types specifically that a
  # missing entry here can mean images that won't display inline or
  # @font-face fonts a browser refuses to load, not just a cosmetic gap.
  #
  # Extend this list as new file types show up in the assets repository --
  # it's deliberately broader than what's in the assets repo today, so
  # adding a new file type there usually won't require a matching change
  # here too.
  # ==============================================================================

  content_types = {
    # --- Web markup / text ---
    ".html" = "text/html"
    ".htm"  = "text/html"
    ".css"  = "text/css"
    ".js"   = "application/javascript"
    ".mjs"  = "application/javascript"
    ".json" = "application/json"
    ".xml"  = "application/xml"
    ".txt"  = "text/plain"
    ".md"   = "text/markdown"
    ".csv"  = "text/csv"

    # --- Images ---
    ".png"  = "image/png"
    ".jpg"  = "image/jpeg"
    ".jpeg" = "image/jpeg"
    ".gif"  = "image/gif"
    ".svg"  = "image/svg+xml"
    ".webp" = "image/webp"
    ".ico"  = "image/x-icon"
    ".bmp"  = "image/bmp"
    ".tiff" = "image/tiff"
    ".avif" = "image/avif"

    # --- Fonts ---
    ".woff"  = "font/woff"
    ".woff2" = "font/woff2"
    ".ttf"   = "font/ttf"
    ".otf"   = "font/otf"
    ".eot"   = "application/vnd.ms-fontobject"

    # --- Documents / archives ---
    ".pdf" = "application/pdf"
    ".zip" = "application/zip"
    ".gz"  = "application/gzip"
    ".tar" = "application/x-tar"

    # --- Audio / video ---
    ".mp3"  = "audio/mpeg"
    ".mp4"  = "video/mp4"
    ".webm" = "video/webm"
    ".ogg"  = "audio/ogg"
    ".wav"  = "audio/wav"

    # --- Web app / misc ---
    ".map"         = "application/json" # source maps
    ".wasm"        = "application/wasm"
    ".webmanifest" = "application/manifest+json"
  }

  assets = fileset(var.assets_path, "**")
}
