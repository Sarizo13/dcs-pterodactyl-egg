# =============================================================================
#  DCS World Dedicated Server — Pterodactyl / Wings compatible image
# =============================================================================
#
#  WHY THIS IMAGE EXISTS (i.e. why we cannot just use aterfax/... directly)
#  -----------------------------------------------------------------------
#  `aterfax/dcs-world-dedicated-server` is built on
#  `lscr.io/linuxserver/webtop:debian-xfce`. Its ENTRYPOINT is s6-overlay's
#  `/init`, which boots a full XFCE desktop + KasmVNC and starts DCS from an
#  s6 longrun service.
#
#  Wings, however, sets NEITHER `Entrypoint` NOR `Cmd` on the container it
#  creates (see pterodactyl/wings environment/docker/container.go). The egg's
#  startup command reaches the container ONLY through the `$STARTUP`
#  environment variable, and it is the IMAGE's own entrypoint that is expected
#  to expand and `eval` it. This is what the docs mean by "Docker images must
#  be specifically designed to work with Pterodactyl Panel".
#     => the aterfax image would silently ignore the egg's startup command
#        and boot a desktop instead.
#
#  Two further blockers:
#    * linuxserver images perform PUID/PGID user-switching as root at boot;
#      Wings runs the container as a fixed non-root UID.
#    * Only /home/container is writable/persistent under Wings; the aterfax
#      layout lives in /config.
#
#  So this image is a Pterodactyl-native rebuild that deliberately REUSES the
#  proven Wine/DCS recipe from Aterfax/DCS-World-Dedicated-Server-Docker —
#  the DLL overrides, the winetricks component list and the DCS_updater
#  bootstrap sequence are taken from that project, not invented here.
#
# =============================================================================

FROM debian:bookworm-slim

# -----------------------------------------------------------------------------
#  Wine version pin  —  DO NOT set this to "latest".
# -----------------------------------------------------------------------------
#  DCS_updater.exe erroneously detects a debugger and refuses to start on
#  WineHQ *standard* builds >= 10.3, with:
#
#      "A debugger has been found running in your system.
#       Please, unload it from memory and restart your program."
#
#  wine-STAGING is the documented fix. DCS_server.exe itself is NOT affected —
#  only the updater, which means a "latest stable" image installs fine once and
#  then breaks the moment it tries to update.
#
#    Upstream: WineHQ bug 58043 and 59074
#    Tracker:  ActiumDev/dcs-server-wine issue #8 (still OPEN as of 2026-08)
#
#  We pin the last 10.x staging build: it carries the updater fix and predates
#  the ntsync synchronisation switch that landed in Wine 11.0. (ntsync also
#  needs /dev/ntsync, which Wings does not expose to the container, so it would
#  be inert here anyway — but there is no reason to take the regression risk.)
#
#  The WineHQ Debian repo keeps every historical build in its pool, so this
#  exact pin stays installable long-term.
# -----------------------------------------------------------------------------
ARG WINE_BRANCH=staging
ARG WINE_VERSION=10.20~bookworm-1

# UID the container process will run as. Must match `system.user.uid` in your
# wings config.yml (Pterodactyl's default is 988). See README-egg.md.
ARG CONTAINER_UID=988
ARG CONTAINER_GID=988

ENV DEBIAN_FRONTEND=noninteractive

# -----------------------------------------------------------------------------
#  Base packages
# -----------------------------------------------------------------------------
#  xvfb      : MANDATORY. DCS_updater.exe will not run without an X display,
#              and winetricks' vcrun2022 needs a real display even when run
#              with --unattended.
#  x11vnc    : optional, used only for the one-time interactive ED login that
#              produces Config/network.vault (see README-egg.md).
#  openbox   : started only alongside VNC. With no window manager the display
#              has no focus management (X falls back to PointerRoot), which
#              makes typing credentials into the DCS login form unreliable —
#              precisely the one step that must not be flaky. Idle cost is
#              zero when VNC is off.
#  winbind   : provides ntlm_auth, which Wine wants for network auth.
#  cabextract: required by winetricks to unpack MS redistributables.
#  iproute2  : `ss`, used by the readiness probe in dcs-server-run.
# -----------------------------------------------------------------------------
RUN dpkg --add-architecture i386 \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        wget \
        gnupg \
        unzip \
        p7zip-full \
        cabextract \
        xvfb \
        xauth \
        x11vnc \
        openbox \
        winbind \
        libfreetype6 \
        libfreetype6:i386 \
        procps \
        psmisc \
        iproute2 \
        locales \
        tzdata \
        tini \
        sed \
        gawk \
        tar \
 && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
#  WineHQ repository + pinned wine-staging
# -----------------------------------------------------------------------------
#  All four packages are pinned to the same version, then apt-mark'ed hold so
#  that a stray `apt upgrade` in a derived image cannot silently move Wine to a
#  build that breaks DCS_updater.exe.
# -----------------------------------------------------------------------------
RUN mkdir -pm755 /etc/apt/keyrings \
 && wget -qO /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key \
 && wget -qNP /etc/apt/sources.list.d/ https://dl.winehq.org/wine-builds/debian/dists/bookworm/winehq-bookworm.sources \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
        "winehq-${WINE_BRANCH}=${WINE_VERSION}" \
        "wine-${WINE_BRANCH}=${WINE_VERSION}" \
        "wine-${WINE_BRANCH}-amd64=${WINE_VERSION}" \
        "wine-${WINE_BRANCH}-i386=${WINE_VERSION}" \
 && apt-mark hold \
        "winehq-${WINE_BRANCH}" \
        "wine-${WINE_BRANCH}" \
        "wine-${WINE_BRANCH}-amd64" \
        "wine-${WINE_BRANCH}-i386" \
 && rm -rf /var/lib/apt/lists/*

# Record the pin inside the image so `wine --version` drift is detectable at
# runtime and visible in the server console banner.
RUN echo "${WINE_BRANCH} ${WINE_VERSION}" > /etc/dcs-wine-pin

# -----------------------------------------------------------------------------
#  winetricks
# -----------------------------------------------------------------------------
#  NOTE / UNPINNED: winetricks is pulled from its master branch, exactly as the
#  aterfax project does. It has no stable release cadence that tracks Wine, and
#  the verb definitions we need (vcrun2022, d3dcompiler_47) are only correct in
#  recent revisions. If you need byte-reproducible builds, replace
#  WINETRICKS_REF with a commit SHA.
# -----------------------------------------------------------------------------
ARG WINETRICKS_REF=master
RUN wget -qO /usr/local/bin/winetricks \
        "https://raw.githubusercontent.com/Winetricks/winetricks/${WINETRICKS_REF}/src/winetricks" \
 && chmod 755 /usr/local/bin/winetricks

# -----------------------------------------------------------------------------
#  Pterodactyl container user
# -----------------------------------------------------------------------------
#  Wings runs the container as the UID from its own config, not as whatever
#  USER we declare. We still create a real passwd entry for that UID because
#  Wine derives the name of its per-user directory
#  (drive_c/users/<name>/Saved Games) from the passwd entry of the running
#  euid. Without it the Saved Games path would change between the install
#  phase and the runtime phase. dcs-server-run additionally resolves that
#  directory dynamically and exposes it as a stable symlink, so a UID mismatch
#  degrades gracefully instead of losing missions.
# -----------------------------------------------------------------------------
RUN groupadd -g ${CONTAINER_GID} container \
 && useradd -m -d /home/container -u ${CONTAINER_UID} -g ${CONTAINER_GID} -s /bin/bash container

# -----------------------------------------------------------------------------
#  Deliberately NO `USER container` directive.
# -----------------------------------------------------------------------------
#  This one image fills two roles, and Wings treats them differently:
#
#    * GAME container    — Wings sets conf.User explicitly
#                          ("<uid>:<gid>" from system.user in config.yml), so a
#                          USER directive here would be ignored anyway.
#
#    * INSTALL container — Wings does NOT set User, so Docker honours the
#                          image's USER. It also writes the install script as
#                          root with mode 0644 into a private temp dir. With
#                          `USER container` the install therefore died on
#                          `bash: /mnt/install/install.sh: Permission denied`
#                          before executing a single line — which is exactly
#                          what happened on the first real deployment.
#
#  Running the install phase as root is the norm (parkervcp/installers images
#  declare no USER either). dcs-bootstrap drops to CONTAINER_UID itself before
#  touching Wine, so the prefix is still created by, and named after, the user
#  that will run the server.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
#  Locale — must be a REAL, generated UTF-8 locale.
# -----------------------------------------------------------------------------
#  POSIX ties the filesystem's filename encoding to LC_CTYPE. Under the default
#  C/POSIX locale that encoding is pure ASCII, so Wine cannot create any file
#  whose Windows name contains a non-ASCII character. DCS ships livery folders
#  with accented names, and the very first download pass dies on one:
#
#      Can't create directory ...\C-101CC\I Brigada Aerea - Chile Early
#      Agressor Nº410 N.1 A-36 HALCON\: (2) File not found.
#
#  Declaring ENV LANG is NOT sufficient: if the locale has not been generated,
#  glibc silently falls back to C and everything looks fine until a non-ASCII
#  filename shows up. That is exactly how this bit the first deployment.
# -----------------------------------------------------------------------------
RUN sed -i 's/^# *\(en_US\.UTF-8 UTF-8\)/\1/' /etc/locale.gen \
 && locale-gen en_US.UTF-8 \
 && update-locale LANG=en_US.UTF-8 \
 && [ "$(LC_ALL=en_US.UTF-8 locale charmap)" = "UTF-8" ]

ENV USER=container \
    HOME=/home/container \
    WINEARCH=win64 \
    WINEDEBUG=-all \
    DISPLAY=:99 \
    XVFB_RES=1024x768x16 \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

# mscoree/mshtml disabled: stops Wine from popping the blocking "install Mono /
# Gecko?" dialogs on first prefix creation, which would hang a headless boot.
ENV WINEDLLOVERRIDES="mscoree=d;mshtml=d"

COPY entrypoint.sh      /entrypoint.sh
COPY dcs-bootstrap.sh   /usr/local/bin/dcs-bootstrap
COPY dcs-server-run.sh  /usr/local/bin/dcs-server-run
RUN chmod 755 /entrypoint.sh /usr/local/bin/dcs-bootstrap /usr/local/bin/dcs-server-run

WORKDIR /home/container

# DCS game port (TCP+UDP) and WebGUI. Documentation only — Wings publishes the
# ports from the server's allocations, not from EXPOSE.
EXPOSE 10308/tcp 10308/udp 8088/tcp

ENTRYPOINT ["/usr/bin/tini", "-g", "--"]
CMD ["/bin/bash", "/entrypoint.sh"]
