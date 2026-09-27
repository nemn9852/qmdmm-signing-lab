#!/usr/bin/env bash
#
# Small helpers shared by the scripts that run on a trusted machine.
#
# The rule these follow: use the tool a real Linux build box would use, and only
# fall back to a Mac-flavoured equivalent when that tool genuinely is not there.
# This lab gets driven from a Mac, but the pipeline that adopts it will not be,
# so nothing Mac-specific should end up on the critical path.

md5_of() {
  if command -v md5sum >/dev/null 2>&1; then md5sum "$1" | cut -d' ' -f1
  else md5 -q "$1"; fi
}

sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# Print the control file of a .deb, fields in file order (no Filename/Size -
# those are the repository's business, not the package's).
deb_control() {
  if command -v dpkg-deb >/dev/null 2>&1; then
    dpkg-deb -f "$1"
  else
    # macOS has no dpkg-deb, and its ar is a Mach-O archiver that cannot read
    # these archives, so parse the ar container directly.
    python3 - "$1" <<'PY'
import sys, io, tarfile
d = open(sys.argv[1], "rb").read()
if d[:8] != b"!<arch>\n":
    sys.exit(0)
i = 8
while i + 60 <= len(d):
    hdr = d[i:i+60]
    name = hdr[0:16].decode(errors="replace").strip()
    size = int(hdr[48:58].decode().strip() or 0)
    body = d[i+60:i+60+size]
    if name.startswith("control.tar"):
        with tarfile.open(fileobj=io.BytesIO(body)) as tf:
            for m in tf.getmembers():
                if m.name.lstrip("./") == "control":
                    sys.stdout.write(tf.extractfile(m).read().decode())
        break
    i += 60 + size + (size % 2)
PY
  fi
}
