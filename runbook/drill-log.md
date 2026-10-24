# Drill log

One entry per drill, newest first. The procedures are in
[restore-drill.md](restore-drill.md) and [README.md](README.md) §3.

```
2026-10-24: first production drills, all passed (times UTC).
  - restore from r2 on the laptop, before the Bitwarden import: snapshot
    2384d4e8, integrity_check ok, counts match prod; the production image
    served /alive 200 on the restored data.
  - restore from r2 again after the import: fresh snapshot 178e4ae6,
    integrity_check ok, counts match prod. Web login round-tripped on
    vw-restore-test over HTTPS; plain http://localhost did not work (#8).
  - backup failure (restic.env moved away): Result=resources, and the
    OnFailure "unit failed" mail arrived.
  - Healthchecks: a /fail ping sent DOWN; the next good backup (snapshot
    c4a1f761) sent UP 24 s later.
  - container down: vaultwarden stopped at 04:38:14, down mail at 04:40:29,
    recovered mail at 04:42:36 after the restart.
  - reboots: the 06:38 dnf-automatic reboot and a forced `systemctl reboot`
    at 16:54:45 both came back unaided (~2 min down). After the second, the
    journal still held the previous boot (#7).
  - fixed from these drills: restore-drill port (#6), HTTPS test vault (#8),
    persistent journal (#7), container-watch state lost across a reboot,
    leaving its down mails without a recovered mail (#9).
```
