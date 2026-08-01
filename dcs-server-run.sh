#!/bin/bash
# =============================================================================
#  dcs-server-run — runtime launcher for the DCS World dedicated server
# =============================================================================
#  Invoked by the egg's startup command (through /entrypoint.sh).
#
#  Responsibilities, in order:
#    1. start Xvfb (DCS and its updater both require an X display)
#    2. self-heal the install if the panel's install phase was skipped
#    3. expose a stable, documented SFTP path for missions
#    4. reconcile serverSettings.lua with the panel variables
#    5. optionally auto-update DCS
#    6. launch DCS_server.exe, stream its log to the console
#    7. emit a deterministic readiness sentinel for Wings
#    8. shut down cleanly on SIGINT/SIGTERM
# =============================================================================
set -uo pipefail

DCS_BASE="/home/container"
export DCS_BASE

# --- panel-provided variables (with safe fallbacks) --------------------------
DCS_BRANCH="${DCS_BRANCH:-release}"
DCS_WRITE_DIR="${DCS_WRITE_DIR:-DCS.server}"
DCS_SERVER_NAME="${DCS_SERVER_NAME:-DCS Server}"
DCS_SERVER_PASSWORD="${DCS_SERVER_PASSWORD:-}"
DCS_MAX_PLAYERS="${DCS_MAX_PLAYERS:-16}"
DCS_MISSION="${DCS_MISSION:-}"
DCS_AUTO_UPDATE="${DCS_AUTO_UPDATE:-0}"
DCS_MANAGE_SETTINGS="${DCS_MANAGE_SETTINGS:-1}"
DCS_WEBGUI_PORT="${DCS_WEBGUI_PORT:-8088}"
DCS_STOP_TIMEOUT="${DCS_STOP_TIMEOUT:-90}"
DCS_READY_REGEX="${DCS_READY_REGEX:-}"
VNC_ENABLED="${VNC_ENABLED:-0}"
VNC_PORT="${VNC_PORT:-5900}"
VNC_PASSWORD="${VNC_PASSWORD:-}"
SERVER_PORT="${SERVER_PORT:-10308}"

DISPLAY="${DISPLAY:-:99}"
XVFB_RES="${XVFB_RES:-1024x768x16}"
export DISPLAY

export WINEPREFIX="${DCS_BASE}/.wine"
export WINEARCH="${WINEARCH:-win64}"
export WINEDEBUG="${WINEDEBUG:--all}"

DCS_INSTALL_DIR="${WINEPREFIX}/drive_c/Program Files/Eagle Dynamics/DCS World Server"
DCS_SERVER_EXE="${DCS_INSTALL_DIR}/bin/DCS_server.exe"

log() { echo "[dcs] $*"; }
warn() { echo "[dcs] WARNING: $*"; }

# =============================================================================
#  Banner
# =============================================================================
log "=============================================================="
log " DCS World Dedicated Server — Pterodactyl egg"
log " Wine:        $(wine --version 2>/dev/null || echo 'NOT FOUND')"
log " Wine pin:    $(cat /etc/dcs-wine-pin 2>/dev/null || echo 'unknown')"
log " Branch:      ${DCS_BRANCH}"
log " Write dir:   ${DCS_WRITE_DIR}"
log " Game port:   ${SERVER_PORT} (TCP+UDP)"
log "=============================================================="

# The updater bug is silent until it bites, so make the branch obvious at boot.
case "$(cat /etc/dcs-wine-pin 2>/dev/null)" in
    *staging*) : ;;
    *) warn "this image was NOT built with wine-staging. DCS_updater.exe is known to fail on WineHQ standard builds >= 10.3 ('A debugger has been found running in your system'). Updates will likely break." ;;
esac

# =============================================================================
#  Xvfb — mandatory
# =============================================================================
XVFB_PID=""

start_xvfb() {
    local sock="/tmp/.X11-unix/X${DISPLAY#:}"
    [ -S "$sock" ] && { log "reusing existing X display ${DISPLAY}"; return 0; }

    log "starting Xvfb on ${DISPLAY} (${XVFB_RES})"
    Xvfb "$DISPLAY" -screen 0 "$XVFB_RES" -nolisten tcp -ac >/dev/null 2>&1 &
    XVFB_PID=$!

    for _ in $(seq 1 100); do
        [ -S "$sock" ] && { log "Xvfb ready (pid ${XVFB_PID})"; return 0; }
        kill -0 "$XVFB_PID" 2>/dev/null || { warn "Xvfb died on startup"; return 1; }
        sleep 0.2
    done
    warn "Xvfb did not come up within 20s — DCS will not start"
    return 1
}

start_xvfb || exit 1

# =============================================================================
#  Optional VNC — used ONCE to log into your Eagle Dynamics account
# =============================================================================
#  DCS_server.exe will not accept players until Config/network.vault exists in
#  the write directory, and that file can only be produced by logging in
#  through the DCS UI with "save credentials" ticked. There is no documented
#  non-interactive login flag, so rather than pretend otherwise this egg gives
#  you a temporary window onto the same Xvfb display. See README-egg.md.
# =============================================================================
if [ "$VNC_ENABLED" = "1" ]; then
    vnc_args=(-display "$DISPLAY" -forever -shared -rfbport "$VNC_PORT" -bg -quiet)
    if [ -n "$VNC_PASSWORD" ]; then
        mkdir -p "${DCS_BASE}/.vnc"
        x11vnc -storepasswd "$VNC_PASSWORD" "${DCS_BASE}/.vnc/passwd" >/dev/null 2>&1
        vnc_args+=(-rfbauth "${DCS_BASE}/.vnc/passwd")
    else
        warn "VNC enabled with NO password — anyone who can reach port ${VNC_PORT} controls this server. Set a password or disable VNC once network.vault exists."
        vnc_args+=(-nopw)
    fi
    log "starting x11vnc on port ${VNC_PORT}"
    x11vnc "${vnc_args[@]}" >/dev/null 2>&1
fi

# =============================================================================
#  Self-heal — only fires if the panel install phase never ran or failed
# =============================================================================
if [ ! -f "$DCS_SERVER_EXE" ]; then
    warn "DCS_server.exe not found at ${DCS_SERVER_EXE}"
    warn "running the bootstrap now. This is the SLOW path (tens of GB) and it"
    warn "belongs in the install phase — check the panel's install log to see"
    warn "why it did not complete."
    DCS_BASE="$DCS_BASE" DCS_BRANCH="$DCS_BRANCH" DCS_MODULES="${DCS_MODULES:-}" \
        /usr/local/bin/dcs-bootstrap all || exit 1
fi

# =============================================================================
#  Resolve the Wine user directory and publish a stable path
# =============================================================================
#  Wine names this directory after the passwd entry of the running UID. If your
#  wings `system.user.uid` is not the UID baked into the image, that name
#  changes. Resolving it dynamically (and symlinking it to a fixed location)
#  means the SFTP path documented in the README stays correct either way.
# =============================================================================
WINE_USER_DIR="$(find "${WINEPREFIX}/drive_c/users" -maxdepth 1 -mindepth 1 -type d \
                    ! -name Public 2>/dev/null | head -n1)"

if [ -z "$WINE_USER_DIR" ]; then
    warn "could not locate the Wine user directory under ${WINEPREFIX}/drive_c/users"
    exit 1
fi
log "wine user dir: ${WINE_USER_DIR}"

SAVED_GAMES="${WINE_USER_DIR}/Saved Games"
WRITE_DIR="${SAVED_GAMES}/${DCS_WRITE_DIR}"
mkdir -p "${WRITE_DIR}/Missions" "${WRITE_DIR}/Config" "${WRITE_DIR}/Logs"

# Stable, short, SFTP-friendly alias. This is the path documented to users.
ln -sfn "$SAVED_GAMES" "${DCS_BASE}/saved-games"
log "missions path (SFTP): saved-games/${DCS_WRITE_DIR}/Missions"

# =============================================================================
#  network.vault — Eagle Dynamics credentials
# =============================================================================
if [ ! -f "${WRITE_DIR}/Config/network.vault" ]; then
    warn "=========================================================="
    warn " Config/network.vault is MISSING."
    warn " The server cannot authenticate against Eagle Dynamics and"
    warn " will not appear in the server list until you log in once."
    warn " Set VNC_ENABLED=1, connect, log in with 'save credentials'."
    warn " See README-egg.md, section 'Compte ED / network.vault'."
    warn "=========================================================="
fi

# =============================================================================
#  serverSettings.lua
# =============================================================================
SETTINGS="${WRITE_DIR}/Config/serverSettings.lua"

# Escape a value for embedding in a Lua double-quoted string literal.
lua_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

# Replace the value of a single ["key"] = <value>, entry in place.
#
# Deliberately NOT sed: the replacement side of `s///` treats & and \ as
# metacharacters and / as the delimiter, so a server name like "A & B" or a
# password containing a slash would corrupt the file. Passing key and value
# through the environment into awk keeps them literal. Only the FIRST match is
# rewritten, and the pattern is line-anchored so ["port"] does not also hit
# ["webgui_port"].
lua_set() {
    local key="$1" value="$2" file="$3"
    LUA_KEY="$key" LUA_VAL="$value" awk '
        BEGIN { key = ENVIRON["LUA_KEY"]; val = ENVIRON["LUA_VAL"]; done = 0 }
        {
            if (!done) {
                pat = "^[ \t]*\\[\"" key "\"\\][ \t]*=[ \t]*"
                if (match($0, pat)) {
                    printf "%s%s,\n", substr($0, RSTART, RLENGTH), val
                    done = 1
                    next
                }
            }
            print
        }
    ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

if [ ! -f "$SETTINGS" ]; then
    log "creating serverSettings.lua"
    cat > "$SETTINGS" <<EOF
cfg =
{
    ["description"] = "",
    ["require_pure_clients"] = false,
    ["listStartIndex"] = 1,
    ["advanced"] =
    {
        ["allow_change_skin"] = true,
        ["allow_change_tailno"] = true,
        ["allow_dynamic_radio"] = false,
        ["allow_export_own_ship"] = true,
        ["allow_object_export"] = false,
        ["allow_ownship_export"] = true,
        ["allow_players_pool"] = false,
        ["allow_sensor_export"] = true,
        ["allow_trial_only_clients"] = false,
        ["disable_events"] = false,
        ["event_Connect"] = true,
        ["event_Crash"] = true,
        ["event_Ejecting"] = true,
        ["event_Kill"] = true,
        ["event_Role"] = true,
        ["event_Takeoff"] = true,
        ["maxPing"] = 0,
        ["pause_on_load"] = false,
        ["pause_without_clients"] = false,
        ["resume_mode"] = 1,
        ["server_can_screenshot"] = false,
        ["voice_chat_server"] = false,
        ["webgui_port"] = ${DCS_WEBGUI_PORT},
    },
    ["port"] = ${SERVER_PORT},
    ["mode"] = 1,
    ["name"] = "$(lua_escape "$DCS_SERVER_NAME")",
    ["password"] = "$(lua_escape "$DCS_SERVER_PASSWORD")",
    ["maxPlayers"] = ${DCS_MAX_PLAYERS},
    ["listShuffle"] = false,
    ["listLoop"] = false,
    ["isPublic"] = true,
    ["bind_address"] = "",
    ["use_private_channel"] = false,
    ["missionList"] =
    {
    },
}
EOF
elif [ "$DCS_MANAGE_SETTINGS" = "1" ]; then
    # DCS rewrites this file on exit, so panel-managed keys are re-applied on
    # every boot. Only the keys below are touched; everything you change in the
    # WebGUI survives.
    log "reconciling serverSettings.lua with panel variables"
    lua_set "port"        "${SERVER_PORT}"                                 "$SETTINGS"
    lua_set "maxPlayers"  "${DCS_MAX_PLAYERS}"                             "$SETTINGS"
    lua_set "webgui_port" "${DCS_WEBGUI_PORT}"                             "$SETTINGS"
    lua_set "name"        "\"$(lua_escape "$DCS_SERVER_NAME")\""           "$SETTINGS"
    lua_set "password"    "\"$(lua_escape "$DCS_SERVER_PASSWORD")\""       "$SETTINGS"
else
    log "DCS_MANAGE_SETTINGS=0 — leaving serverSettings.lua untouched"
fi

# --- mission selection -------------------------------------------------------
if [ -n "$DCS_MISSION" ]; then
    MISSION_UNIX="${WRITE_DIR}/Missions/${DCS_MISSION}"
    if [ ! -f "$MISSION_UNIX" ]; then
        warn "mission '${DCS_MISSION}' not found in ${WRITE_DIR}/Missions — ignoring"
    else
        # DCS stores Windows paths; winepath does the conversion authoritatively
        # instead of us hand-building a C:\ path.
        MISSION_WIN="$(winepath -w "$MISSION_UNIX" 2>/dev/null)"
        MISSION_LUA="$(printf '%s' "$MISSION_WIN" | sed -e 's/\\/\\\\/g')"
        log "setting startup mission: ${DCS_MISSION}"

        NEWBLOCK=$(printf '    ["missionList"] =\n    {\n        [1] = "%s",\n    },' "$MISSION_LUA")

        # Replace the whole ["missionList"] = { ... } table by brace matching.
        # `started` guards the case where the opening brace is on a later line.
        #
        # The block is passed through the ENVIRONMENT, not through `awk -v`:
        # -v assignments undergo escape processing, which would collapse the
        # "\\" pairs we just built back into single backslashes and emit
        # garbage like \u / \S / \D into the Lua file. ENVIRON is taken
        # verbatim.
        NEWBLOCK="$NEWBLOCK" awk '
            {
                if (!inblock && $0 ~ /\["missionList"\][ \t]*=/) {
                    inblock = 1; started = 0; depth = 0
                    print ENVIRON["NEWBLOCK"]
                }
                if (inblock) {
                    o = gsub(/\{/, "{"); c = gsub(/\}/, "}")
                    if (o > 0) started = 1
                    depth += o - c
                    if (started && depth <= 0) inblock = 0
                    next
                }
                print
            }
        ' "$SETTINGS" > "${SETTINGS}.tmp" && mv "${SETTINGS}.tmp" "$SETTINGS"
    fi
fi

# =============================================================================
#  Optional auto-update
# =============================================================================
#  Default OFF on purpose: a DCS update can take hours and can break a working
#  install, and you do not want to discover that during a scheduled boot.
# =============================================================================
if [ "$DCS_AUTO_UPDATE" = "1" ]; then
    log "DCS_AUTO_UPDATE=1 — running the updater before launch"
    DCS_BASE="$DCS_BASE" DCS_BRANCH="$DCS_BRANCH" /usr/local/bin/dcs-bootstrap update \
        || warn "update failed; starting the existing install anyway"
fi

# =============================================================================
#  Launch
# =============================================================================
DCS_LOG="${WRITE_DIR}/Logs/dcs.log"

# Truncate so the readiness probe and the console only see this run.
: > "$DCS_LOG" 2>/dev/null || true

log "starting DCS_server.exe (write dir: ${DCS_WRITE_DIR})"
wine "$DCS_SERVER_EXE" -w "$DCS_WRITE_DIR" >/dev/null 2>&1 &
WINE_PID=$!
log "wine pid: ${WINE_PID}"

# DCS writes to Logs/dcs.log, not to stdout. Wings only ever sees stdout, so
# without this tail the console stays empty and no log-based detection works.
tail -F "$DCS_LOG" 2>/dev/null &
TAIL_PID=$!

# =============================================================================
#  Readiness sentinel
# =============================================================================
#  Rather than make Wings match a DCS log line whose exact wording changes
#  between versions, we detect readiness here and print ONE line that the egg
#  matches verbatim. The probe succeeds on either signal:
#    * the game port is actually bound (authoritative), or
#    * DCS_READY_REGEX matches in dcs.log (optional, user-tunable)
# =============================================================================
READY_SENTINEL=">>> DCS SERVER READY <<<"
(
    waited=0
    while kill -0 "$WINE_PID" 2>/dev/null; do
        if ss -lun 2>/dev/null | grep -qE "[:.]${SERVER_PORT}([[:space:]]|$)" \
        || ss -ltn 2>/dev/null | grep -qE "[:.]${SERVER_PORT}([[:space:]]|$)"; then
            echo "[dcs] game port ${SERVER_PORT} is bound"
            echo "$READY_SENTINEL"
            exit 0
        fi
        if [ -n "$DCS_READY_REGEX" ] && grep -qE "$DCS_READY_REGEX" "$DCS_LOG" 2>/dev/null; then
            echo "[dcs] readiness regex matched in dcs.log"
            echo "$READY_SENTINEL"
            exit 0
        fi
        sleep 3
        waited=$(( waited + 3 ))
        if [ "$waited" = "600" ]; then
            echo "[dcs] still not ready after 10 minutes — check dcs.log above."
            echo "[dcs] a missing Config/network.vault is the most common cause."
        fi
    done
) &
PROBE_PID=$!

# =============================================================================
#  Shutdown
# =============================================================================
#  The egg's stop command is ^C, so Wings sends SIGINT to the container's main
#  process; tini (-g) forwards it to the whole process group.
# =============================================================================
shutdown() {
    trap '' INT TERM
    log "shutdown requested — stopping DCS gracefully"

    kill "$PROBE_PID" 2>/dev/null

    # Ask Wine to terminate its Windows processes, giving DCS a chance to flush
    # its logs, track files and mission state.
    wineserver -k15 2>/dev/null

    waited=0
    while kill -0 "$WINE_PID" 2>/dev/null && [ "$waited" -lt "$DCS_STOP_TIMEOUT" ]; do
        sleep 2
        waited=$(( waited + 2 ))
    done

    if kill -0 "$WINE_PID" 2>/dev/null; then
        warn "DCS did not exit within ${DCS_STOP_TIMEOUT}s — forcing"
        wineserver -k 2>/dev/null
    fi

    kill "$TAIL_PID" 2>/dev/null
    # x11vnc was started with -bg, so it daemonised away from our $!.
    pkill -x x11vnc 2>/dev/null
    [ -n "$XVFB_PID" ] && kill "$XVFB_PID" 2>/dev/null
    log "stopped."
    exit 0
}
trap shutdown INT TERM

wait "$WINE_PID"
EXIT_CODE=$?
log "DCS_server.exe exited with code ${EXIT_CODE}"

kill "$PROBE_PID" "$TAIL_PID" 2>/dev/null
[ -n "$XVFB_PID" ] && kill "$XVFB_PID" 2>/dev/null
exit "$EXIT_CODE"
