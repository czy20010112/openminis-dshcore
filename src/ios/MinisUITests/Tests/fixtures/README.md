# Test fixtures

These files are read by `KeyboardAcceptanceTests` **at run time, from the test
bundle**, so a run needs no compiled-in data and no launch-time payload.

The rule they exist to enforce: a fixture may supply **the id of a Session that
already exists**, and nothing else. No transcript, no token, no credential. A UI
test entry point that can fabricate a whole remote Session from a base64 blob is
indistinguishable from a backdoor to anyone reading this repository — so this suite
does not have one, and should not grow one.

| File | Holds | Needed by |
|---|---|---|
| `remote-session.txt` | one remote Session id, on one line | `testRemoteSlashMenuArrowKeys` |

## Filling them in

Put the simulator in a state where the thing to be tested is on screen, then read
the id out of that state and paste it here (one line, no quotes):

```
session-50163110-e576-4777-8bef-05e9345348fa
```

Until a file exists and no longer says `REPLACE_ME`, the case **skips** with the
reason in the log. A skip is the correct outcome for a fixture that is not there —
a red build caused by a missing fixture is how a suite gets ignored.

## Why not `-MINIS_DSH_SESSION_B64`

`DSHRemoteAcceptance` uses that hook, and it is the wrong tool for these cases: it
builds a Session that never existed on a host, so every assertion afterwards is about
the app talking to a fixture instead of to a computer. These cases are about the
**real** composer in the **real** paired state; the fixture only says which
conversation to open.
