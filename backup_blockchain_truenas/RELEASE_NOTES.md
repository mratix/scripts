Release Notes — v1.1.4 “Gold”
Status

Stable documentation update

Diese Version stellt einen stabilen, aufgeräumten Kern des Projekts dar.
Sie dient als verlässliche Grundlage für zukünftige Erweiterungen.

Neu / Aktualisiert

- Dokumentation auf v1.1.4 aktualisiert (README, README.short, Release Notes)
- Community Standards ergänzt (LICENSE, SECURITY, CONTRIBUTING, Templates)
- Hinweise zu Support und Kontakt klarer dargestellt

Bekannte Einschränkungen

- Die Blockhöhe wird aus dem Servicestatus nicht richtig geparst, übergibt der Logdatei-Rotation am Ende ein "unclean". Die vorherige Logdateil-Parsing Methode (Branch alpha) hat sich zuverlässiger gezeigt.
- Telemetrie Export für Influx als http-Übergabe vorbereitet, nicht getestet.
- Sonderfall ist weiter Monero LMDB mit rsync. Die Geschwindigkeitsoptimierung kann nicht weiter verbessert werden, nicht zufriedenstellend.
- Import/Export für Nativen Dienst/ StartOS start9/ Umbrel usw. in Planung


Zielgruppe

Diese Version richtet sich an:
- Erfahrene Linux Admins
- ZFS-basierte Systeme (hier TruNAS Scale)
- Betreiber von Blockchain-Nodes
- Nicht geeignet für "Fire & Forget" oder copy&paste-Benutzer.

Upgrade-Hinweis

v1.1.4 ist primär eine Dokumentations- und Governance-Aktualisierung.
Keine In-Place-Migration erforderlich.
