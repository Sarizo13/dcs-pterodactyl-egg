/*
 * Structural validation of egg-dcs-world.json against the PTDL_v2 shape that
 * Pterodactyl's egg importer expects.
 *
 * Pterodactyl publishes no machine-readable JSON Schema for eggs, so this
 * mirrors what the importer actually requires: the top-level keys, the
 * nested-JSON-in-a-string fields under `config`, and the variable records.
 *
 *   node validate-egg.js
 */
const fs = require("fs");
const path = require("path");

const file = path.join(__dirname, "egg-dcs-world.json");
const errors = [];
const warnings = [];

const raw = fs.readFileSync(file, "utf8");
let egg;
try {
  egg = JSON.parse(raw);
} catch (e) {
  console.error(`FAIL: not valid JSON — ${e.message}`);
  process.exit(1);
}

const req = (cond, msg) => { if (!cond) errors.push(msg); };
const warn = (cond, msg) => { if (!cond) warnings.push(msg); };

// --- top level ---------------------------------------------------------------
for (const k of ["_comment", "meta", "exported_at", "name", "author", "description",
                 "features", "docker_images", "file_denylist", "startup", "config",
                 "scripts", "variables"]) {
  req(k in egg, `missing top-level key: ${k}`);
}

req(egg.meta && egg.meta.version === "PTDL_v2", "meta.version must be 'PTDL_v2'");
req(egg.meta && "update_url" in egg.meta, "meta.update_url must be present (null is fine)");
req(typeof egg.name === "string" && egg.name.length > 0, "name must be a non-empty string");
req(/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(egg.author), "author must be an email address (panel enforces this)");
req(Array.isArray(egg.features) || egg.features === null, "features must be an array or null");
req(Array.isArray(egg.file_denylist), "file_denylist must be an array");
req(typeof egg.startup === "string" && egg.startup.trim().length > 0, "startup must be a non-empty string");

// --- docker_images -----------------------------------------------------------
req(egg.docker_images && typeof egg.docker_images === "object" && !Array.isArray(egg.docker_images),
    "docker_images must be an object mapping display name -> image ref");
const images = Object.entries(egg.docker_images || {});
req(images.length > 0, "docker_images must not be empty");
for (const [label, ref] of images) {
  req(typeof ref === "string" && ref.length > 0, `docker_images["${label}"] must be a string`);
  warn(!/CHANGEME/.test(ref), `docker_images["${label}"] still contains CHANGEME — set your registry namespace before importing`);
}

// --- config: nested JSON encoded as strings ----------------------------------
req(egg.config && typeof egg.config === "object", "config must be an object");
for (const k of ["files", "startup", "logs", "stop"]) {
  req(egg.config && typeof egg.config[k] === "string", `config.${k} must be a string`);
}
for (const k of ["files", "startup", "logs"]) {
  if (typeof egg.config?.[k] === "string") {
    try {
      JSON.parse(egg.config[k]);
    } catch (e) {
      errors.push(`config.${k} is not parseable JSON: ${e.message}`);
    }
  }
}
if (typeof egg.config?.startup === "string") {
  let s = {};
  try { s = JSON.parse(egg.config.startup); } catch { /* reported above */ }
  req(typeof s.done === "string" || Array.isArray(s.done),
      "config.startup must define a 'done' string (or array) for start detection");
  if (typeof s.done === "string") {
    warn(s.done.trim().length > 0, "config.startup.done is empty — the server will never be marked online");
  }
}
req(typeof egg.config?.stop === "string" && egg.config.stop.length > 0, "config.stop must be set");

// --- scripts.installation ----------------------------------------------------
const inst = egg.scripts && egg.scripts.installation;
req(inst && typeof inst === "object", "scripts.installation must be an object");
if (inst) {
  for (const k of ["script", "container", "entrypoint"]) {
    req(typeof inst[k] === "string" && inst[k].length > 0, `scripts.installation.${k} must be a non-empty string`);
  }
  warn(/^#!/.test(inst.script || ""), "install script does not start with a shebang");
  warn((inst.script || "").includes("\r\n"), "install script has no CRLF line endings (panel exports use CRLF)");
  warn(!/CHANGEME/.test(inst.container || ""), "scripts.installation.container still contains CHANGEME");
}

// --- variables ---------------------------------------------------------------
req(Array.isArray(egg.variables), "variables must be an array");
const seen = new Set();
for (const [i, v] of (egg.variables || []).entries()) {
  const at = `variables[${i}]${v && v.env_variable ? ` (${v.env_variable})` : ""}`;
  for (const k of ["name", "description", "env_variable", "default_value",
                   "user_viewable", "user_editable", "rules"]) {
    req(v && k in v, `${at}: missing key '${k}'`);
  }
  if (!v) continue;
  req(typeof v.user_viewable === "boolean", `${at}: user_viewable must be a boolean`);
  req(typeof v.user_editable === "boolean", `${at}: user_editable must be a boolean`);
  req(typeof v.default_value === "string", `${at}: default_value must be a string`);
  req(/^[A-Z][A-Z0-9_]*$/.test(v.env_variable || ""),
      `${at}: env_variable must be UPPER_SNAKE_CASE`);
  req(!seen.has(v.env_variable), `${at}: duplicate env_variable`);
  seen.add(v.env_variable);

  // Reserved names Pterodactyl injects itself; redefining them breaks imports.
  req(!["STARTUP", "SERVER_MEMORY", "SERVER_IP", "SERVER_PORT", "P_SERVER_UUID",
        "P_SERVER_LOCATION", "P_SERVER_ALLOCATION_LIMIT"].includes(v.env_variable),
      `${at}: '${v.env_variable}' is a reserved Pterodactyl variable and must not be declared`);

  req(typeof v.rules === "string" && v.rules.length > 0, `${at}: rules must be a non-empty string`);

  // A default that its own rules reject makes the egg un-importable.
  if (typeof v.rules === "string") {
    const m = v.rules.match(/regex:\/(.*)\/(?=\||$)/);
    if (m && v.default_value !== "") {
      let re;
      try { re = new RegExp(m[1]); } catch { re = null; }
      if (re) {
        req(re.test(v.default_value),
            `${at}: default_value '${v.default_value}' does not satisfy its own regex rule`);
      }
    }
    const inMatch = v.rules.match(/\bin:([^|]+)/);
    if (inMatch) {
      const allowed = inMatch[1].split(",");
      req(allowed.includes(v.default_value),
          `${at}: default_value '${v.default_value}' not in allowed list [${allowed}]`);
    }
    if (/\brequired\b/.test(v.rules)) {
      req(v.default_value !== "" || /nullable/.test(v.rules),
          `${at}: rule is 'required' but default_value is empty`);
    }
  }
}

// --- referential checks ------------------------------------------------------
// The startup command must be resolvable, and any {{VAR}} it uses must exist.
for (const ph of (egg.startup.match(/\{\{([A-Z0-9_]+)\}\}/g) || [])) {
  const nm = ph.slice(2, -2);
  const builtin = ["SERVER_MEMORY", "SERVER_IP", "SERVER_PORT", "TZ"];
  req(seen.has(nm) || builtin.includes(nm),
      `startup references {{${nm}}} but no such variable is declared`);
}

// --- report ------------------------------------------------------------------
console.log(`egg: ${egg.name}`);
console.log(`variables: ${(egg.variables || []).length}`);
console.log(`images: ${images.length}`);
console.log(`install script: ${(inst?.script || "").length} bytes`);
console.log("");

for (const w of warnings) console.log(`WARN  ${w}`);
for (const e of errors) console.log(`ERROR ${e}`);
console.log("");
if (errors.length) {
  console.log(`FAILED with ${errors.length} error(s), ${warnings.length} warning(s)`);
  process.exit(1);
}
console.log(`PASSED (${warnings.length} warning(s))`);
