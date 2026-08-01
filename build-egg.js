/*
 * Generates egg-dcs-world.json from install.sh.
 *
 * The egg format stores the install script as a single JSON string with CRLF
 * line endings (that is what the panel exports), so hand-escaping it is a
 * reliable way to produce a broken egg. This script does it mechanically.
 *
 *   node build-egg.js
 */
const fs = require("fs");
const path = require("path");

const HERE = __dirname;

// Panel exports use CRLF inside script strings; match that.
const installScript = fs
  .readFileSync(path.join(HERE, "install.sh"), "utf8")
  .replace(/\r\n/g, "\n")
  .replace(/\n/g, "\r\n");

// GHCR namespace. Must be lowercase: registries reject uppercase in image
// names, and the GitHub account here is "Sarizo13".
const IMAGE = "ghcr.io/sarizo13/dcs-world-server";

const egg = {
  _comment:
    "DCS World Dedicated Server egg. Requires the companion image built from the Dockerfile shipped alongside this file - see README-egg.md. Replace 'CHANGEME' in docker_images and in scripts.installation.container with your own registry namespace.",
  meta: {
    version: "PTDL_v2",
    update_url: null,
  },
  exported_at: new Date().toISOString().replace(/\.\d{3}Z$/, "+0000"),
  name: "DCS World Dedicated Server",
  author: "theopachecosarizo@gmail.com",
  description:
    "Eagle Dynamics DCS World dedicated server running under Wine + Xvfb. There is no native Linux dedicated server; this egg runs the Windows binaries on a pinned wine-staging build. First install downloads tens of gigabytes and takes hours. Read README-egg.md before importing.",
  features: [],
  docker_images: {
    // Wine is baked in at build time, so "pinning Wine" is expressed as a
    // choice of image tag rather than a runtime variable.
    "Wine staging 10.20 (recommended, known-good)": `${IMAGE}:wine-10.20`,
    "Wine staging 11.10 (newer, untested with DCS)": `${IMAGE}:wine-11.10`,
  },
  file_denylist: [],
  startup: "dcs-server-run",
  config: {
    // serverSettings.lua is a Lua table. Pterodactyl's parsers are
    // properties/yaml/ini/json/xml/file - none of them can safely rewrite it,
    // and the "file" line-parser breaks on DCS's nested tables. The startup
    // script reconciles the managed keys instead (see DCS_MANAGE_SETTINGS).
    files: "{}",
    // dcs-server-run prints this exact line once the game port is bound, so
    // detection does not depend on DCS log wording, which changes between
    // releases.
    startup: JSON.stringify({ done: ">>> DCS SERVER READY <<<" }, null, 4).replace(/\n/g, "\r\n"),
    logs: "{}",
    // DCS_server.exe has no stdin console. Wings sends SIGINT, tini forwards
    // it, and dcs-server-run performs a graceful wineserver shutdown.
    stop: "^C",
  },
  scripts: {
    installation: {
      script: installScript,
      // MUST be the DCS image: it is the only one with Wine + dcs-bootstrap.
      container: `${IMAGE}:wine-10.20`,
      entrypoint: "bash",
    },
  },
  variables: [
    {
      name: "DCS branch",
      description:
        "Which DCS branch to install: 'release' (recommended) or 'openbeta'. Eagle Dynamics merged Open Beta into the main release line in 2024, so 'openbeta' is retained for legacy installs only and may resolve to the same build.",
      env_variable: "DCS_BRANCH",
      default_value: "release",
      user_viewable: true,
      user_editable: true,
      rules: "required|string|in:release,openbeta",
    },
    {
      name: "Server name",
      description: "Name shown in the DCS multiplayer server browser.",
      env_variable: "DCS_SERVER_NAME",
      default_value: "DCS Server",
      user_viewable: true,
      user_editable: true,
      rules: "required|string|max:64",
    },
    {
      name: "Server password",
      description: "Join password. Leave empty for a public server.",
      env_variable: "DCS_SERVER_PASSWORD",
      default_value: "",
      user_viewable: true,
      user_editable: true,
      rules: "nullable|string|max:64",
    },
    {
      name: "Max players (slots)",
      description: "Maximum simultaneous players.",
      env_variable: "DCS_MAX_PLAYERS",
      default_value: "16",
      user_viewable: true,
      user_editable: true,
      rules: "required|integer|between:1,128",
    },
    {
      name: "Modules / terrains",
      description:
        "Whitespace-separated module IDs installed at install time, e.g. 'SYRIA_terrain MARIANAISLANDS_terrain SUPERCARRIER'. Valid IDs include CAUCASUS_terrain, NEVADA_terrain, NORMANDY_terrain, PERSIANGULF_terrain, THECHANNEL_terrain, SYRIA_terrain, MARIANAISLANDS_terrain, FALKLANDS_terrain, SINAIMAP_terrain, KOLA_terrain, AFGHANISTAN_terrain, IRAQ_terrain, GERMANYCW_terrain, MARIANAISLANDSWWII_terrain, SUPERCARRIER, WWII-ARMOUR. Each terrain is tens of GB. Changing this after install requires a reinstall.",
      env_variable: "DCS_MODULES",
      default_value: "",
      user_viewable: true,
      user_editable: true,
      rules: "nullable|regex:/^[A-Za-z0-9_ -]*$/",
    },
    {
      name: "Auto-update on boot",
      description:
        "1 = run the DCS updater before every start. Default 0. A DCS update can take hours and can break a working install, so leaving this off and updating deliberately is safer. See README-egg.md for the manual update and rollback procedure.",
      env_variable: "DCS_AUTO_UPDATE",
      default_value: "0",
      user_viewable: true,
      user_editable: true,
      rules: "required|in:0,1",
    },
    {
      name: "Startup mission (.miz)",
      description:
        "File name of a mission located in saved-games/<write dir>/Missions to load at startup. Leave empty to keep the mission list already configured in the WebGUI.",
      env_variable: "DCS_MISSION",
      default_value: "",
      user_viewable: true,
      user_editable: true,
      rules: "nullable|regex:/^[A-Za-z0-9 ._()-]+\\.miz$/",
    },
    {
      name: "WebGUI port",
      description:
        "TCP port for the DCS web control panel. Needs its own Pterodactyl allocation to be reachable from outside. Optional - the server runs headless without it.",
      env_variable: "DCS_WEBGUI_PORT",
      default_value: "8088",
      user_viewable: true,
      user_editable: true,
      rules: "required|integer|between:1024,65535",
    },
    {
      name: "Write directory",
      description:
        "Name of the DCS write folder under Saved Games (passed to DCS_server.exe as -w). Pinning it keeps the SFTP mission path stable; do not change it on a running server unless you move your files too.",
      env_variable: "DCS_WRITE_DIR",
      default_value: "DCS.server",
      user_viewable: true,
      user_editable: false,
      rules: "required|regex:/^[A-Za-z0-9._-]+$/",
    },
    {
      name: "Manage serverSettings.lua",
      description:
        "1 = re-apply server name, password, slots, port and WebGUI port from these variables on every boot. Set to 0 if you prefer to manage everything from the DCS WebGUI.",
      env_variable: "DCS_MANAGE_SETTINGS",
      default_value: "1",
      user_viewable: true,
      user_editable: true,
      rules: "required|in:0,1",
    },
    {
      name: "Enable VNC (first-time ED login)",
      description:
        "1 = expose the internal Xvfb display over VNC so you can log into your Eagle Dynamics account once and generate Config/network.vault. Needs its own allocation. Turn this back off once the vault file exists.",
      env_variable: "VNC_ENABLED",
      default_value: "0",
      user_viewable: true,
      user_editable: true,
      rules: "required|in:0,1",
    },
    {
      name: "VNC port",
      description: "TCP port for the temporary VNC session. Requires a matching allocation.",
      env_variable: "VNC_PORT",
      default_value: "5900",
      user_viewable: true,
      user_editable: true,
      rules: "required|integer|between:1024,65535",
    },
    {
      name: "VNC password",
      description:
        "Password for the temporary VNC session. Strongly recommended: a passwordless VNC on a public port hands over full control of the container.",
      env_variable: "VNC_PASSWORD",
      default_value: "",
      user_viewable: true,
      user_editable: true,
      rules: "nullable|string|max:64",
    },
    {
      name: "Force reinstall",
      description:
        "1 = wipe the Wine prefix (DCS install AND Saved Games) on the next panel reinstall. Destructive: missions and network.vault are deleted. Back up over SFTP first.",
      env_variable: "FORCE_REINSTALL",
      default_value: "0",
      user_viewable: true,
      user_editable: true,
      rules: "required|in:0,1",
    },
    {
      name: "Readiness regex (advanced)",
      description:
        "Optional extra readiness signal: an egrep pattern matched against dcs.log. The port-binding probe already handles the normal case; only set this if your server binds late.",
      env_variable: "DCS_READY_REGEX",
      default_value: "",
      user_viewable: true,
      user_editable: true,
      rules: "nullable|string|max:200",
    },
    {
      name: "Stop timeout (seconds)",
      description:
        "How long to wait for DCS to shut down gracefully before force-killing wineserver.",
      env_variable: "DCS_STOP_TIMEOUT",
      default_value: "90",
      user_viewable: true,
      user_editable: true,
      rules: "required|integer|between:10,600",
    },
    {
      name: "Container UID",
      description:
        "Must match system.user.uid in your wings config.yml (Pterodactyl default 988). Wine derives its per-user directory name from this UID's passwd entry, so a mismatch between install and runtime changes the Saved Games path.",
      env_variable: "CONTAINER_UID",
      default_value: "988",
      user_viewable: false,
      user_editable: false,
      rules: "required|integer|between:1,65535",
    },
    {
      name: "Container GID",
      description: "Must match system.user.gid in your wings config.yml (default 988).",
      env_variable: "CONTAINER_GID",
      default_value: "988",
      user_viewable: false,
      user_editable: false,
      rules: "required|integer|between:1,65535",
    },
  ],
};

const out = path.join(HERE, "egg-dcs-world.json");
fs.writeFileSync(out, JSON.stringify(egg, null, 4) + "\n", "utf8");
console.log(`wrote ${out}`);
