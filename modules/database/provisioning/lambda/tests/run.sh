#!/usr/bin/env bash
# Offline tests for the provisioning Lambda. No AWS, no database: boto3 is stubbed
# and the connection is replaced, so what is proven is the function's own logic --
# which statements it runs, in which database, and everything it refuses.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
python3 -W ignore::ResourceWarning -m unittest discover -s . -p 'test_*.py' -v
