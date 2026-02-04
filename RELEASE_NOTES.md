Release Notes — v1.0.0 “Gold”
Status

Stable baseline release

Diese Version stellt einen stabilen, aufgeräumten Kern des Projekts dar.
Sie dient als verlässliche Grundlage für zukünftige Erweiterungen.

Neu

Klar definierter Backup / Restore / Merge-Workflow

ZFS-first Ansatz:

Snapshots vor kritischen Operationen

Statefile (Audit-Trail):

letzter Lauf

Modus

Runtime

Disk Usage (du -shL)

Restore mit Sicherheitsabfrage & FORCE-Flag

Headless-fähig für Cronjobs (außer Restore)

Deterministisches Verhalten (set -Eeuo pipefail)

Entfernt / Bereinigt

h*-Stamp-Konstrukt (Height-Marker)

historisch gewachsene Sonderlogik

implizite Seiteneffekte

vermischte Zustände (Backup ≠ Restore ≠ Merge)

Diese Logik ist nicht verloren, sondern verbleibt im alpha-Branch.

Bekannte Einschränkungen

Telemetrie nur vorbereitet (kein Export aktiv)

Service-spezifische Sonderfälle (z. B. monerod rsync-Optimierung) noch nicht re-integriert

Replikation (z. B. trigger_replication) folgt in späteren Versionen

Zielgruppe

Diese Version richtet sich an:

erfahrene Admins

ZFS-basierte Setups

Betreiber von Blockchain-Nodes

Nicht geeignet für „Fire & Forget“.

Upgrade-Hinweis

v1.0.0 ist kein In-Place-Upgrade früherer Script-Stände.
Es ist ein neuer, stabiler Ausgangspunkt.
