# qmdmm-signing-lab

A **disposable** end-to-end rehearsal of the QMdmm distro signing scheme: a root
key signs the keyring source, and each distro line gets its own sign-only subkey
which signs that line's packages and repository metadata.

Everything here is throwaway — the keys are test keys and this repository is
meant to be deleted. The point is to find the traps before the real thing.

Results and traps: **[FINDINGS.md](FINDINGS.md)**.

## What one run does

Five stages of its own, in order (they are not the same five as the pipeline
below — see "How this relates to QMdmmPackagingCi"). All of it is
`workflow_dispatch` only: a run is twelve real Qt 6 builds, which is not
something to start on every push.

| Stage | Jobs | Declares `environment:` | What it proves |
|---|---|---|---|
| **A** pack | `stage-a-pack` × 12 | no | QMdmmPackagingCi's *own* `pack-<fmt>.sh` builds real packages inside the row's own distribution image |
| **S** sign | `stage-s-sign` × 12 | **yes**, one per line | the row's subkey signs the repository it just built — and the root secret is *not* usable in that container |
| **B** consume | `stage-b-consume` × 12, `stage-b-keyring`, `stage-b-keyring-package`, `stage-b-revoked` × 2, `stage-b-rotated` × 3 | no | a real consumer, holding no secret, establishes trust the way a user does and then installs from the published repository; the root key alone would not have been enough; a revoked key does not stop every consumer; and a **rotation** costs an un-refreshed consumer the repository outright — with the rpm cells also measuring which key file the rotated line should publish |
| **C** taint | `stage-c-taint` × 4 | no | tampering with published metadata is detected — with the *untouched* copy as a control |
| publish | `publish` | no | the site assembled on gh-pages **is** the repository layout |

Only `stage-s-sign` declares an environment. That is the whole trick: without
it `${{ secrets.* }}` expands to empty, so every B and C job sits in exactly a
consumer's position rather than a rehearsal of one.

## How this relates to QMdmmPackagingCi

One pipeline — four stages from that repository, two from this one:

    CI.A pack → CI.B runtime → CI.C dev → S sign → B consume

| Stage | Lives in | What it establishes |
|---|---|---|
| **A** pack | QMdmmPackagingCi | the packages exist |
| **B** runtime | QMdmmPackagingCi | the runtime dependency closure is complete — with the signature question switched off (`[trusted=yes]` on deb, `gpgcheck=0` on rpm, an unsigned `repo-add` on pac) |
| **C** dev | QMdmmPackagingCi | the *dev* package is sufficient to build a consumer project against |
| **S** sign | this lab | the repository is signed by that line's subkey |
| **B** consume | this lab | the trust bootstrap: install the keyring, establish trust, install the signed package |

**Stage A reimplements nothing.** It checks that repository out and runs its own
`ci/pack-<fmt>.sh` inside the row's distribution image; nothing under `lab/`
builds a package.

**This lab's B consume stays, and it is not that repo's B.** Its subject is the
*trust bootstrap* — the path a real user walks: install the keyring, establish
trust in the line's key, then install a package signed by it. Two halves:

- `stage-b-keyring` and `stage-b-keyring-package` are the "install the keyring"
  half. The keyring arrives as a **package**, from a source the **root key alone**
  verifies; the cell then throws away every source it wrote by hand, so that what
  carries the repository configuration is the package and nothing else.
- `stage-b-consume` (× 12) is the "establish trust, then install" half. It takes
  the line's public key the way a consumer would, trusts it, and installs the
  runtime package from the signed repository — having first asserted, in the same
  cell, that holding the root key alone is *not* enough.

The dev package is not installed here because its dependency closure is that
repo's C, and that is a question about package *content* rather than about trust.
The consumer cells still assert the dev and doc packages are **served**
(`served == built`); they just do not install them.

Where that repo has no counterpart at all, this lab adds the rest of the trust
chain: `stage-a-revoked-fixture`, `stage-b-revoked`, `stage-c-taint`.

### S belongs after C, not after A

That repo's B and C do not run here, so the workflow reads
`A → S → publish → B` — those two stages are **absent, not reordered**. The
pipeline the two repositories form *together* is the five-stage one above.

**S must not run until that repo's B and C have passed.** A signature asserts that
the thing it covers is worth trusting, so appending it to packages nobody has
installed yet means the release gets interrupted *after* the signature is already
public — which is the failure that gate exists to prevent. The port therefore
reads `A → B → C → S`.

### The colliding names are a port-time rename

That repo names its stages `A pack` / `B runtime` / `C dev`; this lab names its
`A pack` / `S sign` / `B consume` / `C taint`. Its B and this lab's B are
different stages that happen to share a letter, which is a readability problem
rather than a design one. It goes away when the signing stages move into that
repo, where they should be named for what they do rather than reuse the letters.

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
                                  (after a rotation: root + outgoing[revoked] + incoming,
                                   because a consumer that refreshed should be told
                                   "revoked" rather than "unknown key")
  <line>/qmdmm-packages-before.gpg  the same line, as it looked before its rotation —
                                  i.e. what a consumer that has NOT refreshed holds.
                                  A fixture, not something to hand anyone.
  <line>/qmdmm-packages-pruned.gpg  the same line with the outgoing (revoked)
                                  subkey dropped — what a rotated line could
                                  publish instead. Not handed to anyone either:
                                  it exists so the choice can be measured
                                  (FINDINGS 10.9).
  fingerprints.txt                the list the site's front page shows. Names
                                  each line's CURRENT subkey; a rotated line's
                                  key *file* is bigger than its row here.
site/   material that must be built OFF-CI, staged at its published path
  debian-keyring/                 the root-signed keyring source, which now ships
                                  qmdmm-archive-keyring
  debian-revoked/                 the revoked-subkey fixture (debian's rotation)
  <line>-revoked/                 the same thing for the rotated rpm and pacman
                                  lines: the source that line published immediately
                                  before its subkey was rotated
lab/    the scripts — all reusable, all English
  sign-repo-{deb,rpm,pac}.sh      stage S, format-level
  consume-{apt,dnf,pacman}.sh     stage B, consumer-level
  consume-apt-keyring.sh          stage B, the half that is built off-CI
  consume-keyring-package.sh      stage B, install the keyring package and then
                                  delete every source but the one it configured
  consume-revoked-{dnf,pacman}.sh stage B, revocation is only as good as the
                                  verifier (FINDINGS 10.7)
  consume-rotated-{dnf,pacman}.sh stage B, what a ROTATION does to a consumer
                                  (FINDINGS 10.9): four corners, two of which no
                                  revocation test can reach. The dnf one also
                                  runs the counterfactual — the same key file
                                  with the revoked subkey dropped — because on
                                  rpm that is the difference between a closed
                                  and an open leak window.
  check-fingerprints.sh           assert keys/fingerprints.txt names each
                                  line's current subkey. A gate, not a probe:
                                  the publish job puts that list on the site
                                  and a stale entry advertises a revoked key
  taint-repo.sh                   stage C, tampering must be detected
  mkrepo-debian.sh                build + sign a minimal apt tree (off-CI)
  mkrepo-revoked-{rpm,pac}.sh     build the revoked-key fixtures — in CI, because
                                  the signing key exists only as a secret there
  mkkeyring-deb.sh                build <repo>-archive-keyring (off-CI)
  rotate-line-local.sh            rotate any line's subkey (off-CI)
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

    # rotate any line's subkey (debian|ubuntu|fedora|rocky|alma|arch|manjaro)
    bash lab/rotate-line-local.sh fedora

Both expect a throwaway keyring plus a `$HOME/qmdmm-signing-lab/env.sh` holding
`GNUPGHOME` and the fingerprints — that file is not part of the repo.

The rotation, in order, and steps 1 and 2 are the ones that cannot be undone:

1. **freeze what a consumer holds now.** Two files, both taken *before* the
   revocation: `keys/<line>/qmdmm-packages-before.gpg` — root + outgoing, with no
   revocation certificate in it — and `site/<line>-revoked/`, the source that
   line publishes right now. Exported after the revocation, the first one carries
   the certificate and becomes the *other* cell of the 2x2, which is worse than
   useless: it looks right. The second is fetched from Pages for the rpm and
   pacman lines, so it has to happen before the next publish rebuilds the row;
2. revoke the outgoing subkey;
3. add a fresh signing subkey;
4. re-sign what only the root key may sign. For the deb lines that is the keyring
   source. For the rpm and pacman lines there is no such artifact in this lab, so
   the step is **absent and says so** rather than being skipped in silence;
5. re-export the line's public key file as root + outgoing[revoked] + incoming —
   and, alongside it, `-pruned.gpg`: the same key file with the outgoing subkey
   dropped. Which of the two a line should publish is a measured question rather
   than a preference: on rpm the revoked subkey's presence in the file is what
   keeps it able to sign (FINDINGS 10.9);
5b. rewrite that line's row in `keys/fingerprints.txt`, so the list the site
   shows names the incoming subkey. `lab/check-fingerprints.sh` is the gate that
   catches it if this is ever skipped;
6. write the incoming subkey's secret.

Step 6 does not finish the job. Until the secret is uploaded to that line's
environment **and** the workflow is re-run, the line has no usable private half
in CI and stage S fails — which is the honest state, not a bug. Uploading it also
removes the outgoing key from GitHub, which is half the point.
