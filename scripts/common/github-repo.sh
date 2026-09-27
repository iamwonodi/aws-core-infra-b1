# shellcheck shell=bash
# ==============================================================================
# THE GITHUB REPOSITORY A CLONE BELONGS TO
#
# Sourced by the workstation scripts. The repository is always the one named by
# the "origin" remote, and every gh call that writes to it names it with --repo.
#
# Why not let gh work it out: gh picks a repository from the clone's remotes and
# prefers one called "upstream". A product's clone of this blueprint keeps the
# blueprint as "upstream", so an unnamed "gh variable set" or "gh secret set"
# would go to the blueprint instead of the product.
# ==============================================================================

# origin_repository DIR
#   Prints OWNER/REPOSITORY for DIR's origin remote (https, ssh or scp form,
#   with or without .git). Returns 1, printing nothing, when there is none.
origin_repository() {
  local url
  url="$(git -C "$1" remote get-url origin 2>/dev/null)" || return 1
  [[ -n "${url}" ]] || return 1
  sed -E 's#^(https?://[^/]+/|git@[^:]+:|ssh://[^/]+/)##; s#\.git$##; s#/$##' <<< "${url}"
}
