#!/bin/sh
# DKMS POST_INSTALL hook: put back in-tree modules that dkms archived.
#
# When a DKMS module shares its name with an in-tree one (cx24117, si2168,
# si2157, tda18212, ...), dkms >= 3 *moves* the distro's .ko out of
# /lib/modules/<kver>/kernel/ into
# /var/lib/dkms/<module>/original_module/<kver>/<arch>/, writing a
# <name>.ko.origin file with the original path. That leaves the kernel
# package's files missing (dpkg --verify fails) on every install and
# every kernel upgrade (AUTOINSTALL=yes).
#
# This hook copies (not moves) each archived module back. The DKMS builds in
# updates/dkms still win in depmod's search order, so behaviour is unchanged.
# The archive is left in place so `dkms uninstall` keeps working: it moves
# the identical archived file back over ours and deletes the .origin.
#
# Usage (from dkms.conf): restore-original-modules.sh <kernelver> <arch>

set -u
kver=${1:?kernelver}
arch=${2:?arch}
module=tbs-dvb-drivers-git-dkms
archive=/var/lib/dkms/$module/original_module/$kver/$arch
kdir=/lib/modules/$kver/kernel/

[ -d "$archive" ] || exit 0

find "$archive" -type f -name '*.origin' | while IFS= read -r origin; do
    saved=${origin%.origin}
    dest=$(head -n 1 "$origin")
    [ -f "$saved" ] || continue
    case "$dest" in
        "$kdir"*) ;;
        *) echo "restore-original-modules: skipping unexpected path $dest" >&2
           continue ;;
    esac
    if [ -e "$dest" ]; then
        continue
    fi
    mkdir -p "${dest%/*}"
    cp -p "$saved" "$dest" && echo "Restored in-tree module $dest"
done
exit 0
