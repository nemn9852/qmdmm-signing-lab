# Signing lab — findings

End-to-end rehearsal of the QMdmm distro signing scheme, run entirely against
throwaway keys in a throwaway repo. What follows is what the run actually
taught us, ordered by how much it changes the design.

Scheme under test, per line (distro):

```
root key            (never in CI; signs the keyring source only)
└── P_<distro>      (sign-only subkey; its secret lives in that line's
                     GitHub Environment; signs packages + repo metadata)
```

Consumers get the root public key from Pages and verify with it; a leaked
`P_<distro>` must not be able to forge the source that carries the trust root.

---

## 1. Results

| Check | Result |
|---|---|
| Root key signs keyring source; consumers verify it | **pass** |
| Per-line subkey signs day-to-day source; consumers verify it | **pass** |
| **Keyring source verified with the per-line subkey's key** | **REJECTED** |
| Day-to-day source verified with a refreshed (rotated) key file | **pass** |
| **Source signed by a revoked subkey, verified after rotation** | **REJECTED** |
| Root secret absent inside every signing container | **pass** |
| Rotating one line leaves the root key and the other lines untouched | **pass** |
| Verify jobs see no secret at all (no `environment:` declared) | **pass** |

Exact rejection messages, because they are the evidence:

```
debian, keyring source vs subkey key:
  Sub-process /usr/bin/sqv returned an error code (1), error message is:
    Missing key 22F94DB1069D1F24505CB5675779CAB6443DA554, which is needed to
    verify signature.
  E: The repository '…/repo/debian/daily stable InRelease' is not signed.

debian, revoked subkey's output vs refreshed key file:
  Sub-process /usr/bin/sqv returned an error code (1), error message is:
    Signing key on DB05E5D9027139A493E7C9DDCD290DDA2AE83D38 is bad:
      Invalid key: "signing key is revoked"
  E: The repository '…/repo/debian/daily-revoked stable InRelease' is not signed.

pacman, day-to-day db verified with only the root key imported:
  error: lab: key "1D569E0B4281AA59A13217B0B7681D0609159052" is unknown
  error: failed to synchronize all databases (invalid or corrupted database
    (PGP signature))

rpm, repomd.xml signed by the subkey, verified against the root key:
  >>> repomd.xml GPG signature verification error: Signing key not found
```

## 2. What held up

- **The isolation is real.** On debian the keyring source is only accepted when
  the key file contains the root key; the day-to-day subkey cannot sign anything
  that replaces the trust root. That is the entire point of splitting the keys,
  and it works.
- **Rotation is cheap and narrow.** Rotating the debian subkey touched neither
  the root key nor the fedora/arch lines. Consumers needed only a refreshed
  per-line key file; nothing else moved.
- **Revocation actually stops installs on debian.** `sqv` refuses a revoked
  subkey's signature outright (see §1). Worth stating plainly, because the
  opposite is true one layer down — see §3.1.
- **Verify jobs really do hold no secret.** Declaring no `environment:` is
  enough: `${{ secrets.* }}` expands to empty. That makes the verify job a
  faithful stand-in for a consumer, for free.
- **The trust root never enters CI.** Every sign container asserted that the
  primary secret is unusable there (by attempting to sign with it and failing).
  The root key only ever moves on a trusted machine.

## 3. Traps

### 3.1 Revocation is only as good as the verifier

`sqv` (which apt uses) rejects a revoked subkey hard. **`gpg --verify` does
not**: it still prints `Good signature from …`, exits **0**, and only adds
`WARNING: This subkey has been revoked by its owner!`. It also does not compare
signature time against revocation time, and the signature timestamp is
self-asserted, so back-dating changes nothing.

⇒ Any CI assertion built on `gpg --verify`'s exit code, or on grepping
`Good signature`, will silently accept signature made by a revoked key. The
only reliable signal is `--status-fd`: a revoked signer yields `REVKEYSIG`
instead of `GOODSIG`, plus `KEYREVOKED`.

### 3.2 `dnf makecache` exits 0 when metadata signature verification fails

It prints `>>> repomd.xml GPG signature verification error: Signing key not
found` and still returns **0**, having "created" the metadata cache. Asserting
on the exit code produced a false red during this run. Assert on the message.

### 3.3 `gpg -o /dev/null` destroys `/dev/null` inside the container

Signing a probe with `-o /dev/null` replaced the character device, after which
every later `</dev/null` and `2>/dev/null` in the same script died with
`/dev/null: No such file or directory`.

This one is worth internalising because the symptom appears far from the cause:
it made `rpmbuild`'s `check-buildroot` abort with `xargs: '/dev/null': No such
file or directory` and a bogus `Found '…BUILDROOT' in installed files`, which
looks like a packaging problem and is not.

### 3.4 Package managers eat stdin

Reading the secret with `IFS= read -r` only works if it happens **before**
anything that touches stdin. `apt-get`, `dnf` and `pacman` will happily consume
it first, and then `gpg --import` reports `no valid OpenPGP data found` — which
looks like a corrupt key and is not.

### 3.5 Never pin a fingerprint that is supposed to change

The workflow originally passed each line's subkey fingerprint in as an env var.
The first rotation broke signing immediately, because the pinned value was by
definition the old one. The sign scripts now discover the subkey from the
keyring they just imported and assert that exactly one usable subkey is present
— which doubles as a useful least-privilege check. Rotating a subkey no longer
requires touching the workflow.

### 3.6 Per-toolchain detail that cost time

| Thing | Reality |
|---|---|
| `rpmsign` | lives in `rpm-sign`, **not** `rpm-build` |
| rpm 6 on f44 | default OpenPGP backend is already `gpg` (`%_openpgp_sign`); no need to force it |
| Signing a distro-provided rpm | it already carries the distro's legacy signature; `rpmsign --delsign` first |
| `createrepo_c` on f44 | no `--disable-deltarpm`; plain `createrepo_c <dir>` |
| `createrepo_c` generally | does not sign anything itself — the metadata signature is a plain `gpg --detach-sign --armor` |
| `archlinux:base` | ships an entirely commented-out mirrorlist; `pacman -Sy` fails with "no servers configured" until one is added |
| `repo-add` | creates `lab.db -> lab.db.tar.gz` **symlinks**; artifact upload / Pages do not preserve them, so materialise real files (and copy `.db.tar.gz.sig` to the `.db.sig` name pacman asks for) |
| gpg 2.5.24 `.rev` files | the armor BEGIN line is prefixed with `:` — gpg itself cannot import them; strip the preamble and that colon |
| environment secrets | visible only to jobs that declare `environment:` — a feature here, not a nuisance |

## 4. rpm is not one behaviour, and it is not an algorithm problem

The lab assumed one rpm line would stand in for all rpm distros. That is wrong,
and the way it is wrong is worth more than the rest of this document.

| distro | rpm | dnf | repo_gpgcheck result |
|---|---|---|---|
| `fedora:43` | **6.0.2** | **dnf5 5.2.18** | **fails** — `Signing key not found` |
| `rockylinux/rockylinux:10` | 4.19.1.1 | **dnf 4.20** | passes |
| `almalinux:10` | 4.19.1.1 | **dnf 4.20** | passes |

(`dnf 4.20`, not dnf5 — the earlier note claiming EL10 was dnf5 was simply wrong.)

Before blaming a key type, both hypotheses were tested directly, in the same
container, with the same throwaway key:

| | subkey signs metadata | primary signs metadata |
|---|---|---|
| fedora:43, ed25519 | fail | fail |
| fedora:43, rsa4096 | fail | fail |
| rocky:10, ed25519 | pass | pass |
| rocky:10, rsa4096 | pass | pass |

So **it is neither the algorithm nor the subkey**: switching to RSA does not buy
anything here. dnf5 on fedora:43 is not obtaining the key from `gpgkey=` at all.
Binary and armored `gpgkey=` both fail.

What fedora prints while trying is the useful part, and so is what it does not:

```
>>> repomd.xml GPG signature verification error: Signing key not found
Importing OpenPGP key 0x2C2B3684:
    keyring: /tmp/keyimport/cache-binary-gpgkey/lab-.../pubring
      E9B30B832C2B3684.pub   2825 bytes
```

**The import succeeds and verification fails anyway.** dnf5 writes a real,
2825-byte public key file named after the keyid into its per-repo keyring, and
then reports `Signing key not found` for metadata signed by that very key.

**Correction (second revision of this paragraph).** An earlier attempt at this
said the keyring was left empty ("0 bytes"), based on a `wc -c` that was being
handed a *directory* and on trying to read that directory as a gpg homedir. The
directory does contain the key. The import side of dnf5 is working; whatever is
broken is on the verification side.

**Also retracted:** `rpm --import` "failed on both distros" was my probe's
error, not a finding. rpm wants armored input and was handed the binary export
(`error: /tmp/keyimport/pub.gpg: key 1 not an armored public key`). It is not
evidence about EdDSA or about rpm's parser.

**Correction (this document previously claimed something false here).** An
earlier revision said "the same key is reported under a different keyid by the
two systems" — fedora `0x64947284` vs rocky `0xE762F939` — and inferred an
OpenPGP v6-vs-v4 keyid mismatch from it. That was wrong: this probe generates a
**throwaway key inside each container**, so fedora and rocky necessarily work on
different keys. The two fingerprints were read back and they are, indeed, that
run's own keys (note: a *later* run gives fedora `0x2C2B3684`, a third key —
the number is never comparable across runs, which is the whole point):

```
fedora:43  root = 9E84FC1D5CC3AB463F9B0DFFE7C5A6AF64947284   -> "0x64947284"
rocky:10   root = B8BC55DBA7263BF85F85DEC2390773D1E762F939   -> "0xE762F939"
```

Each system was printing the tail of its own key. There is no cross-system keyid
discrepancy to explain, and **no v6/v4 finding here at all**.

(Related, same revision: it also said the `rpm --import` variants "do not help
either". Those two variations were never run — `set -e` plus a failure inside
the third `attempt` killed the job after variation 2. The probe is now written
without `set -e` and reports all four; see below.)

Consequences for the real scheme:

- **Do not collapse the rpm lines.** "One representative distro is enough"
  held for deb and pacman in this run; it does not hold here.
- **fedora 43+ needs its own answer**, and that answer is not a different key
  type. It may be a v6 key (gpg 2.5+ can make one; 2.4 cannot), or accepting
  that `repo_gpgcheck` is not available there yet.
- EL10 (rpm 4.19 / dnf4) behaves exactly as the design wants: per-repo metadata
  signing works, and only the key named in `gpgkey=` may sign it.

## 5. Two-layer rpm keyring, confirmed

`dnf`'s `repo_gpgcheck` verifies `repomd.xml` against a **per-repository**
keyring, created under `$cachedir/<repo>-<urlhash>/pubring` (observed:
`/tmp/dnfcache/lab-c3e0938e8e5d9a18/pubring`). Package-level `gpgcheck` goes
through the **global rpmdb** instead.

The run proves the split rather than assuming it: the subkey was already
imported into the global rpmdb, and dnf still rejected metadata signed by it
when the repo's `gpgkey=` pointed at the root key. If dnf consulted the rpmdb
for metadata, that scenario would have passed.

## 6. pacman has no per-repo trust scope

With only the root key imported and locally signed, `pacman -Sy` against a db
signed by the line's subkey fails outright ("key … is unknown", then "invalid or
corrupted database (PGP signature)"). Trust is decided by which keys are
`lsign`ed into the single global keyring, not by the repo stanza.

⇒ On pacman the keyring package cannot be protected by repo configuration; it
must be distributed out of band (the ArchWiki unofficial-keys route: download,
check the fingerprint, `pacman-key --add`, `--lsign-key`).

## 7. Carrying forward

Every sign container should keep asserting, as this lab does:

1. exactly one usable subkey is present;
2. the primary secret cannot sign.

And every consumer-side check should assert on the verifier's *message*, not
its exit code, until you have confirmed which verifier is in play — per §3.1 the
two common ones disagree.
