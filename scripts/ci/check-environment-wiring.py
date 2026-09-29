#!/usr/bin/env python3
"""Fail if an environment is wired so that a rebuild from nothing breaks.

Two checks, each a failure a rebuild of development actually hit:

image-egress
    The golden image build downloads Image Builder's own bootstrap the moment
    its build instance starts, through the NAT. If it takes a plain subnet ID,
    Terraform can start it before the NAT, the route tables, the NACLs or the
    tier's outbound rule exist, and the build fails. The network module's
    internal_egress_subnet_ids output waits for all of them (depends_on on the
    output, not on a module, so no data source is held back and nothing is
    replaced by it); every image build must take its subnet from there.

kept-delegation
    A destroyed and rebuilt public zone gets new name servers, and the domain's
    delegation, set by hand at the registrar, then points at nothing: the
    certificates never validate and the apply hangs. The public zone must use a
    reusable delegation set from a module the destroy keeps
    (scripts/ci/resolve-destroy-targets.sh, KEPT_MODULES), and the kept modules
    must depend only on each other, or destroying something else would take
    them with it.

Usage: check-environment-wiring.py <environment-dir>...
Needs: pip install python-hcl2
"""
import os
import re
import sys

import hcl2

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RESOLVER = os.path.join(ROOT, "scripts", "ci", "resolve-destroy-targets.sh")
NETWORK_OUTPUTS = os.path.join(ROOT, "modules", "network", "outputs.tf")
COMPUTE_MAIN = os.path.join(ROOT, "modules", "compute", "main.tf")

EGRESS_OUTPUT = "internal_egress_subnet_ids"
# What the route out is made of; the output must wait for every one of them.
EGRESS_PARTS = {"nat_gateway", "nat_instance", "route_tables", "nacl_security", "global_outbound_routing"}


def load_modules(directory):
    modules = {}
    for name in sorted(os.listdir(directory)):
        if name.endswith(".tf"):
            with open(os.path.join(directory, name)) as handle:
                for block in hcl2.load(handle).get("module", []):
                    for module_name, body in block.items():
                        modules[module_name.strip('"')] = body
    return modules


def kept_modules():
    with open(RESOLVER) as handle:
        match = re.search(r"^KEPT_MODULES=\(([^)]*)\)", handle.read(), re.M)
    return set(re.findall(r'"([^"]+)"', match.group(1))) if match else set()


def egress_output_waits():
    with open(NETWORK_OUTPUTS) as handle:
        for block in hcl2.load(handle).get("output", []):
            for name, body in block.items():
                if name.strip('"') == EGRESS_OUTPUT:
                    return set(re.findall(r"\bmodule\.(\w+)", str(body.get("depends_on", []))))
    return None


def check_network(failures):
    waits = egress_output_waits()
    if waits is None:
        failures.append(f"modules/network: no output {EGRESS_OUTPUT}")
    elif EGRESS_PARTS - waits:
        failures.append(f"modules/network: {EGRESS_OUTPUT} does not wait for {sorted(EGRESS_PARTS - waits)}")

    with open(COMPUTE_MAIN) as handle:
        compute = {n.strip('"'): b for blk in hcl2.load(handle).get("module", []) for n, b in blk.items()}
    image = compute.get("image", {})
    if "var.image_subnet_id" not in str(image.get("subnet_id", "")):
        failures.append("modules/compute: the image build's subnet_id is not var.image_subnet_id")


def check_environment(directory, kept, failures):
    modules = load_modules(directory)
    env = os.path.basename(os.path.normpath(directory))

    # image-egress: whichever way the environment builds its image.
    for name, body in modules.items():
        source = str(body.get("source", "")).strip('"')
        if source.endswith("modules/compute/image"):
            argument = str(body.get("subnet_id", ""))
        elif source.endswith("modules/compute"):
            argument = str(body.get("image_subnet_id", ""))
        else:
            continue
        if f"module.network.{EGRESS_OUTPUT}" not in argument:
            failures.append(f"{env}: module.{name}'s image build subnet is not module.network.{EGRESS_OUTPUT}")

    # kept-delegation
    edge = modules.get("edge")
    if edge is not None:
        refs = set(re.findall(r"\bmodule\.(\w+)", str(edge.get("public_delegation_set_id", ""))))
        if not refs or not refs <= kept:
            failures.append(f"{env}: the public zone's delegation set does not come from a kept module {sorted(kept)}")

    for name in sorted(kept):
        if name not in modules:
            continue
        body = {k: v for k, v in modules[name].items() if k != "source"}
        others = set(re.findall(r"\bmodule\.(\w+)", str(body))) - kept
        if others:
            failures.append(f"{env}: kept module.{name} depends on {sorted(others)}, which the destroy removes")


def main(directories):
    failures = []
    kept = kept_modules()
    if not kept:
        failures.append(f"could not read KEPT_MODULES from {RESOLVER}")
    check_network(failures)
    for directory in directories:
        check_environment(directory, kept, failures)

    for failure in failures:
        print(f"FAIL {failure}")
    if not failures:
        print(f"ok   every image build waits for its route out; the public zones use a kept delegation set ({', '.join(directories)})")
    return 1 if failures else 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1:]))
