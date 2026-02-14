# BorgBackup Install- und Betriebsleitfaden

## Ziel

Diese Anleitung beschreibt ein robustes BorgBackup-Setup fuer Linux-Systeme:
- headless faehig
- sicher per SSH-Key
- mit klaren Restore-Schritten
- geeignet fuer Server und Arbeitsmaschinen

## Grundprinzipien

- Kein Backup ist kein Backup: Wiederherstellung regelmaessig testen.
- Pro Maschine ein eigenes Repository.
- Backups als normaler Benutzer ausfuehren, root nur wenn noetig.
- Keine Passwoerter im Script speichern.
- Zugriff auf dem Backupserver restriktiv absichern.

## Architektur

- Quellsystem: Client (z. B. `crodebhassio`)
- Zielsystem: Backupserver/NAS (z. B. `cronas`)
- Backup-User auf Ziel: `rsync`
- Repo-Pfad pro Host: `/data/backups/pools/borg/<hostname>`

## 1) Borg installieren

Auf Client und Zielsystem Borg ueber Paketmanager installieren.  
Moeglichst kompatible Versionen verwenden.

Pruefen:

```bash
borg --version
```

## 2) Backup-User und Zielpfad auf dem Backupserver

Auf dem Backupserver:

```bash
sudo adduser rsync
sudo mkdir -p /data/backups/pools/borg
sudo chown -R rsync:rsync /data/backups/pools/borg
sudo chmod 700 /data/backups/pools/borg
```

## 3) SSH-Key vom Client zum Backupserver

Auf dem Client (pro lokalem User, der Backups ausfuehrt):

```bash
ssh-keygen -t ed25519 -a 100
ssh-copy-id rsync@backupserver
ssh rsync@backupserver 'echo key-ok'
```

## 4) SSH-Zugriff haerten (wichtig)

In `~rsync/.ssh/authorized_keys` auf dem Backupserver die Keys mit erzwungenem Kommando einsperren:

```text
command="borg serve --restrict-to-path /data/backups/pools/borg/crodebhassio --append-only" ssh-ed25519 AAAA... client-key-comment
```

Hinweise:
- `--restrict-to-path` auf den Host-Pfad setzen.
- `--append-only` schuetzt gegen Loeschen/Ueberschreiben durch kompromittierte Clients.
- Pro Client-Key den passenden Host-Pfad konfigurieren.

## 5) Repository initialisieren

Entweder lokal auf dem Backupserver:

```bash
sudo -iu rsync
mkdir -p /data/backups/pools/borg/crodebhassio
borg init --encryption=repokey /data/backups/pools/borg/crodebhassio
```

Oder direkt vom Client:

```bash
borg init --encryption=repokey ssh://rsync@backupserver/data/backups/pools/borg/crodebhassio
```

## 6) Backup auf dem Client ausfuehren

Beispiel `borg create`:

```bash
export BORG_PASSCOMMAND="cat $HOME/.borg-passphrase"
borg create --stats --compression lz4 --one-file-system \
  ssh://rsync@backupserver/data/backups/pools/borg/crodebhassio::{hostname}-{now:%Y%m%d%H%M} \
  /etc /home /var/www \
  --exclude-caches \
  --exclude '/home/*/.cache/*' \
  --exclude '/var/cache/*'
```

## 7) Retention / Prune

Beispiel:

```bash
borg prune -v --list \
  --keep-within=1d \
  --keep-daily=7 \
  --keep-weekly=4 \
  --keep-monthly=6 \
  ssh://rsync@backupserver/data/backups/pools/borg/crodebhassio
```

Optional danach:

```bash
borg compact ssh://rsync@backupserver/data/backups/pools/borg/crodebhassio
```

## 8) Cron / headless Betrieb

Empfohlen mit Lockfile:

```cron
30 2 * * * /usr/bin/flock -n /tmp/borgbackup.lock /home/rsync/scripts/borgbackup.sh >> /home/rsync/logs/borgbackup.log 2>&1
```

Wichtig:
- `BORG_PASSCOMMAND` im Script oder per Service-Umgebung setzen.
- Keine interaktiven Passwortabfragen im Cron zulassen.

## 9) Restore testen (Pflicht)

Archive anzeigen:

```bash
borg list ssh://rsync@backupserver/data/backups/pools/borg/crodebhassio
```

Ein Verzeichnis extrahieren:

```bash
mkdir -p ~/restore/www
cd ~/restore/www
borg extract ssh://rsync@backupserver/data/backups/pools/borg/crodebhassio::crodebhassio-YYYYmmddHHMM var/www
```

## 10) Haeufige Fehler

- `Permission denied (publickey,password)`:
  - SSH-Key nicht korrekt installiert oder falscher User.
- `Repository not found`:
  - Pfad in URL falsch oder `--restrict-to-path` blockiert.
- `Enter passphrase` im Cron:
  - `BORG_PASSCOMMAND` fehlt oder ist nicht lesbar.
- Restore ungetestet:
  - Backup gilt erst als valide, wenn Restore getestet wurde.

## 11) Was gegenueber alten Anleitungen verbessert wurde

- Kein Klartext-DB-Passwort in Scripts.
- Keine pauschale root-Ausfuehrung.
- Pro Host getrennte Repositories.
- Restriktive `authorized_keys` Regeln.
- Feste Retention und Restore-Routine.

## 12) Integration mit `mybackup.sh`

In diesem Repository wird Borg ueber `mybackup/mybackup.sh` orchestriert.  
Der Modus `borg` fuehrt zusaetzlich einen MySQL all-in-one Dump aus und startet danach `mybackup/borgbackup.sh`.

Empfohlene Aufrufe:

```bash
~/scripts/mybackup.sh borg
~/scripts/mybackup.sh all
```

Hinweise:
- `mybackup.sh all` kombiniert `www`, `mysql`, `tar` und `borg`.
- Fuer `mysql` ist `~/.my.cnf` des ausfuehrenden Users erforderlich.
- Fuer `www` ist ein funktionierender SSH-Key (`id_ed25519_backup_www`) erforderlich.

Empfohlene Reihenfolge fuer Ersttests:

```bash
~/scripts/mybackup.sh www
~/scripts/mybackup.sh mysql
~/scripts/mybackup.sh tar
~/scripts/mybackup.sh borg
```

Danach:
- taeglicher Betrieb ueber `mybackup.sh all`
- Restore-Test monatlich einplanen
