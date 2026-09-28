#!/usr/bin/env python3
"""Fail if a module that owns the database's data volume is given depends_on.

terraform-aws-compute-storage creates the database host and its data volume.
The volume takes its availability zone from a subnet lookup inside that module.
A module-level depends_on holds back every data source in the module until
everything it names has no pending change: a change to the scripts manifest, a
script object or the deploy bucket then leaves the zone unknown at plan time,
and Terraform replaces the volume, with every engine's data on it.

Ordering the host after something belongs in a value the host's own resources
read (modules/database/host passes the manifest's name into the start-up
script), never in depends_on.

Usage: check-host-dependencies.py <directory>...   (searched recursively)
Needs: pip install python-hcl2
"""
import os
import sys

import hcl2

GUARDED_SOURCE = "terraform-aws-compute-storage"


def module_blocks(path):
    with open(path) as handle:
        doc = hcl2.load(handle)
    for block in doc.get("module", []):
        for name, body in block.items():
            yield name.strip('"'), body


def main(directories):
    if not directories:
        print(__doc__.strip().splitlines()[-2], file=sys.stderr)
        return 2

    failures, checked = 0, 0
    for directory in directories:
        for root, dirs, files in os.walk(directory):
            dirs[:] = [d for d in dirs if d != ".terraform"]
            for name in sorted(files):
                if not name.endswith(".tf"):
                    continue
                path = os.path.join(root, name)
                for module, body in module_blocks(path):
                    if GUARDED_SOURCE not in str(body.get("source", "")):
                        continue
                    checked += 1
                    if "depends_on" in body:
                        failures += 1
                        print(f"FAIL {path}: module.{module} ({GUARDED_SOURCE}) has depends_on, "
                              "which defers its subnet lookup and can replace the data volume")
                    else:
                        print(f"ok   {path}: module.{module} has no depends_on")

    if checked == 0:
        print(f"FAIL no module using {GUARDED_SOURCE} found under {' '.join(directories)}")
        return 1
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
