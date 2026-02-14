# mybackup Guide

Stand: 2026-02-14 (mratix + Codex)

Kurzanleitung fuer `mybackup.sh` mit Fokus auf headless Betrieb.

## Was das Script tut

- `www`: synchronisiert `/var/www/html` per `rsync` auf die NAS
- `mysql`: erstellt SQL Dumps (einzeln + all-in-one)
- `tar`: erstellt Tar-Backups und splittet grosse `.tar.gz` in 1 GiB Teile
- `borg`: startet Borg-Backup (separates Script)

Siehe auch: `mybackup/BORG_INSTALL_GUIDE_DE.md` fuer das komplette Borg-Setup (Server, SSH-Haertung, Restore).

## Voraussetzungen

- NAS-Share `backups` ist in `/etc/fstab` eingetragen
- User, die das Script starten sollen (`mratix`, `rsync`), sind in Gruppe `users`
- `~/.my.cnf` ist fuer MySQL Zugriff vorhanden (kein Passwort-Prompt)
- SSH-Key fuer `www`-Backup ist vorhanden

## Erststart nach `git clone`

1. Script ausfuehrbar machen:

```bash
chmod +x mybackup/mybackup.sh mybackup/borgbackup.sh
```

2. CIFS Mount vorbereiten:
- `/etc/fstab` Eintrag fuer `//.../backups` mit `users`
- lokale Gruppe/UID/GID passend setzen

3. Gruppenmitgliedschaft pruefen:

```bash
id mratix
id rsync
```

`users` muss in beiden Ausgaben enthalten sein (neue Login-Session nach `usermod -aG`).

4. MySQL Client Credentials pro User anlegen:
- `~/.my.cnf` mit `chmod 600`

5. SSH Key fuer `www`-Backup je User anlegen und auf NAS kopieren:
- `id_ed25519_backup_www`
- `ssh-copy-id ... rsync@NAS`

6. Smoke Tests:

```bash
./mybackup/mybackup.sh www
./mybackup/mybackup.sh mysql
./mybackup/mybackup.sh tar
```

## fstab Beispiel (CIFS)

```fstab
//192.168.178.20/backups /mnt/cronas/backups cifs rw,_netdev,nofail,noauto,users,vers=3.1.1,credentials=/home/mratix/.smbcredentials,uid=1000,gid=100,file_mode=0660,dir_mode=0770 0 0
```

Hinweise:
- `users` erlaubt Mount/Umount fuer normale User.
- `gid=100` passt zur Gruppe `users`.
- Bei mehreren Usern ist `0660/0770` praxisnaher als `0640/0750`.
- Die `credentials=` Datei muss fuer den aufrufenden User lesbar sein.

Aktueller produktiver Eintrag:

```fstab
//192.168.178.20/backups /mnt/cronas/backups cifs rw,_netdev,nofail,noauto,users,vers=3.1.1,credentials=/home/rsync/.smbcredentials,uid=1001,gid=100,file_mode=0660,dir_mode=0770 0 0
```

## SSH Key Setup fuer `www`

Auf jeder Quellmaschine und pro lokalem User:

```bash
ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519_backup_www
ssh-copy-id -i ~/.ssh/id_ed25519_backup_www.pub rsync@192.168.178.20
ssh -i ~/.ssh/id_ed25519_backup_www -o BatchMode=yes rsync@192.168.178.20 'echo key-ok'
```

`mybackup.sh www` nutzt automatisch:
- `WWW_RSYNC_USER` (Default `rsync`)
- `WWW_RSYNC_SSH_KEY` (optional, sonst auto-detect)
- `BatchMode=yes` (headless)

## NAS Rechte fuer Web-Ziel

Auf der NAS als Admin:

```bash
sudo chown -R rsync:users /volume2/storage/www/html
sudo find /volume2/storage/www/html -type d -exec chmod 2775 {} \;
sudo find /volume2/storage/www/html -type f -exec chmod 664 {} \;
```

## MySQL headless via `~/.my.cnf`

Beispiel (pro lokalem User, der `mybackup.sh mysql` startet):

```ini
[client]
user=rsync
password=DEIN_DB_PASSWORT
host=192.168.178.66
```

```bash
chmod 600 ~/.my.cnf
```

## Lokale SQL-Rotation

Nach Dumps wird lokal automatisch aufgeraeumt:
- pro DB nur letzte 3 Dateien behalten
- die zwei aelteren der 3 werden `.gz`
- alles aeltere wird geloescht
- Symlink `<db>_last.sql` zeigt auf neuesten Dump

Zusatz:
- im `tar`-Modus laeuft Rotation vor dem Tar-Backup ebenfalls einmal global.

## Tar Split

Archive groesser als 1 GiB werden in Teile gesplittet:
- `*.tar.gz.part-0000`, `...0001`, ...
- Original-`*.tar.gz` wird danach entfernt
- Limit optional: `TAR_SPLIT_LIMIT_BYTES`

Rejoin:

```bash
cat archive.tar.gz.part-* > archive.tar.gz
```

## Quick Tests

```bash
~/scripts/mybackup.sh www
~/scripts/mybackup.sh mysql
~/scripts/mybackup.sh tar
~/scripts/mybackup.sh borg
```

Gesamtlauf:

```bash
~/scripts/mybackup.sh all
```

## Troubleshooting

- `Permission denied (publickey,password)` bei `www`:
  - falscher/missing Key fuer genau diesen lokalen User
- `rsync ... mkdir ... Permission denied (13)`:
  - NAS Zielrechte/ACL auf `/volume2/storage/www/html` korrigieren
- `mkdir ... /mnt/cronas/backups ... Keine Berechtigung`:
  - Gruppenrechte/Mountrechte fuer `users` pruefen, neue Login-Session starten
- `ERROR 1045 ... verwendetes Passwort: Nein`:
  - `~/.my.cnf` fehlt/falsch fuer den aktuellen lokalen User
