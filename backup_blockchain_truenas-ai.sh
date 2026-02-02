#!/usr/bin/env bash
# Blockchain Backup/Restore script - robust, headless
# Anforderungen: bash, zfs, docker, rsync, cifs-utils
# on behalf GPT5 nano https://chatx.de/
# on behalf ChatGPT https://chatgpt.com
version="260201-unstable, by Mr.AtiX + AI review"

set -euo pipefail
IFS=$'\n\t' # Zeilenhandling

# --- declare variables
backup=true restore=false prune=false purge=false
use_usb=false dry=false debug=false
force=false is_mounted=false is_svcup=true
height=0 srcsynctime=0 destsynctime=0
thishost="" srcdir="" destdir="" dataset="" nasmount="" snapname=""
suffix="" ctname="" cfgfile="" cifscreds="" rsync_opts=""
role="" service="" mode="" destdir_machine=""
thishost=$(hostname -s)

# --- default variables (an eigene Umgebung anpassen)
export LANG=de_DE.UTF-8
now=$(date +%y%m%d%H%M%S)
mode="${mode:-backup}"
blockchain="${blockchain:-btc}"
service="${service:-bitcoind}"
debug="${debug:-false}"
nasuser="${nasuser:-rsync}"     # Samba Benutzername
cifscreds=""                    # Samba credentials-Datei
NASHOST=192.168.178.20
NASHOSTNAME=cronas
nasshare="${nasshare:-backups}" # Freigabe auf Server
destdir_machine="${destdir_machine:-}"
scriptlogging=true              # Scriptausgaben protokollieren
scriptlogfile="${scriptlogfile:-$HOME/backup_blockchain_truenas.log}"   # Script-Logdatei


# --- logging and error handling
[[ "$debug" == true ]] && set -x
log() { local ts; ts=$(date '+%F %T'); echo "${ts} [info] $*" | tee -a "$scriptlogfile"; sleep 1; }
warn() { local ts; ts=$(date '+%F %T'); echo "${ts} [warn] $*" | tee -a "$scriptlogfile" >&2; sleep 3; }
err() { local ts; ts=$(date '+%F %T'); echo "${ts} [error] $*" | tee -a "$scriptlogfile" >&2; sleep 3; }
on_error() { local rc=$? local lineno=${1:-unknown}; err "Fehler (rc=${rc}) in Zeile ${lineno}."; exit "${rc:-1}"; }
dbg() { [[ "${debug:-false}" == true ]] && echo "[dbg] $*"; }
trap 'on_error $LINENO' ERR

# --- filelock (verhindert parallele Skriptläufe)
exec 9>/var/run/backup_blockchain_truenas.lock || exit 1
flock -n 9 || on_error { "Script $0 läuft bereits als PID="; lsof -t /var/run/backup_blockchain_truenas.lock ; echo "Abbruch."}


# --- configuration loader
load_config() {
  # Format: key=value
  # wird mit load_config "$cfgfile" geladen
  # CLI-Argumente haben Vorrang (werden auch nach dem Laden einer Konfiguration priorisiert)

#todo configfile/input format: KEY=value und key=value zulassen (upper and lowercase)
#todo configfile/input validatätsprüfung nötig:
#   - den versuch ein falsches configfile einzulesen unterbinden
#   - logische prüfung z.b. passt $THIS_HOST||$thishost == $(hostname -s)}"; -> übergabe || sofortiger abbruch
#   - ausnahme wäre ein testing-szenario, bei welchem der KEY/key ganz fehlt oder leer ist. hierbei einen hinweis ausgeben und nachfragen. dieses szenario könnte/sollte man mit --force absichern
#   - globale definitions/arrays welche Features definieren (z.B. ROLES,POOLS,DATASETS,SERVICES,BLOCKCHAINS, usw.) dürfen niemals aus einem configfile eingelesen und gar überschrieben werden. vielmehr sollte es im script constant/statisch verankert sein. zur besseren unterscheidung können solche wichtigen variablen/arrays uppercase beibehalten.

  local cfgfile="$1"

  if [[ -z "$cfgfile" || ! -f "$cfgfile" ]]; then
    warn "load_config: Konfigurationsdatei nicht gefunden: $cfgfile" >&2
    return 1
  fi

  # Zeilenweise lesen
  while IFS='=' read -r key value; do
    # überspringe leere Zeilen und #Kommentare
    [[ -z "$key" || "$key" == \#* ]] && continue

    # Trim whitespaces, vor Key und nach Value
    key="${key##+([[:space:]])}"
    key="${key%%([[:space:]])}"
    value="${value##+([[:space:]])}"
    value="${value%%([[:space:]])}"

    # entferne surrounding Quotes
    if [[ "$value" == \"*\" && "$value" == *\" ]]; then
      value="${value#\"}"
      value="${value%\"}"
    fi
    if [[ "$value" == \'*\" ]]; then
      value="${value#\'}"
      value="${value%\'}"
    fi

    # sonstige Lesefehler abfangen

    # als Global setzen
    if [[ -n "$key" ]]; then
      # hier Validatätsprüfung nötig
      declare -g "$key"="$value"
      log "load_config: read key=$key value=$value"
    fi
  done < "$cfgfile"

# --- normalize variables to lowercase ---
# Übergangsphase: Großbuchstaben abfangen
#todo remove legacy uppercase variable aliases after migration

[ -n "${THIS_HOST:-}" ] && thishost="$THIS_HOST"
[ -n "${ROLE:-}" ]      && role="$ROLE"
[ -n "${FS_TYPE:-}" ]   && fs_type="$FS_TYPE"
[ -n "${SERVICE:-}" ]   && service="$SERVICE"

[ -n "${SRC_BASE:-}" ]  && src_base="$SRC_BASE"
[ -n "${DEST_BASE:-}" ] && dest_base="$DEST_BASE"

[ -n "${MODE:-}" ]      && mode="$MODE"
[ -n "${DEBUG:-}" ]     && debug="$DEBUG"
[ -n "${DRY_RUN:-}" ]   && dry="$DRY_RUN"
[ -n "${FORCE:-}" ]     && force="$FORCE"
[ -n "${RESTORE:-}" ]   && restore="$RESTORE"

log "config normalized: thishost=${thishost:-unset}, role=${role:-unset}, service=${service:-unset}"

  # Validierung/Default-Hinweise
  : "${thishost:=}"
  : "${srcdir:=}"
  : "${destdir:=}"

  local missing=()
  if [[ -z "$thishost" ]]; then
    missing+=("thishost")
  fi
  if [[ -z "${srcdir}" ]]; then
    missing+=("srcdir")
  fi
  if [[ -z "${destdir}" ]]; then
    missing+=("destdir")
  fi

  if (( ${#missing[@]} )); then
    echo "load_config: Fehlender Pflichtwert: ${missing[*]}" >&2
    return 2
  fi

  # Pfad-Existenz überprüfen
  if [[ ! -d "${srcdir}" ]]; then
    warn "load_config: Quellpfad existiert nicht: ${srcdir}" >&2
    return 3
  fi
  if [[ ! -d "${destdir}" ]]; then
    warn "load_config: Zielpfad existiert nicht: ${destdir}" >&2
    return 4
  fi

  # Validierung des Modus
  local allowed_modes=("backup" "restore" "compare")
  if [[ -n "$mode" ]]; then
    case "$mode" in
      "backup"|"restore"|"compare")
        : # ok
        ;;
      "production")
        # Alias: production -> backup (Standard-Operation)
        mode="backup"
        ;;
      *)
        echo "load_config: ungültiger Modus: $mode (erlaubt: ${allowed_modes[*]} oder alias 'production')" >&2
        return 5
        ;;
    esac
  else
    # Standardwert festlegen
    mode="backup"
  fi

  return 0
}


echo ""
echo "------------------------------------------------------------"
echo "Backup Blockchain on TrueNAS"
echo "$version"
echo "------------------------------------------------------------"

# usefull environment detection
is_truenas=false; is_zfs=false; is_docker=false
if uname -r 2>/dev/null | grep -q "truenas"; then is_truenas=true; fi
if command -v midclt >/dev/null 2>&1; then is_truenas=true; fi
if command -v zfs >/dev/null 2>&1; then is_zfs=true; fi
if command -v docker >/dev/null 2>&1; then is_docker=true; fi


# --- load configuration from file
if [[ -n "$cfgfile" ]]; then
  if [[ -f "$cfgfile" ]]; then
    load_config "$cfgfile" # CLI-Werte priorisieren
  else
    on_error "config file not found: $cfgfile" >&2
    exit 1
  fi
fi


#todo allow service selection strategy (first|all|round-robin)
get_service_for_host() {
    local host="$1"
    local line services

    # Suche Host-Zeile im Mapping
    line="$(printf '%s\n' "$host_service_map" | awk -F: -v h="$host" '$1==h {print $2}')"

    if [ -z "$line" ]; then
        # kein Mapping gefunden
        return 1
    fi

    # erster Dienst aus Komma-separierter Liste
    services="${line%%,*}"

    if [ -n "$services" ]; then
        echo "$services"
        return 0
    fi
    return 1
}

# --- Helper: Konvertiert Arrays in sinnvolle Strings
to_list_string() {
  local arr=("$@")
  printf "%s" "${arr[*]}"
}

# --- Logik: Loop über alle Dienste für den aktuellen Hosts
init_logic() {
# Alle Services des Hosts holen
service_list_str="$(get_services_for_host "$host")"

# In Array umwandeln
read -r -a service_list <<< "$service_list_str"

# Falls leer, Default service setzen
if [ ${#service_list[@]} -eq 0 ]; then
  service_list=( "${SERVICES[$DEFAULT_SERVICE_INDEX]}" )
fi

# Schleife über alle Services
for service in "${service_list[@]}"; do
  echo "Verarbeite Dienst: $service"

  # Pfade jeweils für Service setzen
  srcdir="/mnt/ssd/blockchain/$service"
  #destdir="/mnt/tank/backups/blockchain/$service"

  # prepare pro Service aufrufen
  prepare "$service"

done
}

# --- Logik: Destination ermitteln, basierend auf Rolle, Pool und Dataset
init_role() {
# Annahme: Rolle, Pool, Dataset werden gesetzt; Falls nicht vorhanden, Default-Werte verwenden
role="${ROLE:-default}"      # Fallback
pool="${POOL:-ssd}"
dataset="${DATASET:-blockchain}"

# Falls ROLE/POLL/DATASET als Arrays definiert sind, wähle passenden Eintrag
# Falls pro-Host/Rollenspezifische Zuordnungen, ersetze diese Logik durch Mapping-Funktionen

# Beispiel: Standard-Destinationsbasis je Rolle
case "$role" in
  "full-node")
    destroot="$base_dest/production/$thishost/$service"
    ;;
  "backup-node")
    destroot="$base_dest/backups/$thishost/$service"
    ;;
  "validator")
    destroot="$base_dest/validators/$thishost/$service"
    ;;
  "worker")
    destroot="$base_dest/workers/$thishost/$service"
    ;;
  "storage")
    destroot="$base_dest/storage/$thishost/$service"
    ;;
  "monitoring")
    destroot="$base_dest/monitoring/$thishost/$service"
    ;;
  "testing")
    destroot="$base_dest/testing/$thishost/$service"
    ;;
  *)
    destroot="$base_dest/default/$thishost/$service"
    ;;
esac

# Beispiel: Zusätzliche Unterscheidung pro Pool
case "$pool" in
  "ssd")
    pool_sub="ssd"
    ;;
  "hdd")
    pool_sub="hdd"
    ;;
  "raid")
    pool_sub="raid"
    ;;
  "tank")
    pool_sub="tank"
    ;;
  "")
    pool_sub="default"
    ;;
esac

# Beispiel: Dataset-Subpfade (Subvolumes oder einfache Verzeichnisse)
dataset_sub="${dataset}"

# Finaler destdir (Pfad der Backups, ggf. mit Subvolumes)
# Unterscheidung is_btrfs/is_zfs für spezielle Behandlung
destdir="$destroot/$pool_sub/$dataset_sub"

# BTRFS-Subvolumes
# if [ "$is_btrfs" == true ]; then
#   subvol="$dataset_sub"
#   destdir="$destroot/$pool_sub/$subvol"
# fi

echo "Berechnetes Zielverzeichnis: ${destdir}"
}


# Bestimme den Dienst für diesen Host, sofern nicht explizit per CLI oder Config gesetzt
if [ -z "${service:-}" ]; then
    service="$(get_service_for_host "$thishost")"

    if [ -z "$service" ]; then
        service="$default_service"
        log "no host-specific service found, using default_service: $service"
    else
        log "service determined via host mapping: $service"
    fi
else
    log "service preset (CLI/config): $service"
fi


# Rollen-spezifische Standardwerte (überschreibt CLI nur, wenn nötig)
if [ -z "${role:-}" ]; then
  role="default"
fi

# Rollenbasierte Pfade oder Features
case "$role" in
  production)
    backup_interval="6h"
    enable_strict_checks=true
    ;;
  *-node|validator)
    backup_interval="3h"
    enable_strict_checks=true
    validator_mode="active"
    ;;
  tester)
    backup_interval="1h"
    enable_rollback_test=true
    ;;
  *)
    backup_interval="24h"
    ;;
esac

# Rollenabhängige Aktionen (Beispiel-Hook)
if [ "$role" = "validator" ]; then
  echo "Validator-Node: zusätzliche Integritätsprüfungen aktivieren..."
  # z.B. spezielle Prüfsummen-Checks
fi

# Beispiel: Unterschiedliche Destination je nach Rolle
case "$role" in
  *-node|validator|production)
    destdir="/mnt/tank/backups/production/$thishost/$service"
    ;;
  tester)
    destdir="/mnt/tank/backups/testing/$thishost/$service"
    ;;
  *)
    destdir="/mnt/tank/backups/$service"
    ;;
esac


# --- mount destination
mount_dest() {
if [[ "$use_usb" == true ]]; then
    nasmount="/mnt/usb/${nasshare}"
    mkdir -p "$nasmount" || on_error "USB mountdir konnte nicht angelegt werden"

    [[ -n "$usb_dev" ]] || on_error "USB device $usb_dev existiert nicht"

    mountpoint -q "$nasmount" || mount "$usb_dev" "$nasmount" || on_error "USB mount fehlgeschlagen"

    [[ -f "${nasmount}/usb.dummy" ]] || on_error "Ungültiges USB Sicherungsmedium"
    [[ -w "$nasmount" ]] || on_error "USB Ziel ist nicht beschreibbar"

    is_mounted=true
    log "USB Sicherungsmedium $usb_dev erfolgreich eingehängt."
else
    local cifs_opts=""
    if [[ -n "$cifscreds" ]]; then
        cifs_opts="credentials=${cifscreds}"
    else
        cifs_opts=username="${nasuser}"
    fi

    nasmount="${nasmount:-/mnt/${NASHOSTNAME}/${nasshare}}"
    mkdir -p "${nasmount}" || on_error "NAS mountdir konnte nicht angelegt werden"

    mountpoint -q "${nasmount}" || mount -t cifs \
        -o rw,vers=3.1.1,${cifs_opts},noserverino \
        "//${NASHOST}/${nasshare}" "$nasmount" || on_error "Mount NAS share fehlgeschlagen"

    if [ -f "${nasmount}/${NASHOSTNAME}.dummy" ] && [ -f "${nasmount}/dir.dummy" ]; then
        log "mount: Network share ${nasmount} mounted, validated."
    fi

    [[ -w "${nasmount}/" ]] || on_error "mount: ${nasmount} on //${NASHOST}/${nasshare} is NOT writable. Exit."

    is_mounted=true
    echo "mount: Freigabe ${nasshare} erfolgreich eingehängt."
fi
}


# --- unmount destination (nas share, usb drive)
unmount_dest() {
    sync

    if mountpoint -q "$nasmount"; then
        umount "$nasmount" && log "unmount_dest: $nasmount wurde ausgehängt."
    else
        log "unmount_dest: Aushängen von $nasmount übersprungen, nicht eingehängt."
    fi
}


# --- evaluate environment
prepare() {
  # construct paths (srcdir, destdir), basierend auf Machine
  nasmount="${nasmount:-/mnt/${NASHOSTNAME}/${nasshare}}"

  # Bestimme Service-spezifische Einstellungen
  is_zfs=false
  is_splitted=false
  pool=""
  dataset=""

  case "${service}" in
    bitcoind)
      if [[ "$thishost" == "deop9020m" ]]; then
        is_zfs=true
        is_splitted=false
        pool="tank-deop9020m"
        dataset="$pool/blockchain/${service}"
        if [[ "$restore" == false ]]; then
          srcdir="/mnt/$dataset"
        else
          destdir="/mnt/$dataset"
        fi
        # fallback, falls srcdir noch nicht gesetzt ist
        [[ -n "${srcdir}" ]] || srcdir="$nasmount/${service}"
        log "prepare: ${service} on host deop9020m ${service}"
      elif [[ "$thishost" == "hpms1" ]]; then
        is_zfs=true
        is_splitted=true
        pool="ssd"
        dataset="$pool/blockchain/${service}"
        if [[ "$restore" == false ]]; then
          srcdir="/mnt/$dataset"
        else
          destdir="/mnt/$dataset"
        fi
        [[ -n "${srcdir}" ]] || srcdir="$nasmount/${service}"
        log "prepare: ${service} on host hpms1"
      fi
      ;;
    monerod)
      if [[ "$thishost" == "hpms1" ]]; then
        is_zfs=true
        is_splitted=true
        pool="ssd"
        dataset="$pool/blockchain/${service}"
        if [[ "$restore" == false ]]; then
          srcdir="/mnt/$dataset"
        else
          destdir="/mnt/$dataset"
        fi
        [[ -n "${srcdir}" ]] || srcdir="$nasmount/${service}"
        log "prepare: ${service} on host hpms1"
      fi
      ;;
    electrs)
      if [[ "$thishost" == "hpms1" ]]; then
        is_zfs=true
        is_splitted=false
        pool="tank"
        dataset="$pool/blockchain/${service}"
        if [[ "$restore" == false ]]; then
          srcdir="/mnt/$dataset"
        else
          destdir="/mnt/$dataset"
        fi
        [[ ! -n "${srcdir}" ]] && srcdir="$nasmount/${service}"
        log "prepare: ${service} on host hpms1"
      fi
      ;;
    mempool)
      if [[ "$thishost" == "hpms1" ]]; then
        is_zfs=true
        is_splitted=false
        pool="tank"
        dataset="$pool/blockchain/${service}"
        if [[ "$restore" == false ]]; then
          srcdir="/mnt/$dataset"
        else
          destdir="/mnt/$dataset"
        fi
        [[ -n "${srcdir}" ]] || srcdir="$nasmount/${service}"
        log "prepare: ${service} on host hpms1"
      fi
      ;;
    *)
      warn "prepare: blockchain or service=$service not defined."
      return 1
      ;;
  esac

  # to usb drive (optional)
  if [[ "$use_usb" == true ]]; then
    destdir="/mnt/usb/${nasshare}/${service}"
  fi

# --- define rsync opts
  case "${service}" in
    bitcoind)
        rsync_opts="-avihH -P --fsync --mkpath --stats --delete" ;;
    monerod)
        #rsync_opts="-avz -P --inplace --append-verify" # disabled, big performance problems
        rsync_opts="-avihH -P --fsync --mkpath --stats --delete --info=progress2" # temporary used for performance test
        ;;
    *)
        # all other
        rsync_opts="-avzsh -P --update --stats --delete" ;;
  esac
  [[ "$restore" == true ]] && rsync_opts="-avz -P --append-verify --info=progress2"
  [[ "$dry" == true ]] && rsync_opts+=" --dry-run"
  log "prepare: rsync_opts=${rsync_opts}"

# -- define app/service log file
  case "${service}" in
    bitcoind) applogfile="${srcdir}/debug.log" ;;
    monerod)  applogfile="${srcdir}/bitmonero.log" ;;
    electrs)  applogfile="${srcdir}/db/bitcoin/LOG" ;;
    mempool)  applogfile="" ;;
    *)        warn "prepare: applogfile for service ${service} not defined"; return 1 ;;
  esac

  # show construct
  echo ""
  echo "Evaluated environment summary"
  echo "------------------------------------------------------------"
  echo "Blockchain or service is: ${service}"
  echo "Service log file is     : ${applogfile}"
  echo "Source path             : ${srcdir}"
  echo "Destination path        : ${destdir}"
  echo "------------------------------------------------------------"
  log "prepare: direction ${srcdir} -> ${destdir}"
  if [ ! -d "${srcdir}" ] || [ "${srcdir}" == "" ]; then on_error "prepare: srcdir wrong or not defined"; fi
  echo "[ ? ] Please verify source and destination paths."
  echo "Network share will be in 5s mounted or ssh connected."
  sleep 6

  mount_dest
  if [[ "${is_mounted}" != true ]]; then
    log "Destination not mounted. Exit."
    exit 1
  fi
}


# --- stop docker container
stop_service() {
  # sicherstellen, dass im richtigen Verzeichnis gearbeitet wird
  cd "${srcdir}" || return 1

  # Truenas App beenden (auskommentiert, da es nicht zuverlässig ist)
  # case "${service}" in
  #   bitcoind|monerod|electrs|mempool)
  #     midclt call apps.stop "{\"id\":\"${service}\"}" 2>&1
  #     ;;
  # esac

  # Docker Container stoppen
  if [[ "$is_docker" == false ]]; then
    on_error "stop_service: Docker nicht verfügbar"
    return 1
  fi

  if [[ -n "${ctname}" ]]; then
    log "stop_service: Stoppe ${service} Container ${ctname}..."
    docker stop --timeout 20 "$ctname" \
      || { warn "Erzwinge Stoppen des Container ${ctname}..."; docker kill "$ctname"; }
    is_svcup=false
  else
    local containers
    containers=$(docker ps -q --filter "name=${service}")

    if [[ -z "$containers" ]]; then
      log "stop_service: Kein laufender Container für ${service}"
      is_svcup=false
      return 0
    fi

    log "stop_service: Stoppe ${service} Container ${containers}..."
    docker stop --timeout 20 ${containers} \
      || { warn "Erzwinge Stoppen des Container ${containers}..."; docker kill ${containers}; }
    is_svcup=false
  fi

  parse_log_status
}


# --- parse log file, search log file
parse_log() {
    cd "${srcdir}" || return 1

if [[ -z "${applogfile:-}" ]]; then
    on_error "parse_log: Keine Logdatei für Dienst ${service} definiert."
    return 1
elif [[ -f "${applogfile}" ]]; then
    # Logdatei vorhanden
    # log "parse_log: Logdatei ${applogfile} gefunden."
    return 0
else
    # Fallback: debug_h<height>.log
    local base baklogfile
    base="${applogfile%.*}"
    baklogfile="${base}_h${height}.log"

    if [[ -f "${baklogfile}" ]]; then
        applogfile="${baklogfile}"
        warn "parse_log: Fallback auf gesicherte Logdatei ${baklogfile}"
        return 0
    else
        on_error "parse_log: Keine Logdateien gefunden ${applogfile}, ${baklogfile}"
        return 1
    fi
fi
}


# --- parse state from log file
parse_log_status() {
    parse_log
    case "${service}" in
        bitcoind)
            grep -q "Shutdown done" "${applogfile}" && is_svcup=false || is_svcup=true
            ;;
        monerod)
            grep -q "Cryptonote protocol stopped successfully" "${applogfile}" && is_svcup=false || is_svcup=true
            ;;
        electrs)
            grep -q "Shutdown complete" "${applogfile}" && is_svcup=false || is_svcup=true
            ;;
        *)
            is_svcup="unknown"
            ;;
    esac
    log "parse_log_status: Service status ${service}: ${is_svcup}"
}


# --- parse height from log file
parse_log_height() {
  parse_log

  case "${service}" in
    bitcoind)
      # Beispielzeile: ... UpdateTip: new ... height=934626 version=0x20068000 ...
      parse_keyword="UpdateTip"
      parse_key="height="
      height_line=$(tail -n20 "$applogfile" | grep "$parse_keyword" | tail -n1)
      parsed=$(echo "$height_line" | grep -Eo "${parse_key}[0-9]+" | sed "s/${parse_key}//")
      ;;
    monerod)
      # Beispielzeile: ... I Synced 3272808/3600775 (90%...
      # Beispielzeile: ... Sync data returned a new top block candidate: 3270908 -> 3600729 [Your node is 409014 blocks ...
      parse_keyword="Synced"
      parse_key="/"  # erster wert vor slash bzw. nach Synced
      height_line=$(tail -n20 "$applogfile" | grep "$parse_keyword" | tail -n1)
      parsed=$(echo "$height_line" | awk -F'/' '{print $1}' | tr -d ' ')
      ;;
    electrs)
      # kein parsing nötig (height kann von bitcoind/debug.log übernommen werden)
      parsed="0"
      ;;
    *)
      parsed=""
      ;;
  esac

  if [[ -z "$parsed" ]]; then
    parsed_height=0
    on_error "parse_log_height: Parsing error, parsed=$parsed"
    return 1
  else
    parsed_height="$parsed"
  fi

  echo "------------------------------------------------------------"
  log "parse_log_height: Parsed height from $applogfile: $parsed_height"
}


# --- compare height src-dest based on file modification times
# info: %y=readable, %Y=unix timestamp
compare_height() {
  local service="${service:-}"
  local srcsynctime=0
  local destsynctime=0

  case "${service}" in
    bitcoind)
      if [ -e "${srcdir}/chainstate/CURRENT" ]; then
        srcsynctime=$(stat -c %Y "${srcdir}/chainstate/CURRENT" 2>/dev/null || echo 0)
      fi
      if [ -e "${destdir}/chainstate/CURRENT" ]; then
        destsynctime=$(stat -c %Y "${destdir}/chainstate/CURRENT" 2>/dev/null || echo 0)
      fi
      ;;
    monerod)
      if [ -e "${srcdir}/lmdb/data.mdb" ]; then
        srcsynctime=$(stat -c %Y "${srcdir}/lmdb/data.mdb" 2>/dev/null || echo 0)
      fi
      if [ -e "${destdir}/lmdb/data.mdb" ]; then
        destsynctime=$(stat -c %Y "${destdir}/lmdb/data.mdb" 2>/dev/null || echo 0)
      fi
      ;;
    electrs)
      if [ -e "${srcdir}/db/bitcoin/CURRENT" ]; then
        srcsynctime=$(stat -c %Y "${srcdir}/db/bitcoin/CURRENT" 2>/dev/null || echo 0)
      fi
      if [ -e "${destdir}/db/bitcoin/CURRENT" ]; then
        destsynctime=$(stat -c %Y "${destdir}/db/bitcoin/CURRENT" 2>/dev/null || echo 0)
      fi
      ;;
    *)
      err "compare_height: Unbekannter Dienst '${service}'" >&2
      return 2
      ;;
  esac

  # Prüfen, ob beide Zeiten vorhanden sind
  if [ -z "${srcsynctime}" ] || [ -z "${destsynctime}" ]; then
    warn "compare_height: Fehlende Zeitstempel src=${srcsynctime}, dest=${destsynctime}"
    return 1
  fi

  if [ "${srcsynctime}" -gt "${destsynctime}" ]; then
    log "compare_height: src is newer than destination"
    return 10
  elif [ "${srcsynctime}" -lt "${destsynctime}" ]; then
    log "compare_height: destination holds newer than source"
    return 20
  else
    log "compare_height: src and dest have identical timestamps"
    return 30
  fi
}


# --- compare/verify src dest dirs
compare_dirs() {
  # sicherstellen, dass srcdir/destdir gesetzt sind
  if [[ -z "${srcdir:-}" ]]; then
    err "compare_dirs: srcdir ist leer"
    return 1
  fi
  if [[ -z "${destdir:-}" ]]; then
    err "compare_dirs: destdir ist leer"
    return 1
  fi
  if [[ ! -d "${srcdir}" || ! -d "${destdir}" ]]; then
    on_error "compare_dirs: Verzeichnisse existieren nicht: ${srcdir}, ${destdir}"
    return 1
  fi

  echo "Vergleiche ${srcdir} mit ${destdir}..."

  local diffs
  # Zähle Unterschiede via rsync-Output (nur Dateien, Änderungen, etc.)
  diffs=$(rsync -ani "${srcdir}/" "${destdir}/" 2>/dev/null | grep -E '^[<>ch]' | wc -l)

  if [[ "$diffs" -eq 0 ]]; then
    log "compare_dirs: No differences between source and destination."
  else
    log "Differences detected: ${diffs} items"
    rsync -ani "${srcdir}/" "${destdir}/"
    # todo frage ob merge_dirs() ausgeführt werden soll
  fi
}


merge_dirs() {
snapshot_main

  case "${service}" in
    bitcoind)
      ;;
    monerod)
      ;;
    electrs)
      ;;
    mempool)
      ;;
    *)
      err "merge_dirs: Unbekannter Dienst '${service}'" >&2
      return 1
      ;;
  esac


# ...
compare_dirs
}


# --- pre-backup tasks
prebackup() {
  cd "${srcdir}" || return 1

  log "prebackup: Prüfe Service-Zustand..."
  parse_log_status

  if [[ "${is_svcup}" == true ]]; then
    log "Service läuft, wird gestoppt..."
    stop_service
  fi

  # bitcoind.pid-Watchdog (TrueNAS Bug)
  if [[ "${service}" == "bitcoind" && -f "${srcdir}/bitcoind.pid" ]]; then
    warn "Warte auf sauberen Shutdown von bitcoind..."
    while [[ -f "${srcdir}/bitcoind.pid" ]]; do
      sleep 5
    done
    is_svcup=false
    log "prebackup: ${service} ist nun gestoppt"
  fi

  if [[ "${is_svcup}" != false ]]; then
    warn "prebackup: Service-Zustand ist unklar - Backup erfolgt auf eigenes Risiko"
  fi

  #-variable: numeric check
  height="${height:-0}"
  if ! [[ "$height" =~ ^[0-9]+$ ]]; then
    height=0
  fi

  # height auslesen, wenn nicht gegeben
  if [[ "${height}" -lt 111111 ]]; then
    parse_log_height || true
    compare_height
    case "$?" in
      10)
        log "compare_height: Quelle ist neuer als das Ziel"
        ;;
      20)
        warn "compare_height: Ziel ist neuer als die Quelle"
        ;;
      30)
        log "compare_height: Quelle und Ziel sind identisch"
        ;;
    esac
  fi

  rotate_log
  echo "Info: Ideal time to take a snapshot is now."
  echo "------------------------------------------------------------"
}


# --- update height stamp, rotate log file
rotate_log() {
  cd "${srcdir}" || return 1

  log "Rotate log files on height=${height}"
  local suffix=""
  if [[ "${is_svcup}" == true ]]; then
    suffix="-unclean"
  fi

  # setze neue Blockhöhe-Markierung (z.B. h900100) und rotiere die Logdatei
  # ist hier shopt wirklich nötig? h* ist z.B. h900100
  shopt -s nullglob
  mv -u h* "h${height}${suffix}" 2>/dev/null || true
  shopt -u nullglob

  case "${service}" in
    bitcoind)
      if [[ -f debug.log ]]; then
        mv -u debug.log "debug_h${height}${suffix}.log" 2>/dev/null || true
      fi
      ;;
    monerod)
      if [[ -f bitmonero.log ]]; then
        mv -u bitmonero.log "bitmonero_h${height}${suffix}.log" 2>/dev/null || true
      fi
      ;;
    electrs)
      if [[ -f db/bitcoin/LOG ]]; then
        cp -u db/bitcoin/LOG "electrs_h${height}${suffix}.log" 2>/dev/null || true
        rm -f db/bitcoin/LOG.old.* 2>/dev/null || true
      fi
      ;;
  esac
}


# --- snapshot task
snapshot_main() {
  # --- snapshot zfs dataset
  if [[ "${is_zfs}" == true ]]; then
    log "snapshot_main: Prepare dataset ${dataset} for a snapshot..."
    sync
    sleep 1

    local snapname="script-$(date +%Y-%m-%d_%H-%M)"

    # Prüfen, ob Dataset existiert
    if ! zfs list "${dataset}" >/dev/null 2>&1; then
      on_error "Dataset ${dataset} existiert nicht. Snapshot wird abgebrochen."
      return 1
    fi

    # Snapshot erstellen
    if ! zfs snapshot -r "${dataset}@${snapname}"; then
      on_error "snapshot_main: Snapshot ${dataset}@${snapname} konnte nicht erstellt werden."
      return 1
    fi
    log "snapshot_main: A snapshot '${snapname}' is taken."

    # Snapshot-Rollback-Schutz prüfen
    if ! zfs list -t snapshot "${dataset}@${snapname}" >/dev/null 2>&1; then
      on_error "snapshot_main: Snapshot ${dataset}@${snapname} not found."
      return 1
    fi

    # --- snapshot replication, background task
    # local snapreparchive="tank/backups/replica/${thishost}/${dataset}"
    # if [[ "${thishost}" == "hpms1" ]]; then
    #   snaprepcmd="zfs receive ${snapreparchive}"
    # else
    #   snaprepcmd="ssh hpms1 \"zfs receive ${snapreparchive}\""
    # fi
    # log "send snapshot replica to hpms1"
    # zfs send -I "${dataset}@previous" "${dataset}@latest" | ${snaprepcmd} &

  fi
}


# --- list backups and snapshots
list_backups() {
  if [[ "${is_zfs}" == true ]]; then
    zfs list -t snapshot -r "${dataset}" 2>/dev/null || true
  fi
}


# --- backup task main
backup_main() {
  cd "${srcdir}" || return 1

  local today_time
  today_time=$(date '+%Y-%m-%d %H:%M:%S')
  log "Main task started at ${today_time}"

  # prevent overwrite newer destination
  if [[ "${srcsynctime}" -lt "${destsynctime}" && "${force}" != true ]]; then
    on_error "backup_main: Destination is newer and maybe higher as the source."
    on_error "             Use restore. A --force will ignore this situation. Abort."
    exit 1
  elif [[ "${srcsynctime}" -lt "${destsynctime}" && "${force}" == true ]]; then
    warn "[ ! ] Destination is newer as the source."
    warn " Force will now overwrite it. This will downgrade the destination."
  fi

  echo "------------------------------------------------------------"
  log "Start backup job #0: ${service}"

  case "${service}" in
  bitcoind)
      # bitcoind core config backup
    cp -u anchors.dat banlist.json debug*.log fee_estimates.dat h* mempool.dat peers.dat \
      "${destdir}/" 2>/dev/null || true
    cp -u h* "${destdir}/blocks/" 2>/dev/null || true
    cp -u bitcoin.conf "${destdir}/bitcoin.conf.${thishosts}" 2>/dev/null || true
    cp -u settings.json "${destdir}/settings.json.${thishosts}" 2>/dev/null || true
    # optional folders
    folder=( blocks chainstate indexes )
    ;;
  monerod)
    # monerod config backup
    cp -u bitmonero*.log h* p2pstate.* rpc_ssl.* "${destdir}/" 2>/dev/null || true
    cp -u h* "${destdir}/lmdb/" 2>/dev/null || true
    folder=( lmdb )
    ;;
  electrs)
    # electrs config backup
    folder=( db )
    ;;
  mempool)
    # mempool config backup
    folder=( db )
    ;;
  *)
    # Default leer, wenn kein Dienst passt
    if [[ -z "${folder+x}" ]]; then
    folder=()
    fi
    err "merge_dirs: Unbekannter Dienst '${service}'" >&2
      return 1
      ;;
  esac

# merge splitted datasets
#log "Start merge job: ${service}"
#merge_dirs

  # Backup data in subfolders
  local i
  for i in "${!folder[@]}"; do
    local sub_folder="${folder[i]}"
    echo "------------------------------------------------------------"
    log "Start backup job #$((i+1)): ${service}/${sub_folder}"
    if command -v ionice >/dev/null 2>&1; then
      ionice -c2 rsync ${rsync_opts} --exclude '.nobakup' --exclude '.ignore' \
        "${srcdir}/${sub_folder}/" "${destdir}/${sub_folder}/"
    else
      rsync ${rsync_opts} --exclude '.nobakup' --exclude '.ignore' \
        "${srcdir}/${sub_folder}/" "${destdir}/${sub_folder}/"
    fi
    if [[ $? -ne 0 ]]; then
      warn "backup_main: Errors during backup ${destdir}/${sub_folder}."
      sync
    fi
  done
  echo "------------------------------------------------------------"

compare_dirs # verify
}


# --- backup task machine-based configs
backup_configs() {
  cd "${srcdir}" || return 1
  local today_long today_short destdir tarsrcdir1 tarsrcdir2 tarsrcdir3
  today_short=$(date +%y%m%d)

# destination target local/remote
case "$target" in
    local|remote|network|share)
        : # gültig → nichts tun
        ;;
    *)
        target=""
        ;;
esac

if [[ -z "$target" ]]; then
    while :; do
        read -rp "use target: local or remote|network|share ? " target
        case "$target" in
            local|remote|network|share)
                break
                ;;
            *)
                warn "Invalid target: '$target' - please choose local, remote, network or share"
                ;;
        esac
    done
fi

  case "$target" in
    local)
        # send to local archive
        destdir_machine="${DEST_MACHINE_BASE:-/mnt/tank/backups/machines/$thishost}"
      ;;
    remote|network|share)
        # send to remote share
        destdir_machine="${destdir_machine:-${nasmount}/machines/${thishost}}"
      ;;
  esac
  mkdir -p "${destdir_machine}/$today_short"

# run backup system configs
    tarsrcdir1="/var/db/system/configs-*" # truenas system-configuration
    tarsrcdir2="/mnt/.ix-apps" #truenas apps-configuration
    tarsrcdir3=""

# sanity check before backup
if command -v systemctl >/dev/null &&
    systemctl is-active ix-applications >/dev/null; then
    warn "WARNING: ix-applications running - backup may be inconsistent" >&2
fi

# tar-Jobs im Hintergrund parallel starten
declare -A job_pids
shopt -s nullglob
i=1
while declare -p "tarsrcdir$i" &>/dev/null; do
    var="tarsrcdir$i"
    src="${!var}"
    [[ -z "$src" ]] && { ((i++)); continue; }

    today_long=$(date +%y%m%d%H%M)
    destfile="${destdir_machine}/${today_short}/configs${i}-${today_long}.tar.gz"

set +e  # Fehler innerhalb Subshell ignorieren
tar \
    --exclude="*ignore*" \
    --exclude=".nobackup" \
    --exclude=docker \
    --exclude=truenas_catalog \
    -zcvf "$destfile" $src \
    2>/dev/null &

    job_pids[$i]=$! # PID des letzten Jobs
    ((i++))
done
shopt -u nullglob

# Status der Jobs einsammeln
for i in "${!job_pids[@]}"; do
    pid="${job_pids[$i]}"
    if wait "$pid"; then
        log "backup_configs: Job $i finished successfully"
    else
        warn "backup_configs: Job $i FAILED"
    fi
done
}


# --- restart service
start_service() {
  # todo: abfrage ob container wieder gestartet werden soll
  if [[ -n "${ctname}" ]]; then
    log "start_service: Starte ${service} Docker-Container ${ctname}..."
    if docker start "${ctname}"; then
      log "start_service: Container ${ctname} gestartet."
      parse_log_status
    else
      warn "start_service: Container ${ctname} konnte nicht gestartet werden."
    fi
  fi
}


# --- post-backup tasks
postbackup() {
  if [[ "${restore}" == false ]]; then
    height=0  # reset height

    # cleanup snapshot (optional, auskommentiert als Vorlage)
    # if [[ -n "$dataset" && -n "$snapname" ]]; then
    #   log "postbackup: Entferne letztes Snapshot ${dataset}@${snapname}"
    #   zfs destroy "${dataset}@${snapname}" || true
    # fi

    # vorherigen zustand wiederherstellen (Platzhalter)
    # TODO: war $is_svcup vor Sicherung true oder false?
    # Beispiel: if [[ "$last_svcup" == "true" ]]; then ... fi

    start_service
  else
    # Besitzrechte im Zielverzeichnis sicherstellen
    chown -R apps:apps "${destdir}"

    if [[ "${service}" == "bitcoind" ]]; then
      # Berechtigungen für Block-Dateien anpassen
      chmod ugo+r,ugo-wx "${destdir}/blocks/*.dat" 2>/dev/null || true
    fi
  fi

  log "Script ended at ${today_time}"
  log "End."
  echo "------------------------------------------------------------"
}


# --- main logic start
# --- cli parse options
PARSED_OPTIONS="$(getopt -o "" \
  -l mode:,blockchain:,service:,height:,srcdir:,destdir:,usb:,log:,config:,force,debug,dry,help \
  -n "$0" -- "$@")" || {
  echo "Fehler bei der Argument-Interpretation" >&2
  exit 1
}
eval set -- "$PARSED_OPTIONS"
[[ "${debug:-false}" == true ]] && echo "#debug# starting argument parsing"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --)            shift; break ;;
    -h|--help)        usage; exit 0 ;;
    -m|--mode)        mode="$2"; shift 2 ;;
    -bc|--blockchain)  blockchain="$2"; shift 2 ;;
    -svc|--service)     service="$2"; shift 2 ;;
    -bh|--height)      height="$2"; shift 2 ;;
    -s|--srcdir)      srcdir="$2"; shift 2 ;;
    -d|--destdir)     destdir="$2"; shift 2 ;;
    --usb)         usb_dev="$2"; use_usb=true; shift 2 ;;
    -c|--config)      cfgfile="${2:-}"; shift 2 ;;
    -l|--log)         scriptlogfile="$2"; scriptlogging=true; shift 2 ;;
    -f|--force)       force=true; shift 1 ;;
    --verbose|--debug) debug=true; shift 1 ;;
    --test|--dry|--dry-run) dry=true; shift 1 ;;
    -*)              err "Unbekannte Option: $1"; usage ;;
    *)               shift 1 ;;
  esac
done

# --- usage
usage() {
  cat <<EOF
Usage: $0 <command> [options]
Commands: btc|xmr|electrs|mempool|configs|all|full|restore|mount|umount|list
Options: --mode --service --height --srcdir --destdir --usb --config --log --force --debug --dry
Examples: $0 backup --dry-run --config ./hpms1.conf
EOF
}


# --- cli parse command and positional args
after_break="${1:-}"
arg2="${2:-}"
after_break="${after_break:-backup}" # default command if none given

# set height from 2nd numeric argument (e.g. btc 725300)
if [[ "$arg2" =~ ^[0-9]{1,7}$ ]]; then
  height="$arg2"
else
  height="${height:-0}"
fi

log "mode=$mode argcmd=${after_break} arg2=${arg2} height=$height use_usb=$use_usb force=$force log=$scriptlogging conf=${cfgfile}"

# --- fill variables by command
cmd="$after_break"

case "$cmd" in
  backup)
    # no-op: use defaults from config / cli
    ;;
  btc|bitcoin|bitcoind)
    blockchain="btc"
    service="bitcoind"
    ctname="ix-bitcoind-bitcoind-1"
    nasshare="blockchain"
    ;;
  xmr|monero|monerod)
    blockchain="xmr"
    service="monerod"
    ctname="ix-monerod-monerod-1"
    nasshare="blockchain"
    ;;
  bh|[0-9][0-9][0-9][0-9][0-9][0-9]*)
    height="$arg2"
    ;;
  electrs)
    service="electrs"
    nasshare="backups"
    ;;
  mempool)
    service="mempool"
    nasshare="backups"
    ;;
  configs)
    nasshare="backups"
    ;;
  all|full)
    # all services, local backup
    nasshare="backups"
    destdir=/mnt/tank/backups/blockchain/$service
    ;;
  restore)
    restore=true
    mode="restore"
    ;;
  list)
    list_backups
    ;;
  debug)
    debug=true
    set -x # troubleshooting output
    set -euo pipefail
    ;;
  mount|umount)
    nasshare="${nasshare:-backups}"
    ;;
  *)
    echo "Unknown command: ${cmd}" >&2
    usage
    exit 1
    ;;
esac
echo "reached after fill: cmd=$cmd"

log "svc:${service} h=${height} share=${nasshare} mode=${mode} restore=${restore}"

# --- the execute part
case "$cmd" in
  mount)
    nasshare=backups
    mount_dest
    nasshare=blockchain
    mount_dest
    ;;
  umount)
    nasshare="${nasshare:-backups}"
    unmount_dest
    ;;
  configs)
    prepare
    backup_configs
    [[ "$use_usb" == true ]] && unmount_dest
    ;;
  restore)
    if [[ "$force" != true ]]; then
      on_error "Task ignored while --force not given."
      exit 1
    fi
    if [[ "$force" == true ]]; then
      echo "------------------------------------------------------------"
      warn "RESTORE: Richtung Source <-> Destination ist jetzt geändert."
    prepare
    prebackup
    backup_main
    postbackup
    [[ "$use_usb" == true ]] && unmount_dest
    fi
    ;;
  all|full)
    prepare
    backup_configs
    prebackup
    snapshot_main
    backup_main
    postbackup
    [[ "$use_usb" == true ]] && unmount_dest
    ;;
  backup|btc|xmr|electrs|mempool)
    # default case
    prepare
    prebackup
    snapshot_main
    backup_main
    postbackup
    [[ "$use_usb" == true ]] && unmount_dest
    ;;
esac
# --- main logic end
exit

# =============================================================================
# deactivated, snippets and draft workspace #

#skeleton
  case "${service}" in
  bitcoind)
      ;;
  monerod)
      ;;
  electrs)
      ;;
  mempool)
      ;;
  *)
      err "Unbekannter Dienst '${service}'" >&2
      return 1
      ;;
  esac


# We can also print the arguments using a while loop and the environmental variables
i=$(($#-1))
while [ $i -ge 0 ];
do
    echo ${BASH_ARGV[$i]}
    i=$((i-1))
done


# --- purge destination
clean_dest() {
echo "------------------------------------------------------------"
log "clean_dest: REMOVE ALL content in ${destdir}"
    [[ "$force" != true ]] && on_error "clean_dest: [ ! ] Task ignored, --force not given. Exit." && exit 1
    on_error "clean_dest(): --destdir muss explizit gegeben werden. Abbruch."

    warn "clean_dest: REMOVE ALL content in ${destdir}"
    # todo: hier eine starke sicherheitsabfrage einbauen
    exit # vorsorglich abbruch, bis abgesichert
    [[ "$force" == true ]] && rm -i -r ${destdir}/* # preserve top dir (eg. share, dataset)
log "clean_dest: Cleanup task done."
sync
df -h | grep ${destdir}
}


# =============================================================================
# todo's and implementing ideas

# todo: trigger zettarepl task after take_snapshot()
# todo: how to cli trigger a truenas implemented rsync task?
# todo: merge splitted dataset over multiple pools ssd+tank
# todo: $service==mempool, replace rsync with mysqldump, then include as cp -u (job #0)
# todo: system-/apps-configuration, complete the backup_configs() part
# todo: include --srchostname <hostname> --desthostname <hostname> # eg. start9
# todo: --srcdir DIR or --destdir DIR # override collecting vars in prepare(), the start with prebackup()
# todo: monerod/lmdb/data.mdb, performance test with block mode --inplace, or other possibilies
# todo: blockchain datasets on iscsi, performance?
# todo: prebackup(), replace cp -u/mv -u with rsync
# todo: dry|dry-run) dry=true not overall implemented, eg. job #0 for copy/move
# todo: -t|--test simulate, next level of dry-run, don't stop $service
# todo: longtime archive, link versioned backups on usb-destination, use rsync --link-dest
# todo: clean_dest() mehrfach und ausreichend absichern, wurde vorsorglich deaktiviert
# todo: sprache - global alle ausgaben auf english übersetzen, grammatikprüfung
# todo: take_snapshot(), hold/never destroy a snapshot
# todo: --config file, create/generate example $cfgfile.dist with $0
# todo: healthcheck JSON output for monitoring
# todo: --verbose|--debug trennen

# ---

monerod, rsync performance problem with big database file data.mdb
rsync_opts="-avz -P --inplace --append-verify"

[..] 2026-01-31 02:18:59 Start backup job #1: monerod/lmdb
sending incremental file list
./
data.mdb
212,595,912,704 100%   49.58MB/s    1:08:09 (xfr#1, to-chk=2/4)
h3190556
              0 100%    0.00kB/s    0:00:00 (xfr#2, to-chk=1/4)
WARNING: data.mdb failed verification -- update retained (will try again).
data.mdb
212,595,912,704 100%   23.02MB/s    2:26:48 (xfr#3, to-chk=2/4)

sent 53,933,775,511 bytes  received 32,441,644 bytes  3,469,492.25 bytes/sec
total size is 212,595,920,896  speedup is 3.94
2026-01-31 06:38:14 ------------------------------------------------------------
2026-01-31 06:38:15 start_service: Starte monerod Docker-Container ix-monerod-monerod-1...
Error response from daemon: No such container: ix-monerod-monerod-1
Error: failed to start containers: ix-monerod-monerod-1
2026-01-31 06:38:17 Script ended at 02:18:03
2026-01-31 06:38:18 End.[..] =============================================================================
