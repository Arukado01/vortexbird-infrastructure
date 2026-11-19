#!/bin/bash
set -euo pipefail

fail() { printf '%s\n' "$1" >&2; exit 64; }
required() { [[ -n "${!1:-}" ]] || fail "$1 is required; values are never logged."; }
expect_value() { [[ "${!1:-}" == "$2" ]] || fail "$1 does not match the reviewed production setting."; }
https_origin() {
  local value="${!1:-}"
  local pattern='^https://([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z][A-Za-z0-9-]{0,62}(:[0-9]{1,5})?$'
  [[ "$value" =~ $pattern ]] || fail "$1 must be an exact HTTPS DNS origin without path, wildcard, query or credentials."
  local authority="${value#https://}"
  if [[ "$authority" == *:* ]]; then
    local port="${authority##*:}"
    (( 10#$port >= 1 && 10#$port <= 65535 )) || fail "$1 has an invalid port."
  fi
}

for name in VORTEXBIRD_PORTAL_ORIGIN KC_HOSTNAME KC_DB_URL KC_DB_USERNAME KC_DB_PASSWORD KC_PROXY_TRUSTED_ADDRESSES; do
  required "$name"
done
https_origin VORTEXBIRD_PORTAL_ORIGIN
if [[ "$KC_HOSTNAME" != "$VORTEXBIRD_PORTAL_ORIGIN/auth" ]]; then
  https_origin KC_HOSTNAME
  portal_origin="${VORTEXBIRD_PORTAL_ORIGIN,,}"
  identity_origin="${KC_HOSTNAME,,}"
  [[ "${portal_origin%:443}" != "${identity_origin%:443}" ]] || fail 'Identity on the portal origin must use its exact /auth URL.'
fi
# The shared listener removes /auth before forwarding. Both image modes serve at /.
[[ "${KC_HTTP_RELATIVE_PATH:-/}" == / && "${KC_HTTP_MANAGEMENT_RELATIVE_PATH:-/}" == / ]] || fail 'Internal Keycloak HTTP and management paths must be root.'

expect_value KC_DB postgres
expect_value KC_DB_SCHEMA keycloak
expect_value KC_HEALTH_ENABLED true
expect_value KC_METRICS_ENABLED true
expect_value KC_HOSTNAME_STRICT true
expect_value KC_HTTP_ENABLED true
expect_value KC_HTTP_MANAGEMENT_PORT 9000
expect_value KC_HTTP_MANAGEMENT_SCHEME http
expect_value KC_PROXY_HEADERS xforwarded
expect_value KC_CACHE ispn
expect_value KC_CACHE_STACK jdbc-ping

# Require the exact JDBC contract. Reject duplicate parameters that could weaken TLS.
jdbc_pattern='^jdbc:postgresql://[A-Za-z0-9.-]+:5432/keycloak\?sslmode=verify-full&sslrootcert=/opt/keycloak/conf/rds-ca-bundle.pem$'
[[ "$KC_DB_URL" =~ $jdbc_pattern ]] || fail 'KC_DB_URL must use PostgreSQL keycloak with verify-full and the bundled RDS CA.'
[[ -s /opt/keycloak/conf/rds-ca-bundle.pem ]] || fail 'The reviewed RDS CA bundle is missing.'

# The ECS contract supplies only the two IPv4 ALB subnet CIDRs.
IFS=',' read -ra networks <<< "$KC_PROXY_TRUSTED_ADDRESSES"
[[ ${#networks[@]} -gt 0 ]] || fail 'Trusted proxy CIDRs are required.'
for network in "${networks[@]}"; do
  [[ "$network" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]{1,2})$ ]] || fail 'Trusted proxy addresses must be explicit IPv4 subnet CIDRs.'
  mask="${network##*/}"
  (( 10#$mask >= 1 && 10#$mask <= 32 )) || fail 'An unrestricted trusted proxy range is forbidden.'
  address="${network%/*}"
  IFS='.' read -ra octets <<< "$address"
  for octet in "${octets[@]}"; do (( 10#$octet <= 255 )) || fail 'Invalid trusted proxy CIDR.'; done
done

if [[ -n "${KC_BOOTSTRAP_ADMIN_USERNAME:-}" || -n "${KC_BOOTSTRAP_ADMIN_PASSWORD:-}" ]]; then
  required KC_BOOTSTRAP_ADMIN_USERNAME
  required KC_BOOTSTRAP_ADMIN_PASSWORD
  [[ ${#KC_BOOTSTRAP_ADMIN_PASSWORD} -ge 16 ]] || fail 'Bootstrap administrator password must have at least 16 characters.'
fi
