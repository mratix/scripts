backup_blockchain_truenas.sh

ZFS-first backup, restore and merge script for blockchain nodes running on TrueNAS.

This is an admin tool designed for real-world, headless environments.
It prioritizes correctness, safety and deterministic behavior over convenience.


WHAT THIS IS

- A production-grade backup script for blockchain data
- Designed specifically for TrueNAS and ZFS
- Snapshot-driven with rsync as transport layer
- Safe for cron and unattended execution
- Fully configurable via external .conf files


WHAT THIS IS NOT

- Not a one-click tool
- Not a GUI application
- Not designed for beginners
- Not safe if you do not understand ZFS and rsync


SUPPORTED SERVICES

Currently implemented and tested:

- bitcoind
- monerod
- chia (node, farmer, plots)

The script itself is service-agnostic and can be extended easily.


OPERATING MODES

Controlled via the MODE variable:

backup   : Snapshot plus rsync backup (default)
restore  : Restore from backup (requires FORCE and confirmation)
merge    : Dataset merge with snapshot protection
verify   : Reserved for future use


ZFS DESIGN PRINCIPLES

Snapshots are the source of truth.
Rsync is only a transport mechanism.

Rules enforced by the script:

- Snapshots are created before destructive operations
- Snapshot lifecycle management is external
- Replication (e.g. zettarepl) is supported but not enforced
- .zfs paths are explicitly excluded from rsync


CONFIGURATION OVERVIEW

Configuration is externalized and layered.

Typical load order:

1. config.conf (optional, disabled by default)
2. default.conf
3. machine.conf
4. <hostname>.conf (e.g. hpms1.conf)
5. CLI overrides

Each configuration file may contain:

enabled=true or enabled=false

Later configurations override earlier ones.


TYPICAL DATASET LAYOUT

tank/blockchain/
  bitcoind/
    blocks/
    chainstate/
    indexes/
  monerod/
  chia/
    plots/
  backups/
    blockchain/
    replica/


🔹 Verification

verify-Mode

Size check

rsync dry-run compare

Exit-Codes & Partial States

🔹 Telemetry

Optional

MySQL / Influx

Run lifecycle

Events (warn/error/fatal)

Security note (credentials via host.conf)

🔹 Config hierarchy

config.conf

default.conf

machine.conf

host.conf

Override-Regeln

🔹 Safety model

FORCE nur CLI

RESTORE interaktiv

No silent destructive actions

SAFETY NOTES

- Restore operations require FORCE=true
- Restore is intentionally not headless-safe
- Logging is mandatory and must not be removed
- The script is expected to run as root

If you do not understand what the script does, do not use it.


DOCUMENTATION MAP

README.short
  Quick orientation

RELEASE_NOTES_v1.0.4.txt
  Exact release state

default.conf, machine.conf, hpms1.conf
  Configuration examples


LICENSE

Open source.
No warranties.
Use at your own risk.

