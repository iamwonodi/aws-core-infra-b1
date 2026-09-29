# ------------------------------------------------------------------------------
# DNS DELEGATION
#
# A Route 53 reusable delegation set: four name servers that every public zone
# created with it answers on. The domain's delegation (the NS records at the
# registrar, set by hand) points at these, so a public zone destroyed and
# rebuilt keeps the same name servers and the delegation keeps working. Without
# it, every rebuilt zone gets new ones, and the apply hangs on certificates that
# cannot validate until someone updates the registrar.
#
# The destroy workflow keeps this module, as it keeps CI's own role
# (scripts/ci/resolve-destroy-targets.sh). It must depend on nothing the destroy
# removes; scripts/ci/check-environment-wiring.py fails CI if it ever does.
# Retiring an environment removes it from a laptop (docs/runbook.md).
# ------------------------------------------------------------------------------

resource "aws_route53_delegation_set" "this" {
  reference_name = "${var.project_name}-${var.environment}-public"
}
