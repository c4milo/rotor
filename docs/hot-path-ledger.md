# Hot-path ledger

One row per use of a technique that `docs/decisions/0007-hot-path-ugliness.md` confines to the
named hot files. A use with no row here does not land. The harness re-measures every row at each
milestone, and a row whose gain is gone is removed together with the code it justified.

**The ledger is empty.** No hot-path code exists yet, so every hot file starts plain.

| id | file and function | technique | harness workload | before | after | machine | commit | date |
|---|---|---|---|---|---|---|---|---|
