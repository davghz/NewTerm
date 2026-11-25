#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
output=${1:-packages}
case "$output" in /*) ;; *) output="$root/$output" ;; esac
exec "$root/Independent/scripts/package.sh" production "$output"
