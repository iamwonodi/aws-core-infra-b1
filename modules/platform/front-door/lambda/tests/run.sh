#!/usr/bin/env bash
# Offline tests for the front-door function: S3 and Cognito are replaced by fakes
# that hold real state, so each test checks the sign-ins that result.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
python3 -W ignore::ResourceWarning -m unittest discover -s . -p 'test_*.py' -v
