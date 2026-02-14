# mybackup Notes

## WWW Backup (headless via SSH key)

`mybackup.sh www` nutzt:
- Remote user: `rsync` (Default, via `WWW_RSYNC_USER`)
- SSH key: `id_ed25519_backup_www` (auto-detected, optional via `WWW_RSYNC_SSH_KEY`)
- SSH mode: `BatchMode=yes` (kein Passwort-Prompt im Cron/Timer)

## Key Setup (3 commands)

Auf der Quellmaschine (z.B. `crodebhassio`) pro lokalem User:

```bash
ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519_backup_www
ssh-copy-id -i ~/.ssh/id_ed25519_backup_www.pub rsync@192.168.178.20
ssh -i ~/.ssh/id_ed25519_backup_www -o BatchMode=yes rsync@192.168.178.20 'echo key-ok'
```

## NAS Rechte-Fix (3 commands)

Auf der NAS als Admin:

```bash
sudo chown -R rsync:users /volume2/storage/www/html
sudo find /volume2/storage/www/html -type d -exec chmod 2775 {} \;
sudo find /volume2/storage/www/html -type f -exec chmod 664 {} \;
```

## Quick Tests

SSH/Auth Test:

```bash
ssh -i ~/.ssh/id_ed25519_backup_www -o BatchMode=yes rsync@192.168.178.20 'echo key-ok'
```

Rsync dry-run Test:

```bash
rsync -avzsh -e "ssh -i ~/.ssh/id_ed25519_backup_www -o BatchMode=yes" \
  /var/www/html/ rsync@192.168.178.20:/volume2/storage/www/html/ --dry-run
```

Script Test:

```bash
~/scripts/mybackup.sh www
```
