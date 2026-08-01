#!/bin/bash
# =============================================================================
#  Pterodactyl install script — DCS World Dedicated Server
# =============================================================================
#  Runs in the INSTALL container (not the game container):
#    * image      : the same DCS image (it is the only one that has Wine)
#    * user       : root
#    * server vol : /mnt/server
#
#  Everything slow and fragile happens here, on purpose:
#  Wine prefix creation, winetricks, and the multi-tens-of-GB DCS download.
#  The runtime container then only has to start DCS_server.exe.
#
#  EXPECT THIS TO RUN FOR A LONG TIME. A first install with one terrain is
#  routinely 60–120+ minutes depending on your link. Do not cancel it; the
#  panel install log is the place to watch progress.
# =============================================================================
set -uo pipefail

echo "================================================================"
echo " DCS World Dedicated Server — Pterodactyl install"
echo " Wine:     $(wine --version 2>/dev/null || echo 'NOT FOUND')"
echo " Wine pin: $(cat /etc/dcs-wine-pin 2>/dev/null || echo 'unknown')"
echo " Branch:   ${DCS_BRANCH:-release}"
echo " Modules:  ${DCS_MODULES:-<none>}"
echo "================================================================"

if [ ! -x /usr/local/bin/dcs-bootstrap ]; then
    echo "FATAL: /usr/local/bin/dcs-bootstrap is missing."
    echo "The install container MUST use the DCS egg image — it is the only"
    echo "one that ships Wine and the bootstrap logic. Check the egg's"
    echo "Install Container setting."
    exit 1
fi

export DCS_BASE=/mnt/server
mkdir -p "$DCS_BASE"

# --- optional clean reinstall ------------------------------------------------
# Deliberately narrow: it removes the Wine prefix (which contains the DCS
# install AND the Saved Games write directory). Missions and network.vault live
# in there, so this is destructive. It only fires when explicitly requested.
if [ "${FORCE_REINSTALL:-0}" = "1" ]; then
    echo "FORCE_REINSTALL=1 — removing the existing Wine prefix and DCS install."
    echo "This deletes missions and Config/network.vault. Back them up first if"
    echo "you did not mean to do this."
    rm -rf "${DCS_BASE}/.wine" "${DCS_BASE}/DCS_updater.exe" "${DCS_BASE}/DCS_updater_64bit.zip"
fi

# dcs-bootstrap drops from root to the container UID before touching Wine, so
# the prefix is owned by — and named after — the user that will run the server.
DCS_BASE="$DCS_BASE" \
DCS_BRANCH="${DCS_BRANCH:-release}" \
DCS_MODULES="${DCS_MODULES:-}" \
CONTAINER_UID="${CONTAINER_UID:-988}" \
CONTAINER_GID="${CONTAINER_GID:-988}" \
    /usr/local/bin/dcs-bootstrap install
RC=$?

if [ "$RC" -ne 0 ]; then
    echo "----------------------------------------------------------------"
    echo "INSTALL FAILED (exit ${RC})."
    echo "Common causes:"
    echo "  * 'A debugger has been found running in your system'"
    echo "      -> the image was built with a non-staging Wine >= 10.3."
    echo "         Rebuild with wine-staging (see the Dockerfile header)."
    echo "  * out of disk space — DCS plus one terrain needs ~120 GB free."
    echo "  * the updater could not reach updates.digitalcombatsimulator.com."
    echo "----------------------------------------------------------------"
    exit "$RC"
fi

# Re-assert ownership: the updater creates a deep tree and Wings will run the
# game container as CONTAINER_UID.
chown -R "${CONTAINER_UID:-988}:${CONTAINER_GID:-988}" "$DCS_BASE" 2>/dev/null || true

echo "================================================================"
echo " Install complete."
echo ""
echo " NEXT STEP — you are not done yet:"
echo " DCS will not serve players until Config/network.vault exists, and"
echo " that file can only be produced by logging into your Eagle Dynamics"
echo " account once, interactively. Set VNC_ENABLED=1, start the server,"
echo " connect over VNC and log in with 'save credentials' ticked."
echo " Full walkthrough in README-egg.md."
echo "================================================================"
exit 0
