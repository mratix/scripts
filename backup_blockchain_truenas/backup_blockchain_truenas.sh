#!/usr/bin/env bash
#
# ============================================================
# backup_blockchain_truenas-dau.sh
# DAU-SAFE / INTERACTIVE VERSION
# ============================================================
# Philosophie:
# - Dieses Script trifft KEINE Entscheidungen alleine
# - Es erklärt, wartet, fragt und wiederholt sich
# - Abbrechen ist jederzeit erlaubt
# - Exit nur, wenn der User es will
# ============================================================

# --------------------------
# SAFE DEFAULTS (EDIT HERE)
# --------------------------
DEFAULT_SERVICE="btc"              # btc | xmr | xch
DEFAULT_TARGET_HEIGHT=""            # optional
DEFAULT_USER_LEVEL="ask"            # ask | 1 | 2 | 3 | 4
SCRIPT_NAME="$(basename "$0")"

# --------------------------
# TIMER / GAMIFICATION
# --------------------------
SCRIPT_START_TS=$(date +%s)
LAST_ACTION_TS=$SCRIPT_START_TS
COINS=0

# --------------------------
# HELPER FUNCTIONS
# --------------------------

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


# einfache ROT12-Verschiebung (keine Sicherheit, nur Abschreckung 😉)
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
    echo "🍿 Du bist schon eine Weile hier (über 5 Minuten)."
    echo "Soll ich dir Popcorn oder Pizza bestellen? Die Brille suchen? 😄"
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
  echo "Erfahrungspunkte: $COINS Coins" && rot12 "$COINS" >> "$HOME/.backup_blockchain_truenas-safe_DAU.rewards"
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
  echo "3) Ich weiß, was \$HOME ist und kenne meine Daten"
  echo "4) Ich weiß genau, was ich tue (CLI, Pfade, Risiken)" # darf args mitgeben
  echo
  echo "5) Ich bin der Chef oder ein Entwickler"
  read -rp "Auswahl [1-5]: " USER_LEVEL

  case "$USER_LEVEL" in
    1|2|3|4|5) ;;
    *) echo "Ungültige Auswahl."; select_user_level ;;
  esac

  award_coins 50
}

# --------------------------
# SERVICE SELECTION
# --------------------------

select_service() {
  if [ -n "$SERVICE" ]; then
    return
  fi

  echo
  echo "Welche Blockchain möchtest du bearbeiten?"
  echo "1) Bitcoin (BTC)"
  echo "2) Monero (XMR)"
  echo "3) Chia (XCH)"
  echo
  read -rp "Auswahl [1-3]: " _svc

  case "$_svc" in
    1) SERVICE="btc" ;;
    2) SERVICE="xmr" ;;
    3) SERVICE="xch" ;;
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

  local snap_name="backup_safe_${reason}_$(date +%Y%m%d_%H%M%S)"

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
# MAIN ACTION MENU
# --------------------------

main_menu() {
  echo
  echo "Was möchtest du tun?"
  echo "1) Backup erstellen"
  echo "2) Restore durchführen"
  echo "3) Nur prüfen / vergleichen"
  echo "4) Script beenden"
  echo
  read -rp "Auswahl [1-4]: " ACTION

  case "$ACTION" in
    1) do_backup ;;
    2) do_restore ;;
    3) do_compare ;;
    4) show_score; exit 0 ;;
    *) echo "Ungültige Auswahl."; main_menu ;;
  esac
}

# --------------------------
# BACKUP (DAU-SAFE)
# --------------------------

do_backup() {
  echo
  echo "🧰 BACKUP-MODUS"
  echo "Wir sichern jetzt deine Blockchain-Daten."

  # Annahme: DATADIR ist gesetzt / bekannt
  if [ -z "$DATADIR" ]; then
    echo "⚠️  Datenverzeichnis (DATADIR) ist nicht gesetzt."
    ask_continue_or_restart "$@" || return
  fi

  # ZFS Bonus
  if is_zfs_dataset "$DATADIR"; then
    echo "🎉 Glückwunsch! Du nutzt ZFS."
    echo "ZFS bietet Snapshots und zusätzliche Sicherheit."
    award_coins 100  # Willkommensbonus für ZFS
    pause

    # Snapshot vor Backup
    create_snapshot "$DATADIR" "backup"
  else
    echo "ℹ️  Kein ZFS-Dataset erkannt."
    echo "Das Backup funktioniert trotzdem, aber ohne Snapshots."
    pause
  fi

  echo
  echo "Was wird jetzt passieren?"
  echo "- Die Blockchain-Daten werden kopiert"
  echo "- Bestehende Backups werden nicht gelöscht"
  echo
  read -rp "Möchtest du das Backup jetzt starten? [J/n] " _go

  case "$_go" in
    j|J)
      echo "🚀 Backup startet jetzt..."
      echo "(Simulation) Daten werden gesichert..."
      sleep 2

      echo "✅ Backup erfolgreich abgeschlossen."
      award_coins 200   # Belohnung für erfolgreiches Backup

      # Snapshot nach Backup für extra Sicherheit
      if is_zfs_dataset "$DATADIR"; then
        create_snapshot "$DATADIR" "post-backup"
        award_coins 50
      fi
      ;;
    *)
      echo "Backup wurde nicht gestartet."
      ;;
  esac

  pause
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

# --------------------------
# RESTORE (DAU-SAFE)
# --------------------------

do_restore() {
  echo
  echo "⚠️  RESTORE-MODUS"
  echo "Ein Restore kann bestehende Daten ÜBERSCHREIBEN."
  echo "Das ist mächtiger als ein Backup – und gefährlicher."
  pause

  # Snapshot vor Restore (falls ZFS)
  if is_zfs_dataset "$DATADIR"; then
    echo "📸 Sicherheits-Snapshot vor dem Restore"
    create_snapshot "$DATADIR" "pre-restore"
    award_coins 50
  fi

  echo
  echo "Woher sollen die Daten kommen?"
  echo "a) Netzwerk-Backup"
  echo "b) USB-Backup"
  echo "c) Alles löschen und neu aus dem Internet laden (PRUNE)"
  echo
  read -rp "Auswahl [a/b/c]: " RESTORE_MODE

  case "$RESTORE_MODE" in
    a|b)
      echo
      echo "ℹ️  Restore von Backup gewählt."
      echo "Dabei werden vorhandene Daten überschrieben."
      pause

      read -rp "Soll das Restore wirklich gestartet werden? [j/N] " _go
      case "$_go" in
        j|J)
          echo "🚀 Restore startet jetzt..."
          echo "(Simulation) Daten werden wiederhergestellt..."
          sleep 2
          echo "✅ Restore erfolgreich abgeschlossen."
          award_coins 250
          ;;
        *)
          echo "Restore wurde abgebrochen."
          ;;
      esac
      ;;

    c)
      restore_prune
      ;;

    *)
      echo "Ungültige Auswahl."; return
      ;;
  esac

  # Snapshot nach Restore (falls ZFS)
  if is_zfs_dataset "$DATADIR"; then
    echo "📸 Snapshot nach dem Restore (Stabiler Zustand)"
    create_snapshot "$DATADIR" "post-restore"
    award_coins 50
  fi

  pause
  main_menu
}

# --------------------------
# ARGUMENT PARSING (MINIMAL)

# --------------------------

SERVICE="$1"
TARGET_HEIGHT="$2"

# --------------------------
# ROOT CHECK (ERZIEHUNGSMASSNAHMEN)
# --------------------------

root_check() {
  if [ "$EUID" -eq 0 ]; then
    echo
    echo "🚨 ACHTUNG: Du führst dieses Script als root aus!"
    echo
    echo "Dieses Script ist absichtlich dafür gedacht, als NORMALER USER"
    echo "ausgeführt zu werden. Backups brauchen Vertrauen, nicht Macht."
    echo
    echo "Warum ist root hier keine gute Idee?"
    echo "- Fehler wirken sofort und global"
    echo "- Falsche Pfade können ALLES löschen"
    echo "- Lernen funktioniert besser ohne Vollmacht"
    echo
    echo "📚 Lesestoff (freiwillig, aber sinnvoll):"
    echo "https://de.wikipedia.org/wiki/Root_(Unix)"
    echo
    echo "👎 Erziehungsmaßnahme: Punktabzug!"

    COINS=$(( COINS - 200 ))  # negativer Kontostand wird absichtlich erlaubt
    rot12 "$COINS" >> "$HOME/.backup_blockchain_truenas-safe_DAU.rewards"

    echo
    echo "Was möchtest du tun?"
    echo "1) Script jetzt als normaler User neu starten"
    echo "2) Trotzdem weitermachen (nicht empfohlen)"
    echo "3) Script beenden"
    read -rp "Auswahl [1-3]: " _rc

    case "$_rc" in
      1) echo "Gute Entscheidung 👍"; exec sudo -u "${SUDO_USER:-$USER}" "$0" "$@" ;;
      2) echo "Alles klar. Du wurdest gewarnt." ;;
      3) end ;;
      *) echo "Ungültige Auswahl."; root_check "$@" ;;
    esac
  fi
}

# --------------------------
# SCRIPT START
# --------------------------

clear
echo "===================================================="
echo " Blockchain Backup – DAU SAFE MODE"
echo "===================================================="

echo "Dieses Script erklärt jeden Schritt."
echo "Es macht nichts ohne deine Zustimmung."

pause

select_user_level
select_service
confirm_service_stopped

while true; do
  check_idle_time
  main_menu
  LAST_ACTION_TS=$(date +%s)
done

