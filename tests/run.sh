#!/bin/bash
# Unit tests.
#
# Note `geng make Main` and not `--output=...js`: the plain form produces a
# self-running executable, which is what a test runner wants.
set -e
cd "$(dirname "$0")"
geng make Main >/dev/null
exec node app "$@"
