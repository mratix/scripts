#!/usr/bin/env bash
#
# ============================================================
# backup_blockchain_truenas-pacman.sh
# DAU-SAFE / INTERACTIVE VERSION
# ============================================================
# Philosophie:
# - Dieses Script trifft KEINE Entscheidungen alleine
# - Es erklärt, wartet, fragt und wiederholt sich
# - Abbrechen ist jederzeit möglich
# - Exit wenn der User es will
# ============================================================

# --------------------------
# SAFE DEFAULTS (EDIT HERE)
# --------------------------
DEFAULT_SERVICE="btc"               # btc | xmr | xch
DEFAULT_TARGET_HEIGHT=""            # optional
DEFAULT_USER_LEVEL="ask"            # ask | 1 | 2 | 3 | 4 | 5
SCRIPT_NAME="$(basename "$0")"

# --------------------------
# TIMER / GAMIFICATION
# --------------------------
SCRIPT_START_TS=$(date +%s)
LAST_ACTION_TS=$SCRIPT_START_TS
COINS=0

# --------------------------
# LOGGING (LEVELBASIERT)
# --------------------------
# User-Level bestimmt Ausgabemenge
# 1 = sehr viel Erklärung
# 5 = minimal / technisch

log()  { [ "$USER_LEVEL" -le 3 ] && echo "$@"; }
log1() { [ "$USER_LEVEL" -le 1 ] && echo "$@"; }
log2() { [ "$USER_LEVEL" -le 2 ] && echo "$@"; }
log3() { [ "$USER_LEVEL" -le 3 ] && echo "$@"; }
log4() { [ "$USER_LEVEL" -le 4 ] && echo "$@"; }
log5() { [ "$USER_LEVEL" -le 5 ] && echo "$@"; }

warn() { echo "⚠️  $@"; }
err()  { echo "❌ $@"; }

# --------------------------
# HELPER FUNCTIONS
# --------------------------

# einfache ROT12-Verschiebung
rot12() {
  echo "$1" | tr 'A-Za-z0-9' 'M-ZA-Lm-za-l2-90-1'
}

dec_rot12() {
  echo "$1" | tr 'A-Za-z0-9' 'O-9A-N0-1a-no-m'
}

pause() {
  echo
  read -n1 -r -p "Weiter mit beliebiger Taste..."
  echo
}

restart_script() {
  echo
  echo "🔄 Script wird neu gestartet..."
  exec "$0" "$@"
}

ask_continue_or_restart() {
  echo
  echo "Was möchtest du tun?"
  echo "1) Erneut versuchen"
  echo "2) Script von vorne starten"
  echo "3) Jetzt beenden"
  read -rp "Auswahl [1-3]: " _choice

  case "$_choice" in
    1) return 0 ;;
    2) restart_script "$@" ;;
    3) echo "Alles klar. Script beendet."; exit 0 ;;
    *) echo "Ungültige Auswahl."; ask_continue_or_restart "$@" ;;
  esac
}

check_idle_time() {
  local now
  now=$(date +%s)
  local diff=$(( now - LAST_ACTION_TS ))

  if [ "$diff" -ge 300 ]; then
    echo
    echo "🍿 Du stehst schon eine Weile herum (über 5 Minuten)."
    echo "Soll ich dir Popcorn bringen, eine Pizza bestellen oder nach der Brille suchen? 😄"
    pause
    LAST_ACTION_TS=$now
  fi
}

award_coins() {
  local amount="$1"
  COINS=$(( COINS + amount ))
}

show_score() {
  local end_ts elapsed
  end_ts=$(date +%s)
  elapsed=$(( end_ts - SCRIPT_START_TS ))

  echo
  echo "🏁 SESSION ENDE"
  echo "Zeit gebraucht: $((elapsed/60)):$((elapsed%60)) Minuten"
  echo "Erfahrungspunkte: $COINS Coins" && rot12 "$COINS" >> "$HOME/.backup_blockchain-pacman.rewards"
  echo
}

# --------------------------
# USER LEVEL SELECTION
# --------------------------

select_user_level() {
  if [ "$DEFAULT_USER_LEVEL" != "ask" ]; then
    USER_LEVEL="$DEFAULT_USER_LEVEL"
    return
  fi

  echo "Bitte wähle deine Erfahrungsstufe:"
  echo
  echo "1) Absoluter Anfänger (bitte alles erklären und fragen)"
  echo "2) Ich kann mich anmelden und Anweisungen befolgen"
  echo "3) Ich weiß, was im \$HOME ist und kenne meine Daten"
  echo "4) Ich weiß genau, was ich tue (CLI, Pfade, Risiken)"
  echo
  echo "5) Ich bin der Chef oder ein Entwickler"
  read -rp "Auswahl [1-5]: " USER_LEVEL

  case "$USER_LEVEL" in
    1|2|3|4|5) ;;
    *) echo "Ungültige Auswahl."; select_user_level ;;
  esac

  award_coins 10
}

# --------------------------
# SERVICE SELECTION
# --------------------------

select_service() {
  if [ -n "$SERVICE" ]; then
    return
  fi

  echo
  echo "Mit welcher Blockchain möchtest du arbeiten?"
  echo "1) Bitcoin (BTC)"
  echo "2) Monero (XMR)"
  echo "3) Chia (XCH)"
  echo "0) keine oder andere"
  echo
  read -rp "Auswahl [1-3]: " _svc

  case "$_svc" in
    1) SERVICE="btc" ;;
    2) SERVICE="xmr" ;;
    3) SERVICE="xch" ;;
    0) ask_continue_or_restart ;;
    *) echo "Ungültige Auswahl."; select_service ;;
  esac

  award_coins 25
}

# --------------------------
# SERVICE STOP CONFIRMATION
# --------------------------

confirm_service_stopped() {
  log1 "────────────────────────────────────────"
  log1 "WICHTIGER SCHRITT: Service-Status"
  log1 "────────────────────────────────────────"
  log1 "Bevor wir weitermachen, MUSS der betroffene Dienst gestoppt sein."
  log1 "Wenn er noch läuft, können Daten beschädigt werden oder das Backup ist unbrauchbar."
  log1 ""

  log3 "Bitte bestätige, dass der Service '$SERVICE' aktuell NICHT läuft."
  log5 "Service must be stopped before rsync / snapshot operations."

  while true; do
    echo
    echo "Was möchtest du tun?"
    echo "  j) Ja, der Service ist gestoppt"
    echo "  n) Nein / Ich bin mir nicht sicher (ich prüfe das jetzt)"
    echo "  a) Abbrechen"
    read -rp "Auswahl [j/n/a]: " _ans

    case "$_ans" in
      j|J)
        log3 "Okay, wir gehen davon aus, dass der Service gestoppt ist."
        log5 "User confirmed service stopped."
        COINS=$((COINS + 50))
        log1 "👍 Gute Entscheidung! Sicherheit erhöht. (+50 Coins)"
        return 0
        ;;
      n|N)
        log1 "Kein Problem. Nimm dir Zeit und prüfe den Service in Ruhe."
        log1 "Ich warte hier auf dich."
        log5 "User unsure about service state."
        read -rp "Drücke ENTER, wenn du bereit bist weiterzumachen..."
        ;;
      a|A)
        warn "Abbruch gewählt."
        end
        ;;
      *)
        warn "Ungültige Eingabe. Bitte j, n oder a wählen."
        ;;
    esac
  done
}

# --------------------------
# FUN & UX EXTRAS
# --------------------------

pacman_restore_animation() {
  # einfache ASCII-Animation: Pacman frisst Quelle 😄
  local i
  local line="SOURCE_DATA        DESTINATION"

  log5 "Starting pacman restore animation"

  for i in {1..12}; do
    clear
    echo
    echo "🟡  Restore-Visualisierung (nur zur Beruhigung):"
    printf "%*s<:3(" "$((i))"
    echo "$line"
    sleep 0.15
  done

  clear
  echo
  echo "🟡  *chomp chomp* – Quelle wird übernommen."
  sleep 0.4
}

# --------------------------
# SNAPSHOT HANDLING (ZFS)
# --------------------------

# prüft, ob DATADIR ein ZFS-Dataset ist
is_zfs_dataset() {
  zfs list -H -o name "$1" >/dev/null 2>&1
}

# erstellt einen Snapshot, abhängig vom User-Level
create_snapshot() {
  local dataset="$1"
  local reason="$2"

  if ! is_zfs_dataset "$dataset"; then
    return 0
  fi

  local snap_name="backup_safe_${reason}-$(date +%Y-%m-%d_%H-%M)" # respect truenas naming schema

  case "$USER_LEVEL" in
    1|2)
      echo "📸 Sicherheits-Snapshot wird erstellt ($reason)"
      zfs snapshot "${dataset}@${snap_name}" || return 1
      award_coins 20
      ;;
    3)
      echo "📸 Snapshot vor $reason"
      zfs snapshot "${dataset}@${snap_name}" || return 1
      award_coins 10
      ;;
    4|5)
      echo "📸 Snapshot ($reason)"
      zfs snapshot "${dataset}@${snap_name}" || return 1
      ;;
  esac

  return 0
}

# listet Snapshots und erlaubt ggf. Rewind (noch rein dialogisch)
rewind_snapshot_menu() {
  local dataset="$1"

  if ! is_zfs_dataset "$dataset"; then
    echo "Keine ZFS-Snapshots verfügbar."
    return
  fi

  echo
  echo "⏪ Verfügbare Snapshots:"
  zfs list -t snapshot -o name -s creation | grep "^${dataset}@" || return

  echo
  echo "Zurückspulen ist möglich, aber NOCH NICHT aktiviert."
  echo "(DAU-SAFE: erst anzeigen, später erlauben)"
  pause
}

# --------------------------
# LEVEL-UP SYSTEM
# --------------------------

maybe_level_up() {
  # sehr simple Progression
  case "$USER_LEVEL" in
    1) [ "$COINS" -ge 500 ] && { USER_LEVEL=2; echo "🎉 Level Up! Du bist jetzt Level 2."; } ;;
    2) [ "$COINS" -ge 1200 ] && { USER_LEVEL=3; echo "🎉 Level Up! Du bist jetzt Level 3."; } ;;
    3) [ "$COINS" -ge 2500 ] && { USER_LEVEL=4; echo "🎉 Level Up! Du bist jetzt Level 4."; } ;;
    4) [ "$COINS" -ge 5000 ] && { USER_LEVEL=5; echo "🏆 Meister-Level erreicht!"; } ;;
  esac
}

# --------------------------
# RESTORE SOURCE SELECTION
# --------------------------

select_restore_source() {
  log1 "────────────────────────────────────────"
  log1 "RESTORE-QUELLE AUSWÄHLEN"
  log1 "────────────────────────────────────────"

  log1 "Woher sollen die Daten kommen?"
  echo "1) Netzwerk (z.B. NAS, NFS, SMB)"
  echo "2) USB / externe Festplatte"
  echo "3) Lokal (ein Verzeichnis)"
  echo "0) Abbrechen"

  read -rp "Auswahl [0-3]: " _src

  case "$_src" in
    1) RESTORE_SOURCE_TYPE="network" ;;
    2) RESTORE_SOURCE_TYPE="usb" ;;
    3) RESTORE_SOURCE_TYPE="local" ;;
    0) log1 "Restore-Quelle nicht gewählt."; return 1 ;;
    *) warn "Ungültige Auswahl."; return 1 ;;
  esac

  read -rp "Pfad zur Restore-Quelle: " RESTORE_SOURCE

  if [[ ! -d "$RESTORE_SOURCE" ]]; then
    err "Die gewählte Quelle existiert nicht oder ist kein Verzeichnis."
    return 1
  fi

  # Plausibilitätsprüfung
  log1 "────────────────────────────────────────"
  log1 "PLAUSIBILITÄTSPRÜFUNG DER QUELLE"
  log1 "────────────────────────────────────────"

  case "$SERVICE" in
    btc)
      if ls "$RESTORE_SOURCE" | grep -qE 'blocks|chainstate|blk00000.dat'; then
        log1 "✔ Sieht nach Bitcoin-Daten aus."
      else
        warn "Ich sehe keine typischen Bitcoin-Strukturen."
      fi
      ;;
    xmr)
      if ls "$RESTORE_SOURCE" | grep -qE 'bitmonero.log|data.mdb'; then
        log1 "✔ Sieht nach Monero-Daten aus."
      else
        warn "Ich sehe keine typischen Monero-Strukturen."
        log1 "Das kann trotzdem korrekt sein, aber bitte prüfe es."
      fi
      ;;
    xch)
      if ls "$RESTORE_SOURCE" | grep -qE 'blockchain_v2_mainnet.sqlite'; then
        log1 "✔ Sieht nach Chia-Daten aus."
      else
        warn "Ich sehe keine typischen Chia-Strukturen."
      fi
      ;;
  esac

  log3 "Restore-Quelle plausibilisiert: $RESTORE_SOURCE"
  award_coins 100
  maybe_level_up
  return 0
}

# --------------------------
# MAIN ACTION MENU
# --------------------------

main_menu() {
  echo
  echo "Was möchtest du tun?"
  echo "1) Backup erstellen"
  echo "2) Restore durchführen"
  echo "3) Nur prüfen / vergleichen"
  echo "0) Script beenden"
  echo
  read -rp "Auswahl [0-3]: " ACTION

  case "$ACTION" in
    1) do_backup ;;
    2) do_restore ;;
    3) do_compare ;;
    0) show_score; exit 0 ;;
    *) echo "Ungültige Auswahl."; main_menu ;;
  esac
}

# --------------------------
# DATADIR CHECK (DAU-SAFE, LEVEL 1 FIRST)
# --------------------------

suggest_native_datadirs() {
  log1 "────────────────────────────────────────"
  log1 "HILFE: TYPISCHE STANDARD-PFADE"
  log1 "────────────────────────────────────────"

  case "$SERVICE" in
    btc)
      log1 "Bitcoin typische Pfade:"
      log1 "  - $HOME/.bitcoin"
      log1 "  - /var/lib/bitcoin"
      ;;
    xmr)
      log1 "Monero typische Pfade:"
      log1 "  - $HOME/.bitmonero"
      log1 "  - /var/lib/monero"
      ;;
    xch)
      log1 "Chia typische Pfade:"
      log1 "  - $HOME/.chia"
      log1 "  - $HOME/.chia/mainnet"
      ;;
  esac

  log1 ""
  log1 "💡 Tipp: Oft ist es ein versteckter Ordner (beginnt mit .)"
  pause
}

check_datadir() {
  log1 "────────────────────────────────────────"
  log1 "DATENVERZEICHNIS (DATADIR) PRÜFUNG"
  log1 "────────────────────────────────────────"

  if [[ -z "${DATADIR:-}" ]]; then
    warn "DATADIR ist nicht gesetzt."
    log1 "Das ist der Ordner, in dem deine Blockchain-Daten liegen."

    if [[ "$USER_LEVEL" -le 2 ]]; then
      suggest_native_datadirs
    fi

    read -rp "Bitte gib jetzt den vollständigen Pfad zu DATADIR ein: " DATADIR
  fi

  while true; do
    log3 "Prüfe DATADIR: $DATADIR"

    if [[ ! -e "$DATADIR" ]]; then
      err "Der Pfad existiert nicht."
    elif [[ ! -d "$DATADIR" ]]; then
      err "Der Pfad ist kein Verzeichnis."
    elif [[ "$DATADIR" == "/" || "$DATADIR" == "/home" || "$DATADIR" == "/usr" || "$DATADIR" == "/mnt" ]]; then
      err "Dieser Pfad ist zu gefährlich für ein Backup/Restore!"
      log1 "Das könnte dein gesamtes System betreffen."
    else
      log3 "DATADIR sieht gültig aus."
      break
    fi

    log1 "Bitte überprüfe den Pfad und gib ihn erneut ein."

    if [[ "$USER_LEVEL" -le 2 ]]; then
      suggest_native_datadirs
    fi

    read -rp "DATADIR: " DATADIR
  done

  if [[ ! -w "$DATADIR" ]]; then
    warn "Du hast keine Schreibrechte auf dieses Verzeichnis."
    log1 "Das wird zu Fehlern führen."
  fi

  award_coins 75
  maybe_level_up
  log1 "👍 DATADIR-Prüfung abgeschlossen. (+75 Coins)"
}

auto_find_datadir() {
  log3 "Suche typische Standardpfade ..."
  for p in "$HOME/.bitcoin" "$HOME/.monero" "$HOME/.chia"; do
    [[ -d "$p" ]] || continue
    if ask_user "Ist das dein DATADIR? $p"; then
      DATADIR="$p"
      award_coins 20
      return
    fi
  done
}


# --------------------------
# PAC-MAN ANIMATION (RESTORE)
# --------------------------

pacman_restore_header() {
  local width=60
  local pac="C"
  local src="[ QUELLE ]"
  local dst="[ ZIEL ]"

  echo "⚠️⚠️⚠️  RESTORE-MODUS  ⚠️⚠️⚠️"
  echo
  echo "Pac-Man frisst die Quelle..."
  echo

  for ((i=width; i>=0; i--)); do
    printf "
%*s%s %s" "$i" "" "$pac" "$src"
    sleep 0.05
  done

  echo
  echo "💥 QUELLE WURDE ÜBERSCHRIEBEN 💥"
  echo "DESTINATION gewinnt."
  echo
  sleep 1
}

# --------------------------
# ZFS ERKENNUNG (DAU-STYLE)
# --------------------------

check_zfs() {
  log1 "────────────────────────────────────────"
  log1 "DATEISYSTEM-ERKENNUNG"
  log1 "────────────────────────────────────────"

  local fs
  fs=$(stat -f -c %T "$DATADIR" 2>/dev/null)

  case "$fs" in
    zfs)
      log1 "🎉 Dein DATADIR liegt auf ZFS."
      log1 "Snapshots sind möglich – maximale Sicherheit!"
      award_coins 100
      ZFS_AVAILABLE=true
      ;;
    btrfs)
      log1 "✨ Dein DATADIR liegt auf btrfs."
      log1 "btrfs kann Subvolume-Snapshots erstellen."
      log1 "Das ist fortgeschrittene Technik – Respekt!"
      award_coins 75
      log1 "💡 Hinweis: btrfs-Snapshots könnten hier später genutzt werden."
      ZFS_AVAILABLE=false
      BTRFS_AVAILABLE=true
      ;;
    ext4|ext3|ext2)
      log1 "ℹ️  Dein DATADIR liegt auf $fs."
      log1 "Das ist völlig okay und sehr verbreitet."
      log1 "Wenn du irgendwann mehr Sicherheit willst, lohnt sich ein Blick auf ZFS oder btrfs."
      ZFS_AVAILABLE=false
      BTRFS_AVAILABLE=false
      ;;
    *)
      log1 "ℹ️  Dateisystem: $fs"
      ZFS_AVAILABLE=false
      BTRFS_AVAILABLE=false
      ;;
  esac

  maybe_level_up
  pause
}
  main_menu
}


# --------------------------
# COMPARE (PLACEHOLDER)
# --------------------------

do_compare() {
  echo
  echo "🔍 Vergleichsmodus (noch nicht implementiert)"
  pause
  award_coins 75
  main_menu
}

do_restore() {
  clear

  # --------------------------
  # RESTORE HEADER (PAC-MAN)
  # --------------------------
  pacman_restore_header

  log1 "────────────────────────────────────────"
  log1 "RESTORE STARTEN? (GEFÄHRLICH)"
  log1 "────────────────────────────────────────"
  log1 "Beim Restore werden bestehende Daten ÜBERSCHRIEBEN."
  log1 "Das ist keine Sicherung, sondern eine Wiederherstellung."

  log3 "Service: $SERVICE"
  log3 "DATADIR: $DATADIR"
  log3 "ZFS verfügbar: ${ZFS_AVAILABLE:-false}"

  warn "RESTORE IST IMMER GEFÄHRLICH"

  case "$USER_LEVEL" in
    1)
      log1 "Du bist Level 1. Restore ist nichts Alltägliches."
      log1 "Wir halten jetzt extra an und erklären nochmal."
      pause
      ;;
    2|3)
      log1 "Bitte lies aufmerksam. Danach musst du bewusst zustimmen."
      pause
      ;;
    4|5)
      log3 "Advanced restore flow."
      ;;
  esac

  # --------------------------
  # RESTORE SOURCE SELECTION
  # --------------------------

  if ! select_restore_source; then
    log1 "Restore ohne Quelle macht keinen Sinn."
    pause
    main_menu
    return
  fi

  log1 "Restore-Quelle bestätigt."
  log3 "Quelle: $RESTORE_SOURCE_TYPE → $RESTORE_SOURCE"

  read -rp "Möchtest du den Restore wirklich starten? [j/N] " _go
  _go=${_go:-N}

  case "$_go" in
    j|J)
      log1 "⚠️ Restore wird vorbereitet..."
      log3 "Restore confirmed by user."

      if [[ "${ZFS_AVAILABLE:-false}" == true ]]; then
        create_snapshot "$DATADIR" "pre-restore"
      fi

      pacman_restore_animation

      echo "(Simulation) Daten werden zurückgespielt..."
      sleep 2

      log1 "✅ Restore abgeschlossen."
      award_coins 250
      ;;
    *)
      log1 "Restore wurde abgebrochen. Gute Entscheidung, wenn du unsicher warst."
      log3 "User skipped restore."
      ;;
  esac

  pause
  main_menu
}

# --------------------------
# RESTORE_PRUNE (DAU-SAFE, NUKLEAR)
# --------------------------

restore_prune() {
  clear
  echo "☢️☢️☢️  PRUNE-MODUS – NUKLEAROPTION  ☢️☢️☢️"
  log1 "────────────────────────────────────────"
  log1 "JETZT WIRD ALLES GELÖSCHT."
  log1 "Kein Backup. Kein Mitleid. Kein zurück."
  log1 "Danach wird die Blockchain NEU aus dem Internet geladen."

  # mentale Vollbremsung
  case "$USER_LEVEL" in
    1)
      log1 "Du hast Level 1 gewählt."
      log1 "PRUNE ist fast nie das Richtige für Anfänger."
      log1 "Wir halten jetzt mehrfach an."
      pause
      ;;
    2|3)
      log1 "PRUNE ist drastisch. Bitte lies alles genau."
      pause
      ;;
    4|5)
      log3 "Advanced user in prune mode."
      ;;
  esac

  warn "LETZTE WARNUNG: ALLE DATEN in $DATADIR WERDEN GELÖSCHT"
  echo
  read -rp "Tippe PRUNE um fortzufahren (alles andere bricht ab): " _confirm1
  [[ "$_confirm1" == "PRUNE" ]] || { log1 "Abgebrochen."; return; }

  read -rp "Tippe NO-BACKUP um zu bestätigen, dass KEIN Backup existiert: " _confirm2
  [[ "$_confirm2" == "NO-BACKUP" ]] || { log1 "Abgebrochen."; return; }

  award_coins 200  # Wahnsinnsbonus 😄

  # Snapshot vor nuklear (falls ZFS)
  if [[ "${ZFS_AVAILABLE:-false}" == true ]]; then
    log1 "📸 Automatischer Snapshot vor der Zerstörung..."
    create_snapshot "$DATADIR" "pre-prune"
  fi

  echo
  echo "💣 BOOM. Daten werden jetzt gelöscht... (Simulation)"
  sleep 2
  echo "🌍 Blockchain wird neu aus dem Internet geladen... (Simulation)"
  sleep 2

  log1 "✅ PRUNE abgeschlossen. System im jetzt im Neuzustand."
  award_coins 300

  pause
  main_menu
}

# --------------------------------------------------
# STARTSCREEN – PAC-MAN EDITION 😄
# --------------------------------------------------

start_screen() {
  clear
  echo ""
  echo "🟡🟡🟡🟡🟡🟡🟡🟡🟡🟡🟡🟡🟡🟡🟡🟡🟡🟡🟡🟡"
  echo "🟡   BACKUP BLOCKCHAIN – PAC-MAN EDITION   🟡"
  echo "🟡🟡🟡🟡🟡🟡🟡🟡🟡🟡🟡🟡🟡🟡🟡🟡🟡🟡🟡🟡"
  echo ""
  echo "          🟡<:3(    ₿   ɱ   🌱"
  echo ""
  log1 "Willkommen! Dieses Script redet mit dir."
  log1 "Es erklärt, fragt nach und schützt dich vor dir selbst 😄"
  log3 "Pac-Man Modus aktiv."
  pause
}

show_startscreen() {
cat <<'EOF'

   ██████╗ ████████╗ ██████╗
   ██╔══██╗╚══██╔══╝██╔════╝
   ██████╔╝   ██║   ██║
   ██╔══██╗   ██║   ██║
   ██████╔╝   ██║   ╚██████╗
   ╚═════╝    ╚═╝    ╚═════╝

        🟡 ᗧ···ᗣ  Pac-Man Backup Edition

   Frisst das Chaos. Spuckt die Sicherheit.
   Dein Backup-Spiel beginnt jetzt.

EOF
log1 "Willkommen! Dieses Script schützt dich vor dir selbst 😄"
log1 "Du kannst hier nichts kaputt machen, außer du willst es wirklich."
}

# --------------------------
# SCRIPT START
# --------------------------

start_screen
#show_startscreen
select_user_level
select_service
confirm_service_stopped
check_datadir
check_zfs
main_menu

# --------------------------
# SCRIPT ENDE
# --------------------------

