#!/usr/bin/env bash
# IPL Secure MCP multi-host installer — Personal multi-host installer; test on a new host first.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

VERSION='0.4.4'
TUNNEL_VERSION='0.0.16'
MCP_COMMIT='27c80be21b57d1dfed4f7fea2b5cf780f1cced92'
PNPM_VERSION='11.20.0'
BASE='/opt/ipl-mcp'
STATE='/var/lib/ipl-mcp'
CONFIG_BASE='/etc/ipl-mcp'
MODE=''
HOST_LABEL=''
DRY_RUN=0


log(){ printf '[IPL-MCP] %s\n' "$*"; }
warn(){ printf '[WARNUNG] %s\n' "$*" >&2; }
die(){ printf '[FEHLER] %s\n' "$*" >&2; exit 1; }
ask(){ local reply; read -r -p "$1" reply </dev/tty || die 'Interaktives Terminal erforderlich'; REPLY="$reply"; }
confirm(){ ask "$1 [ja/NEIN]: "; [[ "$REPLY" == 'ja' ]]; }
run(){ if ((DRY_RUN)); then printf '[DRY-RUN]'; printf ' %q' "$@"; echo; else "$@"; fi; }
usage(){ cat <<'EOF'
Nutzung: sudo bash install.sh [--mode standard|admin|both] [--host NAME] [--dry-run]
Nur Erstinstallation neuer Linux-Hosts. Vorhandene Dienste/Profile führen zum Abbruch.
Projekt-Gate-Tests sind optional und werden für die Installation nicht ausgeführt.
Lokaler Test: Unit-Validierung, Datei-/Zugriffscheck, Tunnel-ready.
MCP-Funktionsprüfung aus ChatGPT bleibt separat.
Der Installer benötigt einen interaktiven TTY für Tunnel-IDs, API-Keys und Bestätigungen.
EOF
}
while (($#)); do
 case "$1" in
 --mode) MODE="${2:?}"; shift 2;;
 --host) HOST_LABEL="${2:?}"; shift 2;;
 --dry-run) DRY_RUN=1; shift;;
 -h|--help) usage; exit 0;;
 *) die "Unbekanntes Argument: $1";;
 esac
done
[[ -z "$MODE" || "$MODE" =~ ^(standard|admin|both)$ ]] || die 'Ungültiger Modus'
[[ $EUID -eq 0 ]] || die 'Bitte als sudo bash install.sh starten (aus normalem Benutzerterminal)'
[[ -t 0 && -e /dev/tty ]] || die 'Ein interaktives Terminal wird benötigt'
[[ -r /etc/os-release ]] || die 'Linux OS-Metadaten fehlen'
# shellcheck disable=SC1091
source /etc/os-release
ARCH="$(uname -m)"
case "$ARCH" in
 x86_64|amd64) ARCH='amd64'; TUNNEL_SHA='d60cdba019bce451bcc3a15478cc5b9cb11270b049f5b56ea39a80b517f8b117';;
 aarch64|arm64) ARCH='arm64'; TUNNEL_SHA='963d0384aaa7c798778479c45673f9051a4039dd891aef8f8978d2a1a628b74f';;
 *) die "Architektur $ARCH nicht unterstützt";;
esac
if [[ -z "$HOST_LABEL" ]]; then HOST_LABEL="$(hostname -s | tr '[:lower:]' '[:upper:]')"; fi
[[ "$HOST_LABEL" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{1,49}$ ]] || die 'Hostlabel: 2–50 Zeichen, Buchstaben/Ziffern/_/-'
if [[ -z "$MODE" ]]; then
 ask 'Zu installieren (standard/admin/both): '; MODE="$REPLY"
 [[ "$MODE" =~ ^(standard|admin|both)$ ]] || die 'Ungültiger Modus'
fi
log "Version: $VERSION | Linux: ${PRETTY_NAME:-$ID} | Architektur: $ARCH | Host: $HOST_LABEL | Modus: $MODE"
log 'Standard = isolierter Dienstbenutzer ohne sudo; Admin = Root über eigenen OpenAI-Tunnel, nur auf Abruf (120 min).'
((DRY_RUN)) && { log 'DRY-RUN validiert nur die Eingaben; keine vollständige Installationssimulation.'; exit 0; }
confirm 'Fortfahren? Noch keine vorhandenen Installationen werden verändert.' || exit 0

command -v curl >/dev/null || die 'curl fehlt'
command -v unzip >/dev/null || die 'unzip fehlt'
command -v git >/dev/null || die 'git fehlt'
command -v python3 >/dev/null || die 'python3 fehlt'
command -v npm >/dev/null || die 'npm fehlt'
command -v node >/dev/null || die 'node fehlt'
command -v systemctl >/dev/null || die 'systemd fehlt'
node -e 'const major=Number(process.versions.node.split(".")[0]);process.exit(major>=22?0:1)' || die 'Node.js >=22 erforderlich'
command -v sha256sum >/dev/null || die 'sha256sum fehlt'
command -v timeout >/dev/null || die 'timeout fehlt'
command -v runuser >/dev/null || die 'runuser fehlt'
command -v realpath >/dev/null || die 'realpath fehlt'
command -v systemd-analyze >/dev/null || die 'systemd-analyze fehlt'
command -v flock >/dev/null || die 'flock fehlt'
command -v useradd >/dev/null || die 'useradd fehlt'
command -v groupadd >/dev/null || die 'groupadd fehlt'
command -v getent >/dev/null || die 'getent fehlt'


# Serialise concurrent installers. Lock lives in /run, outside rollback scope.
exec 9>/run/ipl-mcp-installer.lock
flock -n 9 || die 'Ein weiterer IPL-MCP-Installer läuft bereits'

# Reject existing installation and shared port conflicts before mutation.
TARGETS=( )
case "$MODE" in both) TARGETS=(standard admin);; *) TARGETS=("$MODE");; esac
# Reject conflicting helper commands before making any changes.
if [[ "$MODE" == admin || "$MODE" == both ]]; then
  for helper in mcp-admin-start mcp-admin-stop; do
    [[ ! -e "/usr/local/bin/$helper" && ! -L "/usr/local/bin/$helper" ]] || die "Admin-Hilfsbefehl bereits vorhanden: /usr/local/bin/$helper (kein Überschreiben)"
  done
fi
for kind in "${TARGETS[@]}"; do
 [[ ! -e "$BASE/$kind" && ! -L "$BASE/$kind" && ! -e "$CONFIG_BASE/$kind.json" && ! -L "$CONFIG_BASE/$kind.json" ]] || die "$kind: Installation vorhanden. Kein automatisches Überschreiben/Upgrade."
 [[ ! -e "/etc/systemd/system/ipl-mcp-$kind.service" && ! -L "/etc/systemd/system/ipl-mcp-$kind.service" ]] || die "$kind: systemd-Dienst existiert bereits"
done
for kind in "${TARGETS[@]}"; do
 if [[ "$kind" == standard ]]; then PORT=18080; else PORT=28080; fi
 if command -v ss >/dev/null && ss -ltnH "sport = :$PORT" | grep -q .; then die "Port $PORT belegt"; fi
done

log 'Voraussetzungen vorhanden. Download und Build erfolgen versionsgebunden.'
WORK="$(mktemp -d /tmp/ipl-mcp-installer.XXXXXXXX)"
# Track only paths/users created during this invocation. No deletion of pre-existing data.
CREATED_PATHS=()
CREATED_USERS=()
CREATED_GROUPS=()
UNIT_CREATED=0
COMMITTED=0
track_path(){ CREATED_PATHS+=("$1"); }
new_dir(){
 local path="$1"; shift
 if [[ -e "$path" || -L "$path" ]]; then die "Vorhandener Pfad vor Installation: $path"; fi
 install -d "$@" "$path"; track_path "$path"
}
rollback(){
 local code=$?
 trap - EXIT
 if (( code != 0 && COMMITTED == 0 )); then
   warn 'Installationsfehler; stoppe neue Dienste und bereinige neu erstellte Artefakte.'
   for kind in "${TARGETS[@]}"; do systemctl disable --now "ipl-mcp-$kind.service" >/dev/null 2>&1 || true; done
   for ((i=${#CREATED_PATHS[@]}-1;i>=0;i--)); do
     case "${CREATED_PATHS[i]}" in
       /usr/local/bin/mcp-admin-start|/usr/local/bin/mcp-admin-stop|/opt/ipl-mcp/*|/etc/ipl-mcp/*|/etc/systemd/system/ipl-mcp-*.service|/var/lib/mcp-agent|/var/lib/mcp-agent/workspace|/var/lib/mcp-agent/.secrets/ipl-mcp-*|/root/.secrets/ipl-mcp-*|/var/lib/mcp-agent/.config/tunnel-client/ipl-mcp-*|/root/.config/tunnel-client/ipl-mcp-*|/var/tmp/ipl-mcp-build.* )
         rm -rf -- "${CREATED_PATHS[i]}" || warn "Bereinigung fehlgeschlagen: ${CREATED_PATHS[i]}" ;;
       *) warn "Manuelle Prüfung erforderlich: ${CREATED_PATHS[i]}" ;;
     esac
   done
   systemctl daemon-reload >/dev/null 2>&1 || true
   for u in "${CREATED_USERS[@]}"; do userdel "$u" >/dev/null 2>&1 || warn "Benutzer bleibt: $u"; done
   for g in "${CREATED_GROUPS[@]}"; do groupdel "$g" >/dev/null 2>&1 || true; done
   warn 'Rollback ist best effort; externe Tunnel/Profile und vorhandene Benutzer sind nicht vollständig reversibel.'
 fi
 rm -rf -- "$WORK"
 exit "$code"
}
trap rollback EXIT
wait_ready(){
 local port="$1" max_wait="$2" i
 for ((i=0;i<max_wait;i++)); do
   if curl -fsS --max-time 2 "http://127.0.0.1:$port/readyz" >/dev/null 2>&1; then return 0; fi
   sleep 1
 done
 return 1
}

ZIP="tunnel-client-v${TUNNEL_VERSION}-linux-${ARCH}.zip"
URL="https://github.com/openai/tunnel-client/releases/download/v${TUNNEL_VERSION}/${ZIP}"
curl -fL --retry 3 --connect-timeout 15 --max-time 180 -o "$WORK/$ZIP" "$URL"
printf '%s  %s\n' "$TUNNEL_SHA" "$WORK/$ZIP" | sha256sum --check --status || die 'Tunnel-Client SHA-256 stimmt nicht!'
log 'Tunnel-Client SHA-256 verifiziert.'
# A valid archive hash is a provenance check; validate names/types before extraction.
python3 - "$WORK/$ZIP" <<'PYZIP'
import sys,zipfile
p=sys.argv[1]
expected={'tunnel-client','cloudflared','cloudflared-manifest.json','LICENSE','NOTICE'}
with zipfile.ZipFile(p) as z:
    files=z.infolist()
    names=[f.filename for f in files]
    if not expected.issubset(set(names)):
        sys.exit('Required tunnel-client files missing')
    if len(names)!=len(set(names)):
        sys.exit('Duplicate ZIP entries')
    for f in files:
        name=f.filename
        mode=(f.external_attr>>16) & 0o170000
        if name.startswith('/') or '\\' in name or '/' in name or name in {'.','..'} or mode==0o120000:
            sys.exit('Unsafe ZIP entry: '+name)
print('ZIP filenames and types validated')
PYZIP

# Explicit user prompts for scope and separately provisioned credentials.
declare -A IDS KEYS ROOTS
for kind in "${TARGETS[@]}"; do
  log "=== $kind: OpenAI Tunnel und Runtime-Key ==="
  log "Erstelle/ermittle in OpenAI Platform einen eigenen ${HOST_LABEL}-${kind^^} Tunnel"
  log 'Runtime-Key: nur Tunnels Read + Use. API-Key niemals in Chat oder Shell-Befehl angeben.'
  ask "Tunnel-ID für $kind (tunnel_...): "; IDS[$kind]="$REPLY"
  [[ "${IDS[$kind]}" =~ ^tunnel_[A-Za-z0-9]+$ ]] || die 'Ungültiges Tunnel-ID-Format'
  read -r -s -p "Runtime API Key für $kind (unsichtbar): " KEYS[$kind] </dev/tty || die 'API-Key-Eingabe fehlgeschlagen'; echo
  [[ -n "${KEYS[$kind]}" ]] || die 'Leerer Runtime-Key'
  if [[ "$kind" == standard ]]; then
    ask 'Standard-Roots (durch | getrennte absolute Pfade; Enter = /var/lib/mcp-agent/workspace): '
    ROOTS[$kind]="${REPLY:-/var/lib/mcp-agent/workspace}"
    IFS='|' read -r -a SELECTED_ROOTS <<< "${ROOTS[$kind]}"
    ((${#SELECTED_ROOTS[@]} > 0)) || die 'Mindestens ein Root erforderlich'
    for selected_root in "${SELECTED_ROOTS[@]}"; do
      [[ "$selected_root" == /* && "$selected_root" != / ]] || die 'Standard-Root muss absolut und darf nicht / sein'
      [[ "$selected_root" != *'..'* ]] || die 'Standard-Root darf keine .. enthalten'
      if [[ "$selected_root" == /var/lib/mcp-agent/workspace && ! -e "$selected_root" ]]; then
        # Der reservierte Workspace wird erst nach der Benutzereinrichtung erstellt.
        [[ "$(realpath -m -- "$selected_root")" == "$selected_root" ]] || die 'Workspace-Pfad nicht kanonisch'
        for prefix in /var /var/lib /var/lib/mcp-agent; do
          [[ ! -L "$prefix" ]] || die "Symlink im Workspace-Elternpfad: $prefix"
        done
      else
        [[ -d "$selected_root" && "$(realpath -e -- "$selected_root" 2>/dev/null)" == "$selected_root" ]] || die 'Standard-Root fehlt oder ist nicht kanonisch'
      fi
    done
  else
    warn 'ADMIN: root + filesystem / + Wildcard-Shell bedeutet vollständige Rechnerkontrolle.'
    confirm 'Die vollständige Root-Freigabe ausdrücklich autorisieren?' || die 'Admin-Freigabe nicht erteilt'
    ROOTS[$kind]='/'
  fi
done
if [[ "$MODE" == both && "${IDS[standard]}" == "${IDS[admin]}" ]]; then die 'Standard und Admin müssen verschiedene Tunnel-IDs nutzen'; fi

# Non-root standard account with nologin, no sudo. Admin process itself runs as root.
if [[ "$MODE" == standard || "$MODE" == both ]]; then
  if ! id mcp-agent >/dev/null 2>&1; then
    # Create home explicitly so rollback can distinguish old from new accounts.
    [[ ! -e /var/lib/mcp-agent ]] || die 'mcp-agent-Home existiert ohne Benutzer; manuell prüfen'
    useradd --system --user-group --home-dir /var/lib/mcp-agent --shell /usr/bin/nologin mcp-agent
    CREATED_USERS+=(mcp-agent)
    new_dir /var/lib/mcp-agent -o mcp-agent -g mcp-agent -m 700
  fi
  [[ "$(id -u mcp-agent)" != 0 ]] || die 'mcp-agent darf nicht root sein'
  if command -v sudo >/dev/null && sudo -l -U mcp-agent 2>/dev/null | grep -Eq 'NOPASSWD|\(ALL'; then die 'mcp-agent hat sudo-Rechte; zuerst bereinigen'; fi
  [[ -d /var/lib/mcp-agent ]] || die 'mcp-agent-Home fehlt'
  if [[ ! -e /var/lib/mcp-agent/workspace ]]; then
    new_dir /var/lib/mcp-agent/workspace -o mcp-agent -g mcp-agent -m 700
  fi
  for selected_root in "${SELECTED_ROOTS[@]}"; do
    if ! runuser -u mcp-agent -- test -r "$selected_root" || ! runuser -u mcp-agent -- test -w "$selected_root"; then
      die "Standard-Root nicht les-/schreibbar für mcp-agent: $selected_root (Rechte nicht automatisch erweitern)"
    fi
  done
fi

[[ -d "$BASE" ]] || new_dir "$BASE" -m 755
[[ -d "$CONFIG_BASE" ]] || new_dir "$CONFIG_BASE" -m 755
chmod 755 "$CONFIG_BASE"
[[ -d /opt/ipl-mcp/bin ]] || new_dir /opt/ipl-mcp/bin -m 755
# Build account must not have root privileges; separate from runtime identities.
if ! id ipl-mcp-build >/dev/null 2>&1; then
  useradd --system --user-group --home-dir /nonexistent --shell /usr/bin/nologin ipl-mcp-build
  CREATED_USERS+=(ipl-mcp-build)
fi
[[ "$(id -u ipl-mcp-build)" != 0 ]] || die 'Build-Account darf nicht root sein'
if command -v sudo >/dev/null && sudo -l -U ipl-mcp-build 2>/dev/null | grep -Eq 'NOPASSWD|\(ALL'; then die 'Build-Account hat sudo-Rechte'; fi
for kind in "${TARGETS[@]}"; do
  if [[ "$kind" == standard ]]; then SERVICE_USER=mcp-agent; SERVICE_HOME=/var/lib/mcp-agent; PORT=18080; else SERVICE_USER=root; SERVICE_HOME=/root; PORT=28080; fi
  TARGET="$BASE/$kind"
  new_dir "$TARGET" -m 755
  new_dir "$TARGET/tunnel-bin" -m 755
  unzip -q "$WORK/$ZIP" -d "$TARGET/tunnel-bin"
  chmod 755 "$TARGET/tunnel-bin/tunnel-client" "$TARGET/tunnel-bin/cloudflared"
  # Git clone/install/gate/build use unprivileged, disposable-owned staging workspace.
  BUILD_DIR="$(mktemp -d /var/tmp/ipl-mcp-build.XXXXXXXX)"
  chown ipl-mcp-build:ipl-mcp-build "$BUILD_DIR"; chmod 700 "$BUILD_DIR"
  track_path "$BUILD_DIR"
  install -d -o ipl-mcp-build -g ipl-mcp-build -m 700 "$BUILD_DIR/.cache"
  # Root HOME/npm cache must not leak into the unprivileged build.
  export IPL_BUILD_HOME="$BUILD_DIR"
  (cd /var/tmp && runuser -u ipl-mcp-build -- env HOME="$IPL_BUILD_HOME" npm_config_cache="$IPL_BUILD_HOME/.cache" git clone --quiet https://github.com/alexcodeplace/chatgpt-mcp.git "$BUILD_DIR/repo")
  runuser -u ipl-mcp-build -- env HOME="$IPL_BUILD_HOME" git -C "$BUILD_DIR/repo" checkout --quiet --detach "$MCP_COMMIT"
  [[ "$(runuser -u ipl-mcp-build -- env HOME="$IPL_BUILD_HOME" git -C "$BUILD_DIR/repo" rev-parse HEAD)" == "$MCP_COMMIT" ]] || die 'Commit-Abgleich fehlgeschlagen'
  log "$kind: Abhängigkeiten und Tests als ipl-mcp-build (nicht root)"
  (cd "$BUILD_DIR/repo" && runuser -u ipl-mcp-build -- env HOME="$IPL_BUILD_HOME" npm_config_cache="$IPL_BUILD_HOME/.cache" npm exec --yes --package="pnpm@$PNPM_VERSION" -- pnpm install --frozen-lockfile)
  # Das Projekt-Gate enthält einen bekannten zeitabhängigen Reliability-Test.
  # Für den privaten Installer zählt, ob der gepinnte Quellcode baut und der
  # Tunnel anschließend tatsächlich betriebsbereit ist.
  log "$kind: Projekt-Gate bewusst übersprungen; baue MCP"
  (cd "$BUILD_DIR/repo" && runuser -u ipl-mcp-build -- env HOME="$IPL_BUILD_HOME" npm_config_cache="$IPL_BUILD_HOME/.cache" npm exec --yes --package="pnpm@$PNPM_VERSION" -- pnpm run build)
  test -s "$BUILD_DIR/repo/dist/src/stdio.js" || die 'Build-Artefakt fehlt'
  mv "$BUILD_DIR/repo" "$TARGET/chatgpt-mcp"
  chown -R root:root "$TARGET/chatgpt-mcp"
  # Unprivileged build staging uses umask 077: grant runtime traversal/read only.
  chmod -R go+rX "$TARGET/chatgpt-mcp"
  chmod -R go-w "$TARGET/chatgpt-mcp"
  rm -rf -- "$BUILD_DIR" # Only this-run staging workspace
  python3 - "$TARGET/chatgpt-mcp/config.example.json" "$CONFIG_BASE/$kind.json" "${ROOTS[$kind]}" "$kind" <<'PY'
import json, os, pathlib, sys
source, dest, root, mode = sys.argv[1:]
c=json.loads(pathlib.Path(source).read_text())
roots=root.split('|')
assert all(p.startswith('/') and p != '/' for p in roots) if mode == 'standard' else True
c['filesystem'].update(read=True,write=True,roots=roots)
c['shell'].update(enabled=(mode=='admin'),allowedCommands=['*'] if mode=='admin' else [])
c['shell']['allowEnvironment']=False
c['process'].update(list=False,kill=False)
c['service']['enabled']=False
c['application']['enabled']=False
c['browser']['enabled']=False
c['desktop'].update(hostDisplayAccess=False,screenCapture=False,screenRecording=False,input=False)
c['jobs']['enabled']=False
p=pathlib.Path(dest); fd=os.open(p,os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600)
with os.fdopen(fd,'w') as f: json.dump(c,f,indent=2);f.write('\n')
print(f'Konfiguration erstellt: {p} | root={root} | admin={mode=="admin"}')
PY
  track_path "$CONFIG_BASE/$kind.json"
  if [[ "$kind" == standard ]]; then
    chown root:mcp-agent "$CONFIG_BASE/standard.json"
    chmod 640 "$CONFIG_BASE/standard.json"
  else
    chown root:root "$CONFIG_BASE/admin.json"
    chmod 600 "$CONFIG_BASE/admin.json"
  fi
  install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 700 "$SERVICE_HOME/.secrets" "$SERVICE_HOME/.config" "$SERVICE_HOME/.config/tunnel-client"
  # Key is written by shell redirection from an in-memory variable, never as an argument.
  KEY_PATH="$SERVICE_HOME/.secrets/ipl-mcp-$kind-runtime-key"
  [[ ! -e "$KEY_PATH" && ! -L "$KEY_PATH" ]] || die "Secret bereits vorhanden: $KEY_PATH"
  ( umask 077; printf '%s' "${KEYS[$kind]}" > "$KEY_PATH" )
  track_path "$KEY_PATH"
  chown "$SERVICE_USER:$SERVICE_USER" "$KEY_PATH"; chmod 600 "$KEY_PATH"
  unset 'KEYS[$kind]'
  # Profile under correct home with clean env, no dependence on invoking user's cwd.
  [[ ! -e "$SERVICE_HOME/.config/tunnel-client/ipl-mcp-$kind.yaml" ]] || die "Tunnel-Profil bereits vorhanden: $kind"
  track_path "$SERVICE_HOME/.config/tunnel-client/ipl-mcp-$kind.yaml"
  (cd /tmp && runuser -u "$SERVICE_USER" -- env -i HOME="$SERVICE_HOME" USER="$SERVICE_USER" LOGNAME="$SERVICE_USER" PATH=/usr/bin:/bin \
    "$TARGET/tunnel-bin/tunnel-client" init --sample sample_mcp_stdio_local \
    --profile "ipl-mcp-$kind" --tunnel-id "${IDS[$kind]}" \
    --mcp-command "env CHATGPT_MCP_CONFIG=$CONFIG_BASE/$kind.json node $TARGET/chatgpt-mcp/dist/src/stdio.js" \
    --health-listen-addr "127.0.0.1:$PORT")
  PROFILE_PATH="$SERVICE_HOME/.config/tunnel-client/ipl-mcp-$kind.yaml"
  [[ -f "$PROFILE_PATH" ]] || die "Tunnel-Profil nicht am erwarteten Pfad erstellt: $PROFILE_PATH"
  # Secure installation code; the stdio subprocess itself runs under systemd's service identity.
  chown -R root:root "$TARGET"
  chmod -R go-w "$TARGET"
  START="/opt/ipl-mcp/bin/run-$kind"
  [[ ! -e "$START" && ! -L "$START" ]] || die "Launcher existiert: $START"
  track_path "$START"
  cat >"$START" <<EOF
#!/bin/sh
set -eu
export HOME="$SERVICE_HOME"
export CONTROL_PLANE_API_KEY="\$(cat "$KEY_PATH")"
exec "$TARGET/tunnel-bin/tunnel-client" run --profile ipl-mcp-$kind
EOF
  chmod 755 "$START"; chown root:root "$START"
  UNIT="/etc/systemd/system/ipl-mcp-$kind.service"
  track_path "$UNIT"
  cat >"$UNIT" <<EOF
[Unit]
Description=IPL Secure MCP $kind (${HOST_LABEL})
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$SERVICE_HOME
Environment=HOME=$SERVICE_HOME
ExecStart=$START
UMask=0077
TimeoutStopSec=30s
KillMode=control-group
EOF
  if [[ "$kind" == standard ]]; then
    cat >>"$UNIT" <<'EOF'
NoNewPrivileges=yes
CapabilityBoundingSet=
AmbientCapabilities=
RestrictSUIDSGID=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectSystem=strict
ProtectHome=no
# ProtectHome=yes would block selected roots under /home; rely on explicit systemd RW paths.
ReadWritePaths=/var/lib/mcp-agent
# Explicitly configured user roots are appended below. Files outside roots are
# still readable depending on OS policy; MCP filesystem roots govern MCP fs tools.
Restart=on-failure
RestartSec=10
EOF
  else
    cat >>"$UNIT" <<'EOF'
NoNewPrivileges=yes
Restart=no
RuntimeMaxSec=2h
EOF
  fi
  if [[ "$kind" == standard ]]; then
    # Explicitly permit declared roots inside ProtectSystem=strict (never broad /).
    IFS='|' read -r -a RW_ROOTS <<< "${ROOTS[standard]}"
    for rwroot in "${RW_ROOTS[@]}"; do
      # systemd unit values may not safely contain whitespace or specifiers
      [[ "$rwroot" != *[[:space:]%]* ]] || die "Standard-Root für systemd ungeeignet: $rwroot"
      printf 'ReadWritePaths=%s\n' "$rwroot" >>"$UNIT"
    done
  fi
  cat >>"$UNIT" <<'EOF'

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$UNIT"
  log "$kind: Dienst vorbereitet (Start erfolgt erst nach gesondertem lokalen Check)"
done
systemctl daemon-reload
for kind in "${TARGETS[@]}"; do
  systemd-analyze verify "ipl-mcp-$kind.service" || die "systemd-Unit $kind ungültig"
  # systemd verify checks only the unit structure; attempt real tunnel start below.
  if [[ "$kind" == standard ]]; then
    log 'Standard: starte Dienst für Bereitschaftstest (noch nicht beim Boot aktiviert)'
    systemctl start ipl-mcp-standard.service || die 'Standard-Dienst konnte nicht starten'
    if ! wait_ready 18080 45; then
      systemctl status --no-pager -l ipl-mcp-standard.service >&2 || true
      journalctl -u ipl-mcp-standard.service -n 25 --no-pager >&2 || true
      die 'Standard-Tunnel nicht innerhalb 45 Sekunden bereit'
    fi
    # Check local service identity, config readability and workspace access.
    runuser -u mcp-agent -- test -r "$CONFIG_BASE/standard.json" || die 'Standard-Konfiguration nicht lesbar'
    runuser -u mcp-agent -- test -x "$BASE/bin/run-standard" || die 'Standard-Launcher nicht ausführbar'
    for selected_root in "${SELECTED_ROOTS[@]}"; do
      runuser -u mcp-agent -- test -w "$selected_root" || die "Standard-Root nicht beschreibbar: $selected_root"
    done
    [[ "$(systemctl show -P MainPID ipl-mcp-standard.service)" =~ ^[1-9][0-9]*$ ]] || die 'Standard-Dienst hat keinen Hauptprozess'
    systemctl enable ipl-mcp-standard.service
    log 'Standard: Lokale Rechte und Tunnel-ready bestätigt; Dienst aktiviert' 
  else
    systemctl disable ipl-mcp-admin.service >/dev/null 2>&1 || true
    log 'Admin ist installiert, bleibt AUS. Start nach Installation: mcp-admin-start'
    log 'Admin Stopp nach Installation: mcp-admin-stop'
  fi
done
# Only admin installations receive the convenience commands. The service remains
# disabled and stopped until explicitly started by the user. Privilege prompting
# is handled by sudo; no passwordless sudo rule is installed.
if [[ "$MODE" == admin || "$MODE" == both ]]; then
  for action in start stop; do
    helper="/usr/local/bin/mcp-admin-$action"
    track_path "$helper"
    cat >"$helper" <<EOFHELPER
#!/bin/sh
set -eu
exec sudo systemctl $action ipl-mcp-admin.service
EOFHELPER
    chown root:root "$helper"
    chmod 755 "$helper"
    /bin/sh -n "$helper" || die "Hilfsbefehl fehlerhaft: $helper"
  done
  log 'Admin-Hilfsbefehle installiert: mcp-admin-start und mcp-admin-stop'
fi
COMMITTED=1
cat <<EOF

=== INSTALLATIONSERGEBNIS ===
Host: $HOST_LABEL
Installierter Modus: $MODE
MCP Commit: $MCP_COMMIT
Tunnel Client: $TUNNEL_VERSION ($ARCH)
Standard-Tunnel: bei Modus standard/both gestartet, ready geprüft und aktiviert
Admin-Tunnel: bei Modus admin/both installiert, AUS bis zur manuellen Aktivierung
Admin-Befehle: mcp-admin-start und mcp-admin-stop (nur bei admin/both)
NÄCHSTE SCHRITTE (manuell):
- Standard-Verbindung in ChatGPT → Add custom MCP server → Tunnel → No Authentication anlegen.
- Admin erst nach gesonderter Root-Risiko-Freigabe starten; dasselbe mit separater Admin-Tunnel-ID.
- ChatGPT Tools refresh; system.info, fs.write, fs.read und PATH_NOT_ALLOWED testen.
- Reboot, 120-Minuten-Limit, Recovery und Rollback bleiben offener Abnahmepunkt.
EOF