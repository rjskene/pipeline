# Status table layout examples

Grouped layout

```
PIPELINE STATUS — <today's date>
================================================================
EPICS
================================================================
 [P1] #120 — feat(install): consumer install hardening
         #144 — feat(doctor): label seeding              (plan-approved)
         #145 — feat(install): CLAUDE.md cleanup         (in-progress)
         #146 — feat(install): settings.json patch       (plan-pending)
 [P2] #131 — feat(observability): self-improve loop
         (all children closed — pending auto-close)
================================================================
ORPHANS
================================================================
 (run)
    [P1] #133 — feat(run): canonical status table grouped by tracker + scope   (plan-pending)
    [P2]  #34 — feat(run): sort status table by scope                           (ready)
 (doctor)
    [P2] #150 — feat(doctor): settings cleanup patch                            (merged)
 (none / generic)
    [P2] #999 — chore: bump tooling                                             (ready)
================================================================
```

NOTES footer

```
NOTES (non-default)
================================================================
 Issue  | Target Base | Path | Blocked by | att
----------------------------------------------------------------
 #150   | next        | A    | --         | 0
 #133   | pipeline    | B    | #132       | 3
================================================================
```

Counts footer

```
5 epics + 19 children + 5 orphans = 29 open
```
