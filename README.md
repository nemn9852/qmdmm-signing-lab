# qmdmm-signing-lab

A **disposable** end-to-end rehearsal of the QMdmm distro signing scheme: a root
key signs the keyring source, and each distro line gets its own sign-only subkey
which signs that line's packages and repository metadata.

Everything here is throwaway — the keys are test keys and this repository is
meant to be deleted. The point is to find the traps before the real thing.

Results and traps: **[FINDINGS.md](FINDINGS.md)**.

## What one run does

Five stages, in order. All of it is `workflow_dispatch` only: a run is twelve
real Qt 6 builds, which is not something to start on every push.

| Stage | Jobs | Declares `environment:` | What it proves |
|---|---|---|---|
| **A** pack | `stage-a-pack` × 12 | no | the harness's *own* pack script builds real packages inside the row's own distribution image |
| **S** sign | `stage-s-sign` × 12 | **yes**, one per line | the row's subkey signs the repository it just built — and the root secret is *not* usable in that container |
| **B** consume | `stage-b-consume` × 12, `stage-b-keyring` | no | a real consumer, holding no secret, installs from the published repository; and the root key alone would not have been enough |
| **C** taint | `stage-c-taint` × 4 | no | tampering with published metadata is detected — with the *untouched* copy as a control |
| publish | `publish` | no | the site assembled on gh-pages **is** the repository layout |

Only `stage-s-sign` declares an environment. That is the whole trick: without
it `${{ secrets.* }}` expands to empty, so every B and C job sits in exactly a
consumer's position rather than a rehearsal of one.

## Published layout

Pages serves the `gh-pages` branch (pushed by CI, not uploaded as a deploy
artifact), and what lands there **is** the repository layout — a consumer
points straight at it:

| Path | What | How a consumer uses it |
|---|---|---|
| `<pages>/<line>/<version>` | day-to-day source, subkey-signed — 12 of them | `deb [signed-by=…] <pages>/debian/sid sid main`<br>`baseurl=<pages>/fedora/44`<br>`Server = <pages>/arch/rolling` |
| `<pages>/debian-keyring` | keyring source, **root**-signed | `deb [signed-by=…] <pages>/debian-keyring sid main` |
| `<pages>/debian-revoked` | fixture signed by a since-revoked subkey | nothing — a test asserts it is *rejected* |
| `<pages>/revoked-rpm` `<pages>/revoked-pac` | repositories signed by the revoked fixture key | nothing — a test asserts both a rejection and, against the *same* artifact, an acceptance |
| `<pages>/keys/…` | public keys + fingerprints | what every consumer in this lab fetches |

Each line has **one** subkey covering all of that line's versions: the same key
signs `debian/{trixie,forky,sid}`, and the same key signs `fedora/{44,45,rawhide}`.
Rotating a line replaces one subkey.

**Why two directories for apt:** `Signed-By` names one key file per source, and
the whole design rests on the keyring source being verifiable by the root key
*alone*. So the keyring source and the day-to-day source cannot share a
directory — they carry different key files.

## The two axes

The grid carries two independent axes, and collapsing them is the mistake this
lab exists to avoid:

- **format** — `deb` / `rpm` / `pac`. What stage S produces, and therefore which
  script signs it (`sign-repo-<fmt>.sh`). One signed rpm repository serves every
  rpm consumer; nothing in stage S is dnf-specific.
- **consumer** — `apt` / `dnf` / `pacman`. Which program reads it, and therefore
  which script verifies it (`consume-<consumer>.sh`) and which command re-reads
  the metadata when it is tampered with (stage C).

`rpm` is not `dnf`, so stage C runs two rpm cells: fedora's dnf5 and EL's dnf4 do
not share a verification implementation. A later openSUSE row would add a third
(`zypper`) without touching anything in stage S.

## In this repo

```
keys/   published public keys
  qmdmm-root.gpg                  root only, no subkeys  -> the keyring repo's Signed-By
  <line>/qmdmm-packages.gpg       root + that line's subkey -> the day-to-day Signed-By
  fingerprints.txt
site/   material that must be built OFF-CI, staged at its published path
  debian-keyring/                 the root-signed keyring source
  debian-revoked/                 the revoked-subkey fixture
lab/    the scripts — all reusable, all English
  sign-repo-{deb,rpm,pac}.sh      stage S, format-level
  consume-{apt,dnf,pacman}.sh     stage B, consumer-level
  consume-apt-keyring.sh          stage B, the half that is built off-CI
  taint-repo.sh                   stage C, tampering must be detected
  mkrepo-debian.sh                build + sign a minimal apt tree (off-CI)
  mkkeyring-deb.sh                build <repo>-archive-keyring (off-CI)
  rotate-debian-local.sh          rotate one line's subkey (off-CI)
  lib-site.sh                     waiting for the deploy, fetching keys, assertions
  lib-tools.sh                    md5sum / sha256sum / dpkg-deb, nothing else
  probe-*.sh                      the one-off probes, kept as the reproducible
                                  path behind FINDINGS §4. No longer wired into
                                  the workflow, except probe-matrix-tags.sh,
                                  which is a real gate rather than a probe.
  lines.tsv                       issue #24 as data; the workflow's matrices are
                                  a mirror of it and the two must stay in step
```

## Running it

Dispatch the workflow. Two steps must stay **off** CI — the root secret never
enters a workflow, so both are run on a trusted machine:

    # rebuild the root-signed keyring source after a change to the layout
    bash lab/mkrepo-debian.sh <root-fpr> site/debian-keyring sid "keyring source (root-signed)"

    # rotate one line's subkey: freeze a fixture with it first, revoke it, add a
    # fresh one, re-sign the keyring source, and print the secret that then has
    # to be uploaded to that line's environment
    bash lab/rotate-debian-local.sh debian

Both expect a throwaway keyring plus a `$HOME/qmdmm-signing-lab/env.sh` holding
`GNUPGHOME` and the fingerprints — that file is not part of the repo.
