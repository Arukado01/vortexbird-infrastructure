#!/bin/bash
set -euo pipefail

if [[ $# -ne 3 || "$1" != start || "$2" != --optimized || "$3" != --import-realm ]]; then
  printf '%s\n' 'Only start --optimized --import-realm is allowed by this production image.' >&2
  exit 64
fi

/opt/keycloak/bin/validate-runtime.sh
exec /opt/keycloak/bin/kc.sh "$@"
