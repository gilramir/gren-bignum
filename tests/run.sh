#!/bin/bash
# Unit tests.
#
# Note `gren make Main` and not `--output=...js`: the plain form produces a
# self-running executable, which is what a test runner wants.
set -e
cd "$(dirname "$0")"
gren make Main >/dev/null
exec node app "$@"
