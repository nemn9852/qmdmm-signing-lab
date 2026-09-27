# qmdmm-signing-lab

A **disposable** end-to-end rehearsal of the QMdmm distro signing scheme: a root
key signs the keyring source, and each distro line gets its own sign-only subkey
which signs that line's packages and repository metadata.

Everything here is throwaway — the keys are test keys and the repository is
meant to be deleted. The point is to find the traps before the real thing.

Results and traps: **[FINDINGS.md](FINDINGS.md)**.

## Shape

```
keys/                 published material (this is what a consumer fetches)
  qmdmm-root.gpg          root public key only (no subkeys)
                          -> point the *keyring* repo's Signed-By at this
  <distro>/qmdmm-packages.gpg   root + that line's signing subkey
                          -> point the *day-to-day* repo's Signed-By at this

repo/                 the two sources themselves
  <distro>/keyring/       root-signed. Built locally (see below), never in CI -
                          the trust root must not enter a workflow.
  <distro>/daily/         subkey-signed. Produced by CI.
  <distro>/daily-revoked/ a frozen snapshot signed by a subkey that is since
                          revoked, kept so a test can prove it gets rejected.

lab/                  the scripts, all English, all reusable
  sign-debian.sh          build+sign the day-to-day source inside debian:sid
  sign-fedora.sh          ditto inside fedora (rpmsign + createrepo_c)
  sign-arch.sh            ditto inside archlinux (repo-add)
  verify-debian.sh        consumer: fetch keys from Pages, run 5-cell matrix
  verify-fedora.sh        consumer: metadata signature via repo_gpgcheck
  verify-arch.sh          consumer: demonstrates the lack of a per-repo scope
  mkrepo-debian.sh        build+sign an apt source with a given key (local use)
  rotate-debian-local.sh  rotate one line's subkey without touching root

.github/workflows/signing-lab.yml
```

## Job split, and why

| Job | Declares `environment:` | What it proves |
|---|---|---|
| `sign-<distro>` | **yes** | gets that line's subkey secret; signs inside the real distro container |
| `publish` | `github-pages` | keys + both sources land on Pages |
| `verify-<distro>` | **no** | holds no secret at all — exactly a consumer's position |

The verify jobs are the interesting half: not declaring an `environment:` means
`${{ secrets.* }}` expands to empty, so they see nothing but what Pages publishes.

## Running it

Push to `main`, or dispatch the workflow. Locally, the parts that must not go
through CI are:

    # one-off: build the root-signed keyring source for debian
    bash lab/mkrepo-debian.sh <root-fpr> repo/debian/keyring "keyring source (root-signed)"

    # rotate the debian subkey (and upload the new secret it prints)
    bash lab/rotate-debian-local.sh debian

Both expect a throwaway keyring and a `$HOME/qmdmm-signing-lab/env.sh` holding
`GNUPGHOME` plus the fingerprints; neither is part of the repo.
