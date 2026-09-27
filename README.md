# qmdmm-signing-lab

A **disposable** end-to-end rehearsal of the QMdmm distro signing scheme: a root
key signs the keyring source, and each distro line gets its own sign-only subkey
which signs that line's packages and repository metadata.

Everything here is throwaway — the keys are test keys and this repository is
meant to be deleted. The point is to find the traps before the real thing.

Results and traps: **[FINDINGS.md](FINDINGS.md)**.

## Published layout

Pages serves the `gh-pages` branch (pushed by CI, not deployed as an artifact),
and what lands there **is** the repository layout — a consumer points straight
at it:

| Path | What | How a consumer uses it |
|---|---|---|
| `<pages>/debian` | day-to-day source (subkey-signed) | `deb [signed-by=…] <pages>/debian sid main` |
| `<pages>/debian-keyring` | keyring source (root-signed) | `deb [signed-by=…] <pages>/debian-keyring sid main` |
| `<pages>/debian-revoked` | fixture signed by a since-revoked subkey | nothing — a test asserts it is *rejected* |
| `<pages>/fedora` `<pages>/rocky` `<pages>/alma` | rpm sources (subkey-signed) | `baseurl=<pages>/<line>` |
| `<pages>/arch` | pacman source (subkey-signed) | `Server = <pages>/arch` |
| `<pages>/keys/…` | public keys + fingerprints | `gpg --import` / eyeball the fingerprint |

**Why two directories for apt:** `Signed-By` names one key file per source, and
the whole design rests on the keyring source being verifiable by the root key
*alone*. So the keyring source and the day-to-day source cannot share a
directory — they carry different key files.

## In this repo

```
keys/     published public keys
  qmdmm-root.gpg                  root only, no subkeys  -> keyring repo's Signed-By
  <distro>/qmdmm-packages.gpg     root + that line's subkey -> day-to-day Signed-By
  fingerprints.txt
site/     material that must be built OFF-CI, staged at its published path
  debian-keyring/                 the root-signed keyring source
  debian-revoked/                 the revoked-subkey fixture
lab/      the scripts — all reusable, all English
  sign-debian.sh    sign-rpm.sh    sign-arch.sh
  verify-debian.sh  verify-rpm.sh  verify-arch.sh
  mkrepo-debian.sh  rotate-debian-local.sh
```

`sign-rpm.sh` is shared by fedora / rocky / alma: signing is a property of the
packaging format, not of the distro.

## Job split, and why

| Job | Declares `environment:` | What it proves |
|---|---|---|
| `sign-debian`, `sign-rpm`, `sign-arch` | **yes** (one per line) | gets that line's subkey secret; signs inside the real distro container |
| `publish` | — | assembles the site and pushes `gh-pages` |
| `verify-debian`, `verify-rpm`, `verify-arch` | **no** | holds no secret at all — exactly a consumer's position |

The verify jobs are the interesting half: not declaring an `environment:` means
`${{ secrets.* }}` expands to empty, so they see nothing but what Pages
publishes.

One assertion is deliberately inverted. `verify-rpm` on `fedora:43` carries
`EXPECT_METADATA_REJECTED=1`, because rpm 6.0.2 / dnf5 5.2.18 cannot verify
`repomd.xml` signed by a gpg key at all (all six key shapes probed — FINDINGS.md
§4.1). With the flag, a *rejection* passes and a *success* fails, so the job is
green while the limitation stands and turns red the day fedora fixes it. Scenario
B is skipped there for the same reason.

## Running it

Push to `main`, or dispatch the workflow. The two steps that must stay off CI:

    # build the root-signed keyring source
    bash lab/mkrepo-debian.sh <root-fpr> site/debian-keyring sid "keyring source (root-signed)"

    # rotate the debian subkey (freezes a fixture first, then prints the secret
    # that needs uploading)
    bash lab/rotate-debian-local.sh debian

Both expect a throwaway keyring plus a `$HOME/qmdmm-signing-lab/env.sh` holding
`GNUPGHOME` and the fingerprints — that file is not part of the repo.
