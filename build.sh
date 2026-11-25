#!/usr/bin/env bash
# Builds everything and runs the Pascal tests: a shortcut for
#   mvn verify -Dfpc.executable=<fpc>
# The FPC compiler is taken from $FPC, or from 'fpc' on the PATH. Extra arguments go to Maven
# before the verify phase, so ./build.sh clean runs "mvn clean verify".
set -euo pipefail
cd "$(dirname "$0")"
FPC=${FPC:-$(command -v fpc || true)}
if [ -z "$FPC" ]; then
  echo "FPC not found: set FPC=/path/to/fpc (or put fpc on the PATH)." >&2
  echo "Building the Java modules only." >&2
  exec mvn -B "$@" verify
fi
exec mvn -B "$@" verify -Dfpc.executable="$FPC"
