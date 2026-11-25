#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
exec "$root/Independent/scripts/package.sh" production "${1:-$root/packages}"
