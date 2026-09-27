#!/usr/bin/env bash
#
# Small helpers shared by the scripts that run on a trusted machine.
#
# These take the tools a Linux box has - GNU coreutils, dpkg-deb - and nothing
# else. That is deliberate. These scripts are meant to move into the real
# pipeline, and a fallback branch written to accommodate the machine you happen
# to be developing on is how you end up shipping something that only works
# there. If the machine driving the lab lacks these tools, install them; do not
# branch around them.

md5_of() { md5sum    "$1" | cut -d' ' -f1; }
sha_of() { sha256sum "$1" | cut -d' ' -f1; }

# The control file of a .deb, in file order (no Filename/Size - those belong to
# the repository index, not to the package).
deb_control() { dpkg-deb -f "$1"; }
