#!/bin/bash
# =============================================================================
#  Pterodactyl entrypoint shim
# =============================================================================
#  Wings passes the egg's startup command in $STARTUP, using the panel's
#  {{VARIABLE}} placeholder syntax, and expects the image to expand and exec
#  it. This is the standard pterodactyl/yolks contract; all DCS-specific logic
#  lives in /usr/local/bin/dcs-server-run, which is what the egg's startup
#  command invokes.
# =============================================================================

cd /home/container || exit 1

# Wings resolves the allocation IP to 0.0.0.0 in some setups; surface the real
# one for scripts that care.
INTERNAL_IP=$(ip route get 1 2>/dev/null | awk '{print $(NF-2); exit}')
export INTERNAL_IP

# Convert {{VAR}} -> ${VAR} and expand against the environment.
MODIFIED_STARTUP=$(echo "${STARTUP}" | sed -e 's/{{/${/g' -e 's/}}/}/g')
MODIFIED_STARTUP=$(eval echo "\"${MODIFIED_STARTUP}\"")

echo ":/home/container$ ${MODIFIED_STARTUP}"

# shellcheck disable=SC2086
exec bash -c "${MODIFIED_STARTUP}"
