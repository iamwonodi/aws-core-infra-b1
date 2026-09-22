#!/usr/bin/env python3
"""Fail if module.github_oidc depends on anything that needs the rest of the environment.

scripts/bootstrap-environment.sh applies module.github_oidc alone (terraform
apply -target=module.github_oidc) to create the first role before any other
infrastructure exists. Terraform pulls in everything a targeted module depends
on, so if github_oidc ever gained a reference to the network, the fleets or the
buckets, that first apply would try to build all of them -- with credentials that
have not been reviewed yet.

Allowed dependencies are variables, locals built only from variables and other
allowed modules, and the pure github_identity module.

Usage: check-bootstrap-closure.py <environment-dir>...
Needs: pip install python-hcl2
"""
import os
import re
import sys

import hcl2

ALLOWED_MODULES = {"github_identity"}
TARGET = "github_oidc"


def load(directory):
    modules, local_exprs = {}, {}
    for name in sorted(os.listdir(directory)):
        if not name.endswith(".tf"):
            continue
        with open(os.path.join(directory, name)) as handle:
            doc = hcl2.load(handle)
        for block in doc.get("module", []):
            for module_name, body in block.items():
                modules[module_name.strip('"')] = body
        for block in doc.get("locals", []):
            for key, value in block.items():
                if not key.startswith("__"):
                    local_exprs[key] = str(value)
    return modules, local_exprs


def closure(directory):
    modules, local_exprs = load(directory)
    if TARGET not in modules:
        return None, set()

    seen_locals, found = set(), set()
    pending = [str(modules[TARGET])]
    while pending:
        text = pending.pop()
        found.update(re.findall(r"\bmodule\.(\w+)", text))
        for local in re.findall(r"\blocal\.(\w+)", text):
            if local not in seen_locals and local in local_exprs:
                seen_locals.add(local)
                pending.append(local_exprs[local])
    # Expand module-to-module references one level at a time.
    changed = True
    while changed:
        changed = False
        for module_name in list(found):
            if module_name in modules:
                for other in re.findall(r"\bmodule\.(\w+)", str(modules[module_name])):
                    if other not in found:
                        found.add(other)
                        changed = True
    return modules, found


def main(directories):
    failed = False
    for directory in directories:
        modules, deps = closure(directory)
        if modules is None:
            print(f"ok   {directory} (no module.{TARGET})")
            continue
        extra = deps - ALLOWED_MODULES
        if extra:
            failed = True
            print(f"FAIL {directory}: module.{TARGET} depends on {sorted(extra)}")
            print("     The bootstrap apply (-target=module.github_oidc) would build these too.")
        else:
            print(f"ok   {directory}: module.{TARGET} depends only on {sorted(deps) or 'variables'}")
    return 1 if failed else 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1:]))
