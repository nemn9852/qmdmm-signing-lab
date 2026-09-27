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

### 3.7 A control group has to be the *same object*

Two mistakes here were the same mistake, and it cost two rounds:

- The two probe containers each generated their **own** throwaway key, so
  fedora's `0x64947284` and rocky's `0xE762F939` were never the same key. A
  "different keyid on the two systems" theory was built on that, and written up,
  before anyone checked whether the two samples were the same thing. Read the
  fingerprints back first: they were each printing their own key's tail.
- `rpm --import` "failing on both distros" was the probe handing rpm the
  **binary** export; rpm wants armor
  (`error: ...: key 1 not an armored public key`). That is a caller error being
  read as a property of rpm. It would have gone straight into a conclusion
  about EdDSA if the error text had not been captured.

Cheap countermeasure, used from then on: have the probe **print the identity it
is working on** (`keyid 0x…`) next to every verdict, and make non-fatal
diagnostics non-fatal (`set -e` killed one probe before it reached half its
cases, so two of four variations were reported as results when they never ran).

### 3.8 Reading a path without checking whether it is a file

The first version of the keyring check said "imports nothing — 0 bytes", which
was wrong twice: `wc -c` was handed a **directory** (so the size was
meaningless), and the directory was then read as a gpg homedir (so the listing
came back empty). It actually contained a 2825-byte key file. Two independent
wrong readings agreed with each other, which is exactly how a false result gets
confidence. Print `ls -la`, not a size.

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

**The import succeeds; verification fails.** dnf5 writes a real 2825-byte
public-key file, named after the keyid, into its per-repo keyring — and then
reports `Signing key not found` for metadata signed by that very key. So this is
not an import problem, and the per-repo keyring does hold the key.

The verify-side probe then removed the remaining suspects (fedora:43, ed25519):

| what signs the metadata | signature issuer keyid | file dnf stored | result |
|---|---|---|---|
| subkey | `4F89842A54B9D7C8` | `59C81CF071BE36C3.pub` (the primary) | rejected |
| primary | `2764BAC9BE637229` | `2764BAC9BE637229.pub` | rejected |
| primary, keyblock has no subkey at all | `ABE3EFDD280A3EDD` | `ABE3EFDD280A3EDD.pub` | rejected |

rsa4096 repeats the same three rejections, also with the keyid matching exactly
in the two primary cases. **So it is neither a keyid lookup miss, nor the
subkey, nor the algorithm:** rpm 6.0.2 / dnf5 5.2.18 on fedora:43 will not
verify a `repomd.xml` signed by a gpg-generated key at all, while rpm 4.19 /
dnf 4.20 accepts every shape. The split is version-correlated.

Consequences for the real scheme:

- **Do not collapse the rpm lines.** "One representative distro is enough"
  held for deb and pacman in this run; it does not hold here.
- **fedora 43+ needs its own answer**, and that answer is not a different key
  type (§4.1). The pragmatic one: do not rely on `repo_gpgcheck` there; sign
  packages and let `gpgcheck` do the work.
- EL10 (rpm 4.19 / dnf4) behaves exactly as the design wants: per-repo metadata
  signing works, and only the key named in `gpgkey=` may sign it.

### 4.1 The package-level path works on fedora:43 — and ed25519 is fine

Since `repo_gpgcheck` is unusable there, the question became whether the
*package* path still works, which is also the old "EdDSA signs fine, installs
badly" question. Asked directly on fedora:43 (rpm 6.0.2, dnf5 5.2.18, gpg 2.4.9,
`%_openpgp_sign` = `gpg`), same key as the rest of the lab (primary + signing
subkey):

| step | ed25519 | rsa4096 |
|---|---|---|
| `rpm --import` armored export | rc=0, key lands in the rpmdb | rc=0 |
| `rpm --import` binary export | rc=1 `not an armored public key` | rc=1 |
| `rpmsign --addsign` with the **subkey** | rc=0 | rc=0 |
| `rpm -K` signed package, key in rpmdb | **`digests signatures OK`** (rc=0) | same |
| `rpm -K` again after removing the key | `digests SIGNATURES NOT OK` (rc=1) | same |

Two things follow:

1. **Package-level signing on rpm 6 fedora:43 works, and it works with
   ed25519.** The EdDSA history did not reproduce here, so there is no evidence
   to force RSA for the real root key. (The last row matters: without it, the
   "OK" could have been a check that passes regardless.)
2. **`rpm --import` wants armor, not a binary key.** `gpgkey=` in a `.repo`
   file is a different path and accepted binary in this lab — but anything that
   shells out to `rpm --import` must be handed `.asc`.

So the fedora failure is confined to repository-metadata verification on
rpm 6 / dnf5, and it is not a reason to change key material.

### 4.2 How CI handles it: invert the assertion, do not accept a red job

`verify-rpm (fedora)` used to be red on every run. A job that is red by design
is worse than no job: it teaches everyone to read a red suite as normal, which
is how the next real regression gets missed. So the assertion is inverted
instead, scoped to that one line via `EXPECT_METADATA_REJECTED=1`:

| scenario A outcome | result |
|---|---|
| metadata rejected | **PASS** — reported as the known limitation |
| metadata verified | **FAIL**, and the message says the limitation is gone and the flag should be dropped |

Scenario B (root-only key must be rejected) is skipped under the flag, with the
reason printed: if A cannot be verified at all on this rpm/dnf, B says nothing
about the two-layer split. It remains asserted on both EL lines, where it does.

So the suite is green and still honest, and the day fedora fixes this the run
goes red for a reason worth acting on.

**And the inversion is proven to have teeth**, because a flag that makes a job
green is one careless change away from being a flag that makes it green *no
matter what*. `lab/probe-inversion-control.sh` takes the same script with the
same flag and runs it on rocky:10, where metadata verification does work. It
must exit non-zero — and the control also checks *why*, since a run that dies
earlier (a failed fetch, `wait_for_publish` timing out) would exit non-zero too
and prove nothing:

```
--- A. ... (key=packages.gpg, expect PASS)
    exit=0  signature-error-in-output=0
    => FAIL (expected the documented rejection, but it verified!)
       The known fedora:43 limitation appears to be FIXED.
       Drop EXPECT_METADATA_REJECTED for this line so A and B assert normally.
verify-rpm.sh exit = 1
OK: it failed, and for the documented reason (the limitation is absent here)
=> the inversion discriminates: green means 'still broken', red means 'fixed'
```

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
