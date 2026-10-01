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
| rpm bootstrap: a root-signed source hands a consumer the `*-release` package, which then configures the day-to-day source on its own (§10.10) | **pass** |
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

### 3.9 Silenced output cannot tell "did nothing" from "never ran"

The first dnf5-upgrade probe ran `dnf upgrade ... >/dev/null 2>&1` and then
reported "still 5.2.18". That is not a result: it is equally consistent with the
upgrade having found nothing, the command never executing, and the repos being
unreachable. Assertions about *absence* need the absence to be visible —
`dnf --refresh list --upgrades` and the upgrade's own output are what turned
"nothing happened" into "the repos offer no newer dnf5".

Same shape as 3.7. When a check reports that something is not there, print what
you asked and what came back, not just the conclusion.

### 3.10 Sourcing `/etc/os-release` silently overwrites your own variables

`. /etc/os-release && echo "  $PRETTY_NAME"` is the ordinary way to print which
distribution a container is, and it is a trap for anything that also takes a
`VERSION`: the file defines `VERSION`, `ID`, `HOME_URL` and a handful more, and
sourcing it assigns every one of them over whatever the script already had.

On `fedora:45` this turned `VERSION=45` into
`VERSION=45 (Container Image Prerelease)`, and the repository URL was built as

    .../fedora/45 (Container Image Prerelease)

so all twelve consumer cells reported "the source served no qmdmm package at
all" - a message that points at the repository, while the repository was fine.

Worth noting what it did *not* break: the signing stage reads the same value as
`SUITE`, a name this file does not define, so that stage stayed green throughout
and gave no hint at all. The fix is a `sed -n 's/^PRETTY_NAME=…'` helper instead
of renaming the variable, because renaming only defends against the collisions
you happened to hit today.

### 3.11 `apt-get update` exits 0 when a source fails to verify

It falls back to the index files it already holds:

    Err:1 https://…/debian/sid sid InRelease
      Sub-process /usr/bin/sqv returned an error code (1), error message is:
      Missing key 52A6DA92508F487EA0EC6DF53F4622CC95CDBFB4, which is needed to verify signature.
    W: An error occurred during the signature verification. The repository is not
       updated and the previous index files will be used.
    W: Some index files failed to download. They have been ignored, or old ones used instead.

Two warnings, no `E:` line, exit status **0** - and it says "the previous index
files will be used" out loud, which is the mechanism: the source was rejected
and the package list from the *previous, valid* fetch is still there to be used.

This is §3.2's shape in the other package manager, and it caught the same
assertion. "The update must fail" was green in the run where apt had just
rejected the signature. What works instead is to clear `/var/lib/apt/lists`
first and then ask what apt can still see: if `apt-cache search` can list a
package from that source, the source was accepted, whatever the exit status said.

### 3.12 An assertion that reads the wrong source is green for the wrong reason

After §3.11 the apt negative check was rewritten to clear the index and then ask
"can any qmdmm package still be seen". It was red in the next run - and wrongly,
because `apt-cache` answers that question out of **the dpkg status file** as well
as the index, and the positive half of the same job had just installed `qmdmm-6`.
So the check reported "apt still lists packages from a source it does not hold"
for a source apt had rejected.

The fix is to ask the narrower question the mechanism actually supports: after
clearing `/var/lib/apt/lists`, did anything from that source get written into
it? Counting `*Packages*` files at depth 1 is an answer about the repository;
asking `apt-cache` is an answer about the machine.

This is the §3.7 family again - the control has to be the same object - with a
different costume: the observation has to be the same mechanism.

### 3.13 A container can have curl and no trust store

Two cells waited fifteen minutes for a deploy, reporting
`site currently serves: nothing` the whole time. The deploy was fine. Both were
containers whose tooling step installed `curl` and **not** `ca-certificates`, so
every https request failed at the TLS handshake - and the only symptom, fifteen
minutes later, was upstream of the cause and pointed at Pages.

Two habits come out of it: install the trust store wherever curl is installed,
and ask the TLS question directly once, immediately after the tooling, so the
failure takes seconds and names itself. `assert_tls` in `lib-site.sh` does the
second.

### 3.14 Revoked subkeys are invisible by default, so "revoked" reads as "absent"

`gpg --list-keys` omits revoked subkeys. On this lab's keyring, after the
rotations so far - debian twice, then fedora, rocky and arch (§10.9):

    gpg --list-keys                                      | grep -c '^sub'  ->  7
    gpg --list-keys --list-options show-unusable-subkeys | grep -c '^sub'  -> 14

The seven it hides are exactly the seven revoked ones. `--with-colons` shows them
too, `sub:r:` in the validity field and a `fpr` line to identify them.

That default is how a *revoked* subkey gets read as an *absent* one, and
"absent" does not stay "absent" on a second visit: the follow-up reading is "an
unused subkey that was never revoked" - the shape of a live key nobody is
tracking, which is the one thing here worth panicking about. The lab's
first-generation debian subkey is the worked example. `5779CAB6…`
(`22F94DB1069D1F24505CB5675779CAB6443DA554`, created 2026-09-27 09:33 together
with the root key and the fedora/arch subkeys, and the key whose absence is §1's
`Missing key …` evidence) does not appear in `gpg --list-keys` at all. It is
revoked anyway - by the root key, at 2026-09-27 10:00:07, the same second its
successor `77E9E913…` was added.

The debian key file's history is the record, one commit per generation:

    94a15c4  root + 5779CAB6                          (gen 1, live)
    a81d76f  root + 5779CAB6[revoked] + 77E9E913      (rotation 1)
    b70a2d2  root + 77E9E913[revoked] + 3F4622CC      (rotation 2)

so the debian line was rotated **twice**, and each export carries the outgoing
subkey *with* its revocation certificate on purpose - that is what lets a
consumer report "revoked" rather than "unknown key". Nothing else carries it: no
other key file, no workflow, no published path. The site's `keys/` was checked
over Pages rather than from the working tree, and holds no trace of it. Its only
mention in the repository is §1's rejection message, where it is evidence rather
than a key.

Two ways to make `gpg` answer the question instead of inferring it: attempt a
signature with the subkey (`Unusable secret key` when revoked), and read the
subkey's packets directly (`sigclass 0x28`, a revocation signature from the key
that owns it). At the time of writing the lab's keyring held eleven subkeys,
seven live - one per line - and none of the four revoked ones was reachable from
anything published. After the first rpm and pacman rotations (§10.9) it held
fourteen: seven live, one per line, and **seven revoked**, of which five are
reachable from published material. That was checked over Pages rather than from
the working tree:

| revoked subkey | published in |
|---|---|
| `0CB6055F…` | `keys/fedora/qmdmm-packages.gpg` - and *unrevoked* in that line's `-before` file |
| `D7434719…` | `keys/rocky/qmdmm-packages.gpg` - same |
| `1D569E0B…` | `keys/arch/qmdmm-packages.gpg` - same |
| `C0408216…` | `keys/debian/qmdmm-packages.gpg` |
| `0B1F7C5A…` | both `keys/revoked-fixture*.gpg` - the fixture, a subkey that exists to be revoked |

The last row corrects this section as written: the fixture subkey *is* published,
in both of its states, because that pair is the whole point of it. What survives
is the point the section was making, and this is its sharper form - a revoked
subkey can be in the keyring, out of use, and reachable from nothing:

    5779CAB6443DA554   debian generation 1 (§1's "Missing key …" evidence)
    301F53C25DFA7FA5   created 2026-09-28 13:02:02, forty seconds before the
                       fixture subkey that is in use, and identified when it was
                       found as a rehearsal product of creating the fixture key

### 3.15 On dnf5, a repository that cannot be verified is refused in silence

dnf4 and dnf5 do not just differ in behaviour; they differ in whether they *say*
anything. The same pair of readings - one source the key file can verify, one it
cannot, one repository configuration, nothing different but the key file (§10.9
readings 1 and 2) - produces this on rocky:10 (dnf 4.20):

    Importing GPG key 0x2AE83D38:
     Userid     : "QMdmm Signing Lab Root <root@qmdmm-lab.invalid>"
     Fingerprint: DB05 E5D9 0271 39A4 93E7 C9DD CD29 0DDA 2AE8 3D38
     From       : /tmp/tmp.dna0XmCUF5/keys/before.gpg
    Error: Failed to download metadata for repo 'qmdmm-rotated': repomd.xml GPG
    signature verification error: Signing key not found

and this on fedora:44 (dnf5 5.4.3.0), for **both** of them:

    Importing OpenPGP key 0x2AE83D38:
     UserID     : "QMdmm Signing Lab Root <root@qmdmm-lab.invalid>"
     Fingerprint: DB05E5D9027139A493E7C9DDCD290DDA2AE83D38
     From       : file:///tmp/tmp.Tcl3Z79Opq/keys/before.gpg
    The key was successfully imported.
    Metadata cache created.

Including `Metadata cache created.` - which is what the revoked-key fixture cell
reads as "accepted" (§10.7.1). So on dnf5 "dnf said nothing about the signature"
is not weak evidence, it is no evidence: the two cases are indistinguishable from
the outside, and a cell that asserts the absence of an error message asserts
nothing at all. `dnf makecache` also exits 0 in both cases (§3.2), so it is not
only the message that fails to carry the answer.

What does carry it is the package listing - six packages from the verifiable
source, none from the unverifiable one - which is why every verdict in this lab is
taken from that and not from the text. The rotation cell now *measures* whether
the log discriminates (bash string comparison, not a tool that may be absent -
§3.16) and prints which of the two situations it is in, per consumer, rather than
assuming either.

### 3.16 A tool that is missing reports exactly like a negative answer

`diff -q a b` exits non-zero when the files differ **and** when there is no `diff`.
fedora:44 does not ship diffutils, so a block written as

    if diff -q "$W/r1.log" "$W/r2.log" >/dev/null 2>&1; then ... else ... fi

took the differ-branch on fedora and made the cell report that dnf *did* name the
refusal in its log - while the two logs were identical, which is §3.15 measured
properly. The claim was wrong, the cell was green, and the only reason anyone saw
it is that the disabled `diff` printed its own complaint on stderr in the middle
of the block:

    /__w/qmdmm-signing-lab/lab/consume-rotated-dnf.sh: line 214: diff: command not found

Two habits. Compare with what the shell has (bash string comparison here;
`grep -F -x -v` for the "what did the second file add" line, since grep is present
wherever grep is), or check for the tool first the way `assert_tls` checks for the
trust store. And do not blanket-suppress stderr around a comparison: the one line
that told the truth was the one the `2>&1` was there to hide.

This is the container-tooling half of §3.13 - there a missing trust store, here a
missing diffutils - and in both the failure surfaced as a plausible reading rather
than as an error. A script that runs in several images can only rely on what all
of them have: the rotated dnf script runs in fedora and in rocky, and `diff` is in
the second one only.

The same shape, one level up, came in with issue #24. `lab/probe-matrix-tags.sh`
asks whether the container tags the release matrix is built on will resolve, and it
asks with `docker manifest inspect`. This machine has no container runtime at all,
so every tag took the not-resolvable branch: nineteen lines of `MISSING` and a
summary that reads as "issue #24 names tags that do not exist" when in fact nothing
had been asked. The registry API is not a way around it either - it is not
reachable from this machine (tried 2026-10-01, after the hub itself was ruled out).

The script now checks for the runtime first and exits 2 saying that no reading was
taken, and it separates "a runtime is present but no registry answers" from "the
tag is missing". The rule the two cases share: a negative answer and an absent
capability must not share a shape. Only one of them is evidence, and a check that
could not run gets believed exactly as readily as one that ran and said no.

### 3.17 `gpg --export <fpr>` is not "the key", it is "the key and everything under it"

`gpg --export` takes the whole key: the primary key **and every subkey**. Only the
trailing bang, `--export <fpr>!`, limits it to the primary key alone. That is the
same bang `--local-user` needs (§4.1's signing side), and on the signing side a
missing one is visible immediately, because a subkey then signs where only the
primary key should have. On the *verifying* side it is invisible: a file that
carries more keys than it should still verifies everything the correct file
verifies, so every positive assertion passes.

This cost a run. The lab's line signing keys are subkeys of the root key, and the
armored root pin was exported without the bang, so it carried all fourteen of
them; two consumer cells then reported "the two-layer split does not hold" for a
file-shaped cause (§10.10). Two rules follow, and they are the general ones rather
than this file's:

- **An exported trust anchor is a claim about a set of keys, so assert the set.**
  `count_subkeys(pin) == 0` is one line and it names the file in the failure. A
  behavioural assertion downstream of it - here, "the root key alone cannot read
  the day-to-day source" - detects the same thing but reports it as a property of
  the scheme, which sends you to the wrong half of the system.
- **An invariant that exists on one of two parallel sides is not an invariant.**
  `consume-dnf.sh` had asserted `subkeys: 0` on the deb-side pin since it was
  first written; the rpm half, written months later by the same hand, did not.
  Where two paths do the same thing in two formats, the assertions have to be
  copied across deliberately - the second writer sees the *shape* of the first
  script and inherits its flow, not its checks.

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
- **Only fedora:43 is affected**, and only because of the dnf5 it ships (§4.2).
  Everything from 44 on behaves exactly as the design wants, so no key or
  layout decision changed.
- EL10 (rpm 4.19 / dnf4) behaves exactly as the design wants too: per-repo
  metadata signing works, and only the key named in `gpgkey=` may sign it.

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

### 4.2 It is a fedora:43 defect, not the new normal

Same probe, four fedora generations, three key shapes each:

| image | rpm | dnf5 | subkey signs | primary signs | no subkey, primary signs |
|---|---|---|---|---|---|
| `fedora:43` | 6.0.2 | **5.2.18** | rejected | rejected | rejected |
| `fedora:44` | 6.0.2 | **5.4.3.0** | accepted | accepted | accepted |
| `fedora:45` | 6.1.0 | 5.4.3.0 | accepted | accepted | accepted |
| `fedora:rawhide` | 6.1.0 | 5.4.3.0 | accepted | accepted | accepted |

fedora:44 carries the **same rpm 6.0.2** as 43 and works, so the component that
moved is **dnf5** (5.2.18 → 5.4.3.0). The defect is in that dnf5 release, and it
is fixed in the next one. It is not a new requirement, and it is not about key
material — which is why nothing about the key design changed.

Consequences, in order of how much they matter:

- **fedora:43 is dropped from this lab**, and the fedora line runs `fedora:44`
  (the tag issue #24 already identifies with `fedora:latest`). With no known
  limitation left, the inverted assertion, its positive-control probe and
  `verify-rpm-dnf.sh`'s escape hatch were all removed rather than left as dead
  code. (That script has since been replaced by `consume-dnf.sh` along with the
  rest of the first generation - see §10.)
- **Issue #24 should not carry a fedora:43 row without a note.** As listed it
  would fail `repo_gpgcheck` on that container. Two honest options: drop 43, or
  keep it and fall back to package-level `gpgcheck` there.
- **And "a 43 user could just update dnf5" is not true**, which was worth checking
  rather than assuming: `probe-fedora43-dnf5-upgrade.sh` refreshes metadata and
  asks the repos directly.

  ```
  dnf --refresh list --upgrades dnf5 librepo   -> No matching packages to list
  dnf upgrade -y dnf5 librepo                  -> Nothing to do.
  after: rpm 6.0.2  dnf5 5.2.18.0              (unchanged)
  ```

  The Fedora 43 repos are reachable (base, updates and openh264 all loaded) and
  offer no newer dnf5, so the three shapes stay rejected. That closes the last
  escape route: Fedora 43 as it exists today cannot verify repomd, not merely
  "the container image is stale".

  **Independently corroborated** by Fedora's own package index
  (`packages.fedoraproject.org/pkgs/dnf5/dnf5/`), which shows the branch each
  release sits on rather than one moment in time:

  ```
  Fedora 43        5.2.18.0-5.fc43        <- still the 5.2 branch
  Fedora 44        5.4.5.0-1.fc44         <- moved to 5.4
  Fedora 45        5.4.5.0-1.fc45
  Fedora rawhide   5.4.6.0-1.fc46
  ```

  So 43 is not "waiting for an update": it stays on 5.2.x, because a released
  Fedora does not rebase its package manager to a new minor series. Waiting
  would not have helped.

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

## 8. The 12-row matrix: what each distro version can actually build

The lab is being moved off its stand-ins and onto the real pipeline: stage A is
the harness's own `ci/pack-<fmt>.sh`, cloned from `QMdmm/QMdmmPackagingCI` at run
time. `lab/lines.tsv` is issue #24 as data - **12 container rows across 7 signing
lines**:

| line | fmt | versions | containers |
|---|---|---|---|
| debian | deb | trixie, forky, sid | `debian:trixie`, `debian:forky`, `debian:sid` |
| ubuntu | deb | resolute, stonking | `ubuntu:resolute`, `ubuntu:stonking` |
| fedora | rpm | 44, 45, rawhide | `fedora:44`, `fedora:45`, `fedora:rawhide` |
| rocky | rpm | 10 | `rockylinux/rockylinux:10` |
| alma | rpm | 10 | `almalinux:10` |
| arch | pac | rolling | `archlinux:base` |
| manjaro | pac | rolling | `manjarolinux/base:latest` |

Before building on that, one question: can each row install the Qt 6 toolchain
stage A needs? Three of the images are *unreleased* distributions, and a
12-row build is an expensive way to find out. `probe-toolchain.sh` reads the
package list **out of the harness's own `pack-<fmt>.sh`** rather than copying it,
so it cannot drift from what stage A will ask for.

**Result: all 12 rows are usable — but one of them needs a repository that
`base-image-rpm.sh` does not enable.** The first pass found 11 of 12 clean; the
one failure was `rockylinux/rockylinux:10`, and it is not "Rocky cannot build
QMdmm":

```
--- 1. as shipped (what stage A gets today) ---
    MISSING  ninja-build
    ok       qt6-qtbase-devel      (6.10.1-1.el10, appstream)
    MISSING  doxygen

--- 2. with CRB + EPEL enabled (EL rows) ---
      enabled crb
      ninja-build   available: 1.11.1-9.el10   (crb)
      doxygen       available: 2:1.13.2-1.el10 (crb)
```

`almalinux:10` satisfies the identical list as shipped, so the two EL rows are
**not interchangeable**, and the difference is not package naming: `ninja-build`
and `doxygen` live in **CRB**, which Rocky's image leaves disabled. (Both came
from CRB here; EPEL is enabled too and reported, but it is not what supplies
either package.)

The probe therefore answers the two questions in order and prints both. Reporting
only the first would have written off a row that works; reporting only the second
would have hidden that **`base-image-rpm.sh` does not enable CRB** - which is the
finding the harness needs, not the lab.

Also worth keeping: on `archlinux:base` the mirrorlist is entirely commented out,
so the refresh step has no server until one is written. The harness's
`base-image-pac.sh` already pins `geo.mirror.pkgbuild.com`, which is why this
only bit the lab's own probes.

## 9. Two axes, not one: package format and the program that reads it

The matrix in issue #24 says **`rpm+dnf`**, and that is not a redundant label - it
names two different things, and the pipeline is split along the same line:

| axis | what it decides | where it lives |
|---|---|---|
| **format** | how a package and its repository metadata are laid out and signed: `deb`, `rpm`, `pacman`, `apk` | stage A (`pack-<fmt>.sh`) and stage S (signed repository) |
| **consumer** | which program reads that repository and what it does when a signature is wrong: `apt`, `dnf`, `zypper`, `pacman`, `apk` | stage B/C (verification) |

Consequences, which is why this is written down before the stages exist:

- **Stage A and stage S are format-level.** `ci/pack-rpm.sh` and a signed
  `repodata/` know nothing about dnf, and the same signed repodata serves any rpm
  consumer.
- **Stage B/C is consumer-level.** `lab/consume-dnf.sh` is named for dnf and
  not for rpm, because that is the half that would differ.
- **A new consumer is a new verification script, not new packaging or signing.**
  `openSUSE` + `zypper` is the case that will exercise this: same rpm format,
  same signed repodata, different reader. `lab/lines.tsv` therefore carries a
  `consumer` column next to `fmt`, so that row is data plus one script.
- **Do not let a consumer's quirk become a format's fact.** The one that has
  already bitten: `dnf makecache` exits **0** even when repomd verification
  fails. That is a dnf behaviour, and it stays labelled as one - a zypper script
  must not inherit it as an assumption.

## 10. The pipeline as it now stands, and what B and C had to be careful about

The stand-in chain is gone. `sign-debian` / `sign-rpm` / `sign-arch` and their
`verify-*` counterparts were the *first* generation: one job per distro line, one
container each, operated on a hand-built site. They are replaced by A → S →
publish → B → C, where the artifact under test is a real package built by the
harness (A), signed once per row at format level (S), published as-is (publish),
and then read by a consumer that holds no secret (B) and whose refusal of
tampering is measured against an untouched control (C).

Three things were worth more than the code they cost.

### 10.1 The control group in stage C is the same object, not a fresh setup

Each C cell first points the consumer at an **untampered** local copy of the
published repository and requires that refresh to succeed, then appends one byte
to a metadata file and requires the *same* refresh to fail. §3.7 is the reason:
a failure in the second half can otherwise be caused by the harness itself - a
mistyped `file://` URL, a key that never got imported - and it still looks like
detection. The control has to be the very object the tampering then modifies.

### 10.2 Revocation is asserted on the status stream, not on the exit code

`stage-b-keyring` checks that the fixture signed by a since-revoked subkey is
*reported* as revoked. Per §3.1 that cannot be done with an exit code, nor by
grepping `Good signature`: `gpg --verify` prints **Good signature** and exits
**0** for a revoked signer. The assertion therefore reads
`--status-fd`, where a revoked signer produces `REVKEYSIG` / `KEYREVOKED`
instead of `GOODSIG`.

That cell also exists so the two claims about the keyring source keep a witness:
that it verifies under the **root key alone**, and that the signer really is the
root key (`GOODSIG`'s key id is compared, not merely "a signature verified" -
a subkey living in the same key file would otherwise satisfy the check).

### 10.3 A hard-coded artifact list silently drops everything after a rename

The publish step used to collect artifacts with

    for d in debian fedora rocky alma arch; do src="artifacts/repo-$d"; ...

which matched the *first* generation's per-line names (`repo-debian`,
`repo-fedora`, …). When stage S moved to per-(line, version) names
(`repo-debian-sid`, `repo-fedora-44`, …), **not one** of them matched: each
iteration hit `[ -d "$src" ] || continue` and the run stayed green while the site
carried none of the signed repositories. A skipped `continue` is invisible; a
green job is not evidence that the thing ran.

The collection now walks `artifacts/repo-*`, splits the name into line and
version, and **fails** if a name cannot be read - so the next rename breaks the
run instead of quietly emptying the site.

Two consequences of the same mistake were fixed with it: `keys/` carried only
the first five lines (no `ubuntu/`, no `manjaro/`), and `site/`'s keyring package
pointed consumers at `<pages>/<line>` rather than `<pages>/<line>/<suite>`.

### 10.4 dnf's `--qf` was never the problem; the missing `\n` was

This section previously predicted that `--qf` would turn out to be a dnf4
spelling and `--queryformat` the dnf5 one. The measurement says otherwise:
`--qf` is accepted by both, and the actual defect was in the format string -
`--qf '%{name}'` has no newline. dnf applies the format string per package, so
every name was concatenated into one long word:

    served: qmdmm-6qmdmm-6-develqmdmm-common-develqmdmm-doc
    built:  qmdmm-6 qmdmm-6-devel qmdmm-common-devel qmdmm-doc

which then failed a comparison against the list stage A built, and reported a
mismatch that pointed at the repository while the repository was fine. The fix
is `--qf '%{name}\n'`. The three-way fallback (`--qf`, `--queryformat`,
`list --available`) is kept anyway: it costs one failed command, and the third
shape is genuinely different rather than a spelling of the other two.

### 10.5 Six runs to green, and not one of the failures was about signing

A and S were 12/12 from the first run, and `publish` assembled a correct site
from the first run. Everything that took six runs was in the consumer half, and
every single one of them was mechanical:

| run | green | what the red cells turned out to be |
|---|---|---|
| 1 | 26/43 | `/etc/os-release` overwriting `VERSION` in 16 cells (§3.10); `gpgv` not installed in the keyring cell (§10.2) |
| 2 | 27/43 | apt verifying as `_apt` and unable to read a 0700 keyring; `--qf '%{name}'` without its newline (§10.4); dnf4 answering "no" to an unanswerable key-import prompt; pacman's keyring having no secret key to sign with |
| 3 | 28/43 | a diagnostic written to stdout being read back as a package name; "the update must fail" as an assertion (§3.11); the same missing secret key in stage C; two containers with curl and no CA bundle (§3.13) |
| 4 | 34/43 | the apt assertion reading the dpkg status file instead of the index (§3.12); dnf returning names space-separated instead of newline-separated |
| 5 | 41/43 | `gpgv` missing again - in the one file not updated when §10.2 was fixed; Manjaro's `curl` broken by a partial upgrade |
| 6 | **43/43** | - |

Two things are worth taking from this. The first is that the failures clustered
by *mechanism*, not by distribution: one cause took out five apt cells, another
took out six dnf cells, and the fix for each was one line in one script.

The second is that the diagnostics are what shortened the loop. The run that
took two hours has a `curl: symbol lookup error: ... ngtcp2_conn_...` in it
after eleven seconds, because the TLS question is asked directly instead of
being inferred from fifteen minutes of "the site never served ...".

### 10.6 What the green cells actually did

Checked rather than assumed, because a job that skips its work is also green:

- every consumer row installed the real runtime package from the published
  repository - `qmdmm-6 0.0.2` on apt, `qmdmm-6-0.0.2-1.x86_64` on rpm,
  `qmdmm-6 0.0.1-1` on pacman - and each compared the served package set against
  the one stage A built;
- every consumer row also refused the same repository when only the root key was
  available, which is the half that makes the per-line subkey mean something;
- all four stage C cells refused the tampered copy, having first accepted the
  untouched one;
- and the keyring cell demonstrated §3.1 in its own log rather than merely
  testing for it:

      gpgv: Good signature from "QMdmm Signing Lab Root <root@qmdmm-lab.invalid>"
      [GNUPG:] REVKEYSIG 77E9E913C4BC3F61 QMdmm Signing Lab Root <root@qmdmm-lab.invalid>
      OK: reported as signed by a revoked key, not accepted as good

  The human-readable line says **Good signature**. The status stream says
  `REVKEYSIG`. An assertion built on the first would have passed.

### 10.7 Revocation, measured: three verifiers, three answers

3.1 said revocation is only as good as the verifier, having noticed that `gpg
--verify` and `sqv` disagree. That was one pair. The same question has now been
put to the three package managers, one artifact per format, with the signing key's
two public states committed (`keys/revoked-fixture-before.gpg`, 602 bytes, and
`keys/revoked-fixture.gpg`, 724 bytes - the difference is the revocation
certificate). The only thing that differs between the two readings is which state
the consumer was handed:

| verifier | format | metadata signed by a revoked key |
|---|---|---|
| `gpgv` (what apt verifies with) | deb | **refused** - `REVKEYSIG` in the status stream (§10.2) |
| `dnf` 5.4.3.0 on fedora:44 | rpm | **ACCEPTED** |
| `pacman` on archlinux:base | pac | **refused** - `signature from … is invalid`, `invalid or corrupted database (PGP signature)` |

**What this means for a release.** Revoking a signing key is the standard answer
to a key being compromised. On the rpm line it does not do what it is expected to
do: dnf imports the key, never consults the revocation certificate, and accepts
the repository - its output on the revoked key is character-for-character what it
produces on the valid one. So the stop-gap for an rpm line has to be "rotate the
key and move consumers to it", not "revoke and let consumers notice". apt and
pacman do refuse, so for those two the ordinary story holds.

That dnf verifies signatures at all is not in doubt, and this lab shows it: the
twelve rpm consumer rows refuse a repository whose `gpgkey=` names only the root
key, with `repomd.xml GPG signature verification error`. It checks signatures; it
does not check revocation.

`pacman-key --lsign-key` deserves its own line: it **accepted** locally signing
the revoked key, without complaint. The refusal comes later, at the database. So
for pacman too, the trust-granting step is not where revocation is noticed.

### 10.7.1 The rpm half was green for the wrong reason first

Recorded because it is §3.12's family and would otherwise have been invisible.

The first version of the dnf cell asserted "dnf can no longer list a package from
this repository". The rpm fixture is an **empty** repository - deliberately, so
that "the metadata verified" stays separable from "packages install" - and that
assertion is true of an empty repository whether or not the signature was ever
accepted. Revocation could have been doing nothing at all and the cell would have
been green, which is what happened: it passed on the same run as the working
pacman cell, and read as confirmation. Asking the narrower question - did dnf say
anything about the signature - turned it red on the next run and produced the
table above. An empty fixture needs an assertion about the *mechanism*, because
the packages are absent by construction.

**That fix was half a fix, and §3.15 is where it shows.** On dnf5 *neither* half
of the cell says anything about the signature - not on the accepted fixture, not
on the revoked one, not even on a repository the consumer cannot verify at all
(§10.9 readings 1 and 2 print the same six lines) - so the narrower question has
the same answer whichever way it goes, and on fedora:44, the consumer this cell
runs on, it discriminates nothing. The rpm row of the table above therefore rests
on §10.9, where the same question is put to a repository that can be *listed*:
six packages under the valid key, none under the revoked one, on both dnf
generations. The fixture cell is left as it is, with this note saying so: an empty
fixture can support a mechanism-shaped assertion only if the consumer under test
has mechanism-shaped output, and this one has none. The fix is a marker package
inside the fixture, so that "the metadata verified" becomes visible in a listing -
which is exactly how §10.9's readings 1 and 2 are told apart, on a repository that
has something to list.

### 10.8 What this lab does **not** cover

Written down because an unverified thing that is not labelled as unverified tends
to be read as a verified one. The first two entries are **scope decisions rather
than gaps** - they are listed so that their absence is not read as an oversight.

- **The dev package's dependency closure is not tested here.** That is
  QMdmmPackagingCi's C, and it stays there. What the consumer cells here answer is
  a question about the *trust path* - install the keyring, establish trust,
  install a signed package - not a question about package content. They still
  assert the dev and doc packages are *served* (`served == built`); they just do
  not install them, because that answer already exists in that repository's C.

- **This repository signs after packing, where the pipeline signs after C.** That
  repo's B and C do not run here, so the workflow reads `A → S → publish → B` -
  those two stages are **absent, not reordered**. The pipeline the two
  repositories form *together* is `CI.A → CI.B → CI.C → S → B consume`, and **S
  must not run until that repo's B and C have passed**: a signature asserts that
  what it covers is worth trusting, and appending it to packages nobody has
  installed yet guarantees the release is interrupted *after* the signature is
  already public. See README, "S belongs after C, not after A".

- **Rotation has been rehearsed on four of the seven lines, and the procedure is
  no longer debian-only.** This entry replaces one that said the operation had
  only ever been run on debian and that six lines' key files carried no revoked
  subkey as a result. Both are now false: `rotate-line-local.sh` takes any line in
  `lab/lines.tsv`, and it has been run for real on fedora, rocky and arch (§10.9),
  where the old script's `case` accepted `debian` and nothing else. What is still
  not covered is ubuntu, alma and manjaro - not on the argument that their
  procedure differs (procedures are format-level and all three formats have now
  been run), but on the argument about *consumer behaviour* below, which has to
  hold or the three rotations were a formality.

- **Three of the seven lines have never been rotated, and their key files reflect
  that.** ubuntu, alma and manjaro ship root plus one live subkey; debian, fedora,
  rocky and arch each carry their outgoing subkey with its revocation certificate
  (§3.14 lists them). The intent of carrying it is that a consumer which has
  refreshed is told "revoked" rather than "unknown key", and that intent holds for
  two of the three verifiers: pacman prints `signature from … is invalid` for the
  revoked signer and `key … is unknown` for one it does not have (§10.9), and apt
  goes through `gpgv`, which honours the certificate. dnf does neither - it does
  not consult the certificate and does not say "revoked" (§10.7), so on rpm
  carrying the subkey buys the diagnosis nothing and costs the revocation, which
  is §10.9's conclusion.

- **The deb and rpm formats have a keyring/trust-artefact mechanism; pacman does
  not, and on pacman that is an answer rather than a gap.** `site/debian-keyring`
  serves `qmdmm-archive-keyring` and `site/<line>-keyring` serves the rpm
  `*-release` package, each from a source only the root key signs, so each gives
  a consumer holding nothing but a fingerprint a way in (README, "Running it").
  Both are now measured: the deb half since `stage-b-keyring-package-deb` existed,
  the rpm half in §10.10. On pacman no such package can be protected by repository
  configuration at all - trust is one global keyring and the repo stanza does not
  scope it (§6) - so the key has to be distributed out of band and checked by
  fingerprint. That is a documentation problem, not a package waiting to be
  written.

- **`stage-c-taint` covers four (format, consumer) pairs, not twelve rows**, on
  purpose: tamper detection is a property of the format and the refusal is a
  property of the verifying program, so twelve versions would repeat the same
  four mechanisms. The assumption that costs something is "one verifier per
  family" - and fedora:43, where the same dnf5 at a different patch level
  behaved differently, is a counter-example to exactly that assumption. Cells
  here are cheap (metadata only, no package installation), so filling in the
  other eight rows is a reasonable thing to want.

### 10.9 Rotation, measured: what it costs a consumer, and which key file to publish

§10.7 answered "does this consumer consult a revocation certificate", with a key
that exists only to be revoked. An incident asks something else. A line's subkey is
compromised, its subkey is replaced, and what happens to everybody holding the old
key material? That had never been measured, for the plain reason that rotation had
only ever been performed on debian (§10.8) and no cell existed for it.

`lab/rotate-line-local.sh` now rotates any line in `lab/lines.tsv` - the script it
replaces accepted `debian` and nothing else, so "rotate fedora's subkey" was a
process nobody had walked through, whatever the consumer-side behaviour turned out
to be. It has now been run for real, off CI, four lines:

| line | outgoing, now revoked | incoming | times rotated |
|---|---|---|---|
| debian | `…77E9E913C4BC3F61` | `…3F4622CC95CDBFB4` | 2 (§3.14) |
| fedora | `0CB6055F…8399B375` | `D3032A80…4DCC4024` | 1 |
| rocky | `D7434719…8E830643` | `32654163…0C797AA3` | 1 |
| arch | `1D569E0B…09159052` | `56EF6767…31240F4E` | 1 |

Each rotation leaves three artifacts a consumer could be handed, and one source
that stops existing the moment the line publishes again:

- `keys/<line>/qmdmm-packages-before.gpg` - the key file as it was, root +
  outgoing, no revocation certificate in it: what a consumer that has NOT
  refreshed holds. It has to be exported *before* the revocation, which is why the
  rotation script insists on the order;
- `keys/<line>/qmdmm-packages.gpg` - the key file as it is now: root +
  outgoing[revoked] + incoming;
- `keys/<line>/qmdmm-packages-pruned.gpg` - the same file with the outgoing subkey
  dropped: root + incoming only. This is the one this section had to add, and the
  reason is below;
- `site/<line>-revoked/` - the source the line published immediately before the
  rotation (metadata only), signed by the outgoing subkey.

That makes a 2x2, and `lab/consume-rotated-{dnf,pacman}.sh` walk all four cells of
it, once per (format, verifier implementation) the way stage C does: dnf5 5.4.3.0
on fedora:44, dnf4 4.20 on rocky:10, pacman on archlinux:base. A verdict is "can
the consumer list a package from this repository" - never the exit code (§3.2) and
never the log (§3.15).

|  | key material NOT refreshed | key material refreshed |
|---|---|---|
| **frozen source** (signed by the outgoing subkey) | **accepted** - the control | rpm **accepted** / pacman **refused** |
| **rebuilt source** (signed by the incoming subkey) | **refused** | **accepted** |

Both rpm cells gave identical answers, so this is not a dnf-generation difference.
The two refusals are diagnosed differently, which matters for the second table
below:

    dnf4,  rebuilt source, un-refreshed key file:
      Error: Failed to download metadata for repo 'qmdmm-rotated': repomd.xml GPG signature verification error: Signing key not found

    dnf5,  the same reading, says nothing at all (FINDINGS 3.15)

    pacman, rebuilt source, un-refreshed keyring:
      error: lab: key "56EF6767681BE8778834C5144B8A46BD31240F4E" is unknown

    pacman, frozen source, refreshed keyring (this is the one that differs):
      error: lab: signature from "QMdmm Signing Lab Root <root@qmdmm-lab.invalid>"
      is invalid

**Corner 2 is the cost, and nobody had priced it.** A consumer that has not
refreshed its key material cannot read the *new* source at all - not "sees a
warning", not "installs without verification": the repository is gone. So "rotate
the key and let consumers notice" is not a plan. The new key file and the new
signature have to ship at the same time and be announced as a pair, or every
consumer that does not update is broken the moment the rotation is published.

**Corner 3 is the leak window, and on rpm it is open.** A consumer that *has*
refreshed - and therefore holds the revocation certificate, which the cells assert
rather than assume, by checking the keyring's validity field for the outgoing
subkey - is handed the old source and accepts it. That is not a bookkeeping fact:
it means a compromised subkey can keep signing package metadata, from a mirror or
a copy of the old repository, and every refreshed rpm consumer accepts it, because
dnf does not consult the certificate (§10.7). pacman refuses the same artifact
with `signature … is invalid`, and so does apt's `gpgv` with `REVKEYSIG` (§10.2).
On rpm, the revocation accomplishes nothing; only removing the key does.

**And that is what the extra key file is for.** Corner 3 and corner 2 together
imply that on rpm it is the *presence* of the revoked subkey in the key file that
keeps it able to sign - which is an inference, and the recommendation it supports
is about an artifact people are handed, so the cells measure it instead. Readings
5 and 6 run the same two sources against the pruned key file:

| reading | key file | source | verdict |
|---|---|---|---|
| 5 | pruned (no outgoing subkey) | frozen | **refused** - the window closes |
| 6 | pruned | rebuilt | **accepted** - and closing it costs nothing |

Both rpm cells: refused then accepted. So the two files are not equivalent, and
which of them a rotated line publishes is a decision with a measurement behind it:

- **rpm: publish the pruned file.** The courtesy of carrying the outgoing subkey
  buys literally nothing here - dnf never prints "revoked" (§10.7), and the change
  it makes to what a *refreshed* consumer accepts is exactly the leak. Dropping it
  costs the consumer nothing (reading 6) and closes the window (reading 5).
- **debian: keep carrying it.** `gpgv` honours the certificate, so "revoked" is a
  diagnosis the consumer can act on rather than an unknown key; that trade - a key
  whose revocation is enforced but which a consumer is told about - is only
  available because the verifier does the work.
- **pacman: either, and now for a stated reason.** Both refusals refuse, and the
  messages differ - `key … is unknown` for a key it does not have, `signature … is
  invalid` for one it will not use - so carrying the subkey turns "I have never
  seen this signer" into "this signer is revoked". That is a real difference and it
  is a diagnostic one. The pruned counterpart is not measured for pacman, and the
  cell's header says why rather than leaving it to be read as an oversight: trust
  here is one global keyring that cannot be un-taught a revocation certificate
  (§6), so the counterfactual needs a second keyring - a consumer that never
  existed in this sequence - and the causal question it would answer (does
  removal change anything) is already closed, because corner 3 is refused *and*
  the script asserts the certificate arrived.

**One published artifact was silently stale, and the rotation is what made it
stale.** `keys/fingerprints.txt` names each line's current subkey and the publish
job pastes it onto the front page of the site. After the three rotations it still
named the outgoing ones for fedora, rocky and arch, so the site went on
advertising the keys that had just been revoked as those lines' operational keys,
with the current ones sitting in the key files next to them. Nothing looked, so
nothing caught it - the file is hand-maintained and no cell had ever compared it
with the keys it describes. Now `lab/check-fingerprints.sh` does, from the publish
job, and `rotate-line-local.sh` rewrites the row it rotates. The gate was checked
both ways: red on the three stale rows before they were rewritten, green after,
and red again on a single flipped hex digit. The corrected list is live on the
site - verified over Pages, not from the working tree.

Two runs went green around this, 51/51 each: `36442600908` at `a1d3506` (the
readings above) and `36444142798` at `0de8e3c`. Both found a defect that was not a
rotation: §3.15 (dnf5 refuses in silence, so the log-based assertion in the older
fixture cell discriminates nothing on the consumer it runs on) and §3.16 (the
comparison that was supposed to catch that used a tool fedora does not ship, and
reported the missing tool as a difference).

**Still not covered.** The deb lines have no rotated cell: debian *has* been
rotated twice, so one could be written, and the reason it has not is that the only
cell where the verifiers differ is corner 3, and for apt that one is already
§10.7's `gpgv` row. ubuntu, alma and manjaro have not been rotated, on the
argument - about consumer behaviour, not procedure - that each shares a verifier
with a line that has. And the lab itself keeps publishing the *carrying* key file
for fedora, rocky and arch, because that is the artifact the cells measure; which
one the project hands to users is now a decision with a reading behind it, and
changing the published file is a separate step from being able to say why.

### 10.10 The rpm trust bootstrap, measured - and the pin it first shipped was the wrong export

Two cells, one per live dnf generation (`fedora:44`, dnf5 5.4.3.0; `rockylinux/
rockylinux:10`, dnf4 on rpm 4.19.1.1), each starting from nothing but a key
fingerprint read off the website. The mechanism is `mkkeyring-rpm.sh` off-CI and
`consume-dnf-keyring-package.sh` in stage B; the shape is §5's two layers plus
the bootstrap argument in §10.8.

Four readings. The first run of it, `36836722274`, failed on the third, on both
cells, in the same words.

**0 - the keyring source is signed by the ROOT key, read off the published
bytes.** `GOODSIG CD290DDA2AE83D38` on both cells, over the exact `repomd.xml`
fetched from Pages, checked through the status stream rather than the exit code -
the discipline §10.2 and §3.1 ask for, because `gpg --verify` calls a signature
good whatever key made it. dnf is not consulted for this one on purpose: stage A
of the chain is a claim about a signature, and dnf's agreement is reading A.

**A - holding only the root key, the root-signed source is readable and offers
exactly one package** (`qmdmm-release-fedora-44`, `qmdmm-release-rocky-10`), from
a stanza the consumer writes by hand:

    [qmdmm-bootstrap]
    baseurl=<pages>/<line>-keyring
    gpgcheck=0          # the bootstrap package itself is not signed
    repo_gpgcheck=1     # the protection is the root-signed repomd.xml
    gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-qmdmm-root

**A' - the same root key against the DAY-TO-DAY source must serve nothing.** This
is where `36836722274` went red, listing `qmdmm-6 qmdmm-6-devel qmdmm-common-devel
qmdmm-doc` on both fedora 44 and rocky 10. It was not dnf and not a signature.

The line signing keys are **subkeys of the root key** — not separate keys that the
root key has signed. `keys/qmdmm-root.gpg` is the primary key alone (279 bytes,
`subkeys: 0`), and the mounted root of the failure was that `mkkeyring-rpm.sh`
produced the armored companion with

    gpg --armor --export "$ROOT"          # no trailing bang

so `keys/qmdmm-root.asc` was 7737 bytes carrying the primary key **and all
fourteen of the lab's line subkeys**. A consumer handed that file can verify any
line's day-to-day source, which makes the two-layer split true on the signing side
and absent on the verifying side — and **step A cannot see it**, because the
keyring source is signed by the primary key and the primary key is in both
versions of the file. Reading 2 was green before the fix and green after it.

The assertion that was missing is the one `consume-dnf.sh` has made about the
deb-side pin since it was written:

    [ "$nsub" = 0 ] || ... the root key file carries subkeys; it must carry none

The rpm half never got it, and the cost was a scheme-shaped failure
("the split does not hold") for what was a wrong file. Both halves now assert it,
and `mkkeyring-rpm.sh` asserts three things about the pin it writes: the root
fingerprint, `subkeys: 0`, and that the armored file **dearmors to exactly
`keys/qmdmm-root.gpg`** — two published encodings of one pin, never two pins. The
regenerated file is 457 bytes and satisfies all three. `4338ff7`, and the same
run that carries it is 53/53.

**A' after the fix, and the two generations do not agree on how to say it.** On
rocky 10 (dnf4) the refusal is loud, once per way of listing the repository:

    Error: Failed to download metadata for repo 'qmdmm-neg':
      repomd.xml GPG signature verification error: Signing key not found

On fedora 44 (dnf5) there is **no message at all** - the cell prints nothing under
the heading, and the only reading that separates "refused" from "never asked" is
that all three listing paths returned an empty set. This is §3.15 arriving in a
new place: the negative half of the bootstrap has mechanism-shaped output on one
generation and none on the other, so an assertion written as "dnf said something
about the signature" would be green on rocky and would discriminate nothing on
fedora. The assertion is on the package list for that reason.

**B and C - the package is what configures the repository.** Installing
`qmdmm-release-<line>-<ver>` puts `/etc/yum.repos.d/qmdmm.repo` (mode 644) and
`/etc/pki/rpm-gpg/RPM-GPG-KEY-qmdmm-<line>` (896 bytes) on disk; the key file it
ships is the line's **current** subkey (`EC773BB34DCC4024` fedora,
`5D6DC95D0C797AA3` rocky) with **0 unusable subkeys**, i.e. the pruned file, which
is §10.9's answer for this format. Then the hand-made stanza is deleted: only
`qmdmm.repo` is left, and on nothing but the package's own configuration the
day-to-day source serves the same four packages and installs `qmdmm-6-0.0.2-1`.
That last step is the acceptance criterion (§10.8's bullet, and the README's
"Running it"): a `*-release` package that installs but configures nothing looks
exactly like a working one until this point.

**What this does not cover.** The bootstrap package is not signed and is not meant
to be - what protects it is the signed checksum in the metadata it is served
through, which is why the stanza is `gpgcheck=0` with `repo_gpgcheck=1` and not
the other way round. And the cells fetch the site over the public Pages URL, so
they do cover the network path the deb keyring cell covers; what they do not cover
is a *real* user's first contact, which is a download page and a fingerprint
comparison that no runner can make on the user's behalf.

## 11. The Alpine line's own key

Alpine is the one line the GPG genesis above does not cover, and for a structural
reason rather than an omission: `abuild-keygen` and `abuild-sign` are shell
around OpenSSL (`openssl dgst -sha1 -sign`), and apk resolves a package's
signature by looking for a file named exactly after the signature member
`.SIGN.RSA.<basename>` in `/etc/apk/keys`. There is no subkey to delegate to and
no root/operational pair to build, so the key-granularity design that applies to
deb and rpm does not apply here at all. But neither is the line optional: abuild
signs every package and the repository index unconditionally, and dies without a
key, so a key is not something this line can choose to do without.

There is also **no revocation**, and that is what makes the file name the key's
whole identity - it is the name in every consumer's `/etc/apk/keys` and the
member name inside every package, so a rotation can only be a new name plus
asking every consumer to delete the old file by hand. Which is why the name is
chosen before the first release rather than inherited from whatever tool happened
to generate it.

The production key is `qmdmm-release-6abe0b34` - 4096-bit RSA, PKCS#8 private
half, SPKI public half, 800 bytes, the same shape as the one it replaces - and it
was generated by `lab/genesis-alpine-key.sh`, whose pattern is abuild-keygen's own
`<identity>-<hex>` with the project where that script uses the invoking user. It
replaces one that had inherited `neve-` from the 2026-09-16 local verification: a
default that then shipped as though it had been chosen.

What the generating tool can prove stops at the OpenSSL layer, because this
machine has neither `abuild` nor `apk-tools`. The readings it does give are that
the two halves are one pair - using stage A's own `openssl pkey ... | cmp -` call,
so a mismatch fails in seconds rather than after a build - and that a signed
message verifies while a tampered copy of the same message does not. The Alpine
row of the packaging run is what covers the rest.

### 11.1 The reading that covers the rest

The packaging run at `960b4ba7` closed it: the Alpine row went green end to end,
and three things in it are the ones this machine could reach.

Stage A writes the secret to `~builder/.abuild/qmdmm-release-6abe0b34.rsa` and
compares it against the committed public half with stage A's own
`openssl pkey -in "$priv" -pubout -outform DER | cmp - <(openssl pkey -pubin -in
"$pub" -outform DER)`. **This is the first time the value of a GitHub secret has
been checked against what the repository says the key is.** The API cannot read
a secret back, so until a runner does this, "the secret is set" is a claim about
a keystroke rather than about bytes - and it is the same gap the seven GPG lines
still have. It passed.

Stage A then asserts, for each of the four packages and for the index, that the
member list contains `.SIGN.RSA.qmdmm-release-6abe0b34.rsa.pub`: the expected
name derived from `$PACKAGER_KEY`, matched exactly (`grep -qxF`) against what
`abuild-sign` actually wrote.

Stage C runs in a container that declares no environment and therefore holds no
secret at all. It installs the committed public half into `/etc/apk/keys/`,
`apk update` succeeds, `apk add qmdmm-dev` resolves and installs, and the
consumer project builds against it. That is the name-as-identity claim measured
rather than argued: one string has to be in the signature member, in the
consumer's trust directory, and in `PACKAGER_KEY`, and the line only works when
all three agree.

Two things this reading does **not** cover. The packages came from the run's own
artifact (`file://$PWD/pkgs`), not from a published site, so it says nothing
about a consumer fetching them over the network. And it says nothing about the
seven GPG lines: their secrets remain unread in the sense above, and only
`release.yml` signing with them can close that.
