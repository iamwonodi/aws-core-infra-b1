# ------------------------------------------------------------------------------
# PLATFORM SCRIPTS
#
# The scripts every host runs, kept in one place. This module creates no
# resources: it only exposes the files and their checksums, so that the
# compute and database modules -- which both upload and verify them -- always
# agree on what those files are.
# ------------------------------------------------------------------------------

locals {
  deploy_lib_path    = "${path.module}/assets/deploy-lib.sh"
  fetch_scripts_path = "${path.module}/assets/fetch-scripts.sh"
}
