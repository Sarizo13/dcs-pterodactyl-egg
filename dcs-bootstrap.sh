#!/bin/bash
# =============================================================================
#  dcs-bootstrap — Wine prefix + DCS dedicated server install/update
# =============================================================================
#  Shared by BOTH phases:
#    * the Pterodactyl install container (DCS_BASE=/mnt/server)  — heavy work
#    * the runtime container (DCS_BASE=/home/container)          — self-heal
#                                                                 + auto-update
#
#  The Wine/DCS recipe below (DLL overrides, winetricks components, the
#  DCS_updater_initial.exe rename dance) is taken from the maintained
#  Aterfax/DCS-World-Dedicated-Server-Docker project rather than invented.
#
#  Usage: dcs-bootstrap <prefix|install|update|modules|all>
# =============================================================================
set -uo pipefail

DCS_BASE="${DCS_BASE:-/home/container}"
DCS_BRANCH="${DCS_BRANCH:-release}"          # release | openbeta
DCS_MODULES="${DCS_MODULES:-}"               # whitespace-separated module IDs
DISPLAY="${DISPLAY:-:99}"
XVFB_RES="${XVFB_RES:-1024x768x16}"
export DISPLAY

log() { echo "[dcs-bootstrap] $*"; }
die() { echo "[dcs-bootstrap] FATAL: $*" >&2; exit 1; }

# -----------------------------------------------------------------------------
#  Drop privileges when invoked as root (Pterodactyl install containers run as
#  root). This matters for more than file ownership: Wine names its per-user
#  directory after the passwd entry of the running euid, so creating the prefix
#  as root would produce drive_c/users/root while the runtime container would
#  look in drive_c/users/container — different "Saved Games", missions lost.
# -----------------------------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
    target_uid="${CONTAINER_UID:-988}"
    target_gid="${CONTAINER_GID:-$target_uid}"

    # Guarantee a passwd entry exists for that UID, otherwise Wine falls back
    # to a numeric/unknown user directory name.
    if ! getent passwd "$target_uid" >/dev/null 2>&1; then
        log "no passwd entry for uid ${target_uid}, creating one"
        getent group "$target_gid" >/dev/null 2>&1 || groupadd -g "$target_gid" container
        useradd -M -d /home/container -u "$target_uid" -g "$target_gid" -s /bin/bash container
    fi

    run_user="$(getent passwd "$target_uid" | cut -d: -f1)"
    log "running as root; handing off to ${run_user} (uid ${target_uid})"

    mkdir -p "$DCS_BASE"
    chown -R "${target_uid}:${target_gid}" "$DCS_BASE"

    exec setpriv --reuid="$target_uid" --regid="$target_gid" --init-groups \
        env HOME=/home/container USER="$run_user" \
            DCS_BASE="$DCS_BASE" DCS_BRANCH="$DCS_BRANCH" DCS_MODULES="$DCS_MODULES" \
            DISPLAY="$DISPLAY" XVFB_RES="$XVFB_RES" \
            WINEARCH="${WINEARCH:-win64}" WINEDEBUG="${WINEDEBUG:--all}" \
            WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree=d;mshtml=d}" \
            "$0" "$@"
fi

# -----------------------------------------------------------------------------
#  Paths
# -----------------------------------------------------------------------------
export WINEPREFIX="${DCS_BASE}/.wine"
export WINEARCH="${WINEARCH:-win64}"
export WINEDEBUG="${WINEDEBUG:--all}"
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree=d;mshtml=d}"

DCS_INSTALL_DIR="${WINEPREFIX}/drive_c/Program Files/Eagle Dynamics/DCS World Server"
PREFIX_MARKER="${WINEPREFIX}/.dcs-prereqs-done"

case "$DCS_BRANCH" in
    release)  DCS_VARIANT="dcs_server.release"  ;;
    openbeta) DCS_VARIANT="dcs_server.openbeta" ;;
    *) die "DCS_BRANCH must be 'release' or 'openbeta' (got '${DCS_BRANCH}')" ;;
esac

# -----------------------------------------------------------------------------
#  Xvfb
# -----------------------------------------------------------------------------
#  NON-NEGOTIABLE: DCS_updater.exe refuses to run without an X display, and
#  winetricks' vcrun2022 needs one even with --unattended. Everything below
#  runs against this virtual display.
# -----------------------------------------------------------------------------
XVFB_PID=""
start_xvfb() {
    local sock="/tmp/.X11-unix/X${DISPLAY#:}"

    if [ -S "$sock" ]; then
        log "X display ${DISPLAY} already present, reusing it"
        return 0
    fi

    log "starting Xvfb on ${DISPLAY} (${XVFB_RES})"
    Xvfb "$DISPLAY" -screen 0 "$XVFB_RES" -nolisten tcp -ac >/dev/null 2>&1 &
    XVFB_PID=$!

    # Poll for the socket instead of sleeping blind: prefix creation on a cold
    # volume is slow and racing Xvfb here is a classic source of
    # "could not open display" failures halfway through winetricks.
    for _ in $(seq 1 100); do
        [ -S "$sock" ] && { log "Xvfb ready (pid ${XVFB_PID})"; return 0; }
        kill -0 "$XVFB_PID" 2>/dev/null || die "Xvfb died during startup"
        sleep 0.2
    done
    die "Xvfb did not create ${sock} within 20s"
}

stop_xvfb() {
    [ -n "$XVFB_PID" ] && kill "$XVFB_PID" 2>/dev/null
    return 0
}

# Block until every DCS/Wine process has settled. `wine ... &` returns long
# before the Windows process is actually done, so waiting on $! is not enough.
wait_for_exe() {
    local exe="$1" label="${2:-$1}" start elapsed
    start="$(date +%s)"
    while pgrep -f "$exe" >/dev/null 2>&1; do
        elapsed=$(( $(date +%s) - start ))
        log "waiting for ${label}... ${elapsed}s elapsed"
        sleep 10
    done
}

# -----------------------------------------------------------------------------
#  Phase 1 — Wine prefix + prerequisites
# -----------------------------------------------------------------------------
do_prefix() {
    start_xvfb

    if [ -f "$PREFIX_MARKER" ]; then
        log "Wine prerequisites already installed, skipping"
        return 0
    fi

    log "initialising Wine prefix at ${WINEPREFIX} (this takes several minutes)"
    mkdir -p "$WINEPREFIX"
    wineboot --init
    wineserver -w
    log "Wine prefix created"

    # --- DLL overrides (from the aterfax recipe) -----------------------------
    # wbemprox=native            : DCS queries WMI at startup; the builtin
    #                              implementation is incomplete.
    # msvcp140_atomic_wait=n,b   : native first, builtin fallback — DCS ships
    #                              its own copy and the builtin one is missing
    #                              symbols the server binary imports.
    log "applying DLL overrides"
    wine reg add 'HKCU\Software\Wine\DllOverrides' /v wbemprox              /t REG_SZ /d 'native' /f
    wine reg add 'HKCU\Software\Wine\DllOverrides' /v msvcp140_atomic_wait  /t REG_SZ /d 'n,b'    /f

    # --- winetricks components (from the aterfax recipe) ---------------------
    # win10 sets the reported Windows version; DCS refuses older targets.
    # vcrun2022 genuinely needs a live display even with --unattended, which is
    # why start_xvfb() must have succeeded before we get here.
    log "installing Wine components via winetricks (long)"
    for verb in d3dcompiler_43 d3dx11_43 d3dcompiler_47 win10 vcrun2022; do
        log "  winetricks ${verb}"
        winetricks --unattended "$verb" || die "winetricks ${verb} failed"
    done

    wineserver -w
    touch "$PREFIX_MARKER"
    log "Wine prerequisites complete"
}

# -----------------------------------------------------------------------------
#  Phase 2 — DCS install skeleton + updater bootstrap
# -----------------------------------------------------------------------------
do_install() {
    start_xvfb

    mkdir -p "${DCS_INSTALL_DIR}/bin" "${DCS_INSTALL_DIR}/Config"

    # DCS reads these two before the updater will agree to do anything.
    [ -f "${DCS_INSTALL_DIR}/Config/lang.txt" ]  || printf 'EN' > "${DCS_INSTALL_DIR}/Config/lang.txt"
    [ -f "${DCS_INSTALL_DIR}/dcs_variant.txt" ]  || printf '%s' "$DCS_VARIANT" > "${DCS_INSTALL_DIR}/dcs_variant.txt"

    # autoupdate.cfg drives what the updater fetches.
    #   "launch": null is REQUIRED — otherwise the updater starts the server
    #   itself once it finishes, which under Pterodactyl means a stray DCS
    #   process outside the console's control.
    if [ ! -f "${DCS_INSTALL_DIR}/autoupdate.cfg" ]; then
        log "writing autoupdate.cfg (branch=${DCS_VARIANT})"
        {
            printf '{\n'
            printf '  "WARNING": "Generated by the Pterodactyl DCS egg. Edit via panel variables.",\n'
            printf '  "branch": "%s",\n' "$DCS_VARIANT"
            printf '  "arch": "x86_64",\n'
            printf '  "lang": "EN",\n'
            printf '  "modules": [\n    "WORLD"\n  ],\n'
            printf '  "launch": null\n'
            printf '}\n'
        } > "${DCS_INSTALL_DIR}/autoupdate.cfg"
    fi

    # --- fetch the updater ---------------------------------------------------
    local zip="${DCS_BASE}/DCS_updater_64bit.zip"
    local url="https://updates.digitalcombatsimulator.com/files/DCS_updater_64bit.zip"

    # Refresh if missing or older than 14 days (same policy as aterfax).
    if [ ! -f "$zip" ] || [ -n "$(find "$zip" -mtime +14 2>/dev/null)" ]; then
        log "downloading DCS updater"
        wget -qO "$zip" "$url"       || die "updater download failed"
        unzip -tq "$zip"             || die "updater zip is corrupt"
        ( cd "$DCS_BASE" && unzip -qo "$zip" ) || die "updater extraction failed"
        log "updater downloaded and extracted"
    fi

    [ -f "${DCS_BASE}/DCS_updater.exe" ] || die "DCS_updater.exe missing after extraction"

    do_update
}

# -----------------------------------------------------------------------------
#  Phase 3 — run the updater
# -----------------------------------------------------------------------------
do_update() {
    start_xvfb
    [ -d "${DCS_INSTALL_DIR}/bin" ] || die "no DCS install found at ${DCS_INSTALL_DIR}"

    # The updater updates ITSELF first, and racing its own binary makes it
    # fail. aterfax's workaround: run a copy under a different name, then
    # restore the canonical name afterwards.
    cp -f "${DCS_BASE}/DCS_updater.exe" "${DCS_INSTALL_DIR}/bin/DCS_updater_initial.exe" 2>/dev/null \
        || cp -f "${DCS_INSTALL_DIR}/bin/DCS_updater.exe" "${DCS_INSTALL_DIR}/bin/DCS_updater_initial.exe" \
        || die "cannot stage the updater binary"

    log "running DCS updater (first install downloads tens of GB — be patient)"
    ( cd "${DCS_INSTALL_DIR}/bin" && wine DCS_updater_initial.exe --quiet update & )
    sleep 5
    wait_for_exe DCS_updater_initial.exe "DCS updater"

    mv -f "${DCS_INSTALL_DIR}/bin/DCS_updater_initial.exe" "${DCS_INSTALL_DIR}/bin/DCS_updater.exe" 2>/dev/null || true

    [ -f "${DCS_INSTALL_DIR}/bin/DCS_server.exe" ] \
        || die "DCS_server.exe not present after update — see the log above. If you see 'A debugger has been found running in your system', your Wine build is a non-staging build >= 10.3; rebuild the image with wine-staging."

    log "DCS updater finished"
}

# -----------------------------------------------------------------------------
#  Phase 4 — terrain / unit modules
# -----------------------------------------------------------------------------
do_modules() {
    [ -n "${DCS_MODULES// /}" ] || { log "no extra modules requested"; return 0; }

    # Same validation as upstream: module IDs only, no shell metacharacters —
    # this string is passed to the updater as separate arguments.
    if ! [[ "$DCS_MODULES" =~ ^[A-Za-z0-9_[:space:]-]*$ ]]; then
        die "DCS_MODULES contains invalid characters: '${DCS_MODULES}'"
    fi

    start_xvfb
    log "installing modules: ${DCS_MODULES}"
    # shellcheck disable=SC2086
    ( cd "${DCS_INSTALL_DIR}/bin" && wine DCS_updater.exe install ${DCS_MODULES} & )
    sleep 5
    wait_for_exe DCS_updater.exe "module installer"
    log "module installation finished"
}

# -----------------------------------------------------------------------------
main() {
    case "${1:-all}" in
        prefix)  do_prefix ;;
        install) do_prefix; do_install; do_modules ;;
        update)  do_update ;;
        modules) do_modules ;;
        all)     do_prefix; do_install; do_modules ;;
        *) die "unknown action '${1}' (prefix|install|update|modules|all)" ;;
    esac
}

trap stop_xvfb EXIT
main "$@"
log "done."
