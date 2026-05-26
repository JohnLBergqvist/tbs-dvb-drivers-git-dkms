# tbs-dvb-drivers-git-dkms

DKMS package for TBS DVB drivers tracking
[`tbsdtv/linux_media`](https://github.com/tbsdtv/linux_media) upstream.

## What this is

Out-of-tree TBS DVB driver modules, packaged for DKMS so they survive
kernel upgrades. Targets `tbsdtv/linux_media` `latest` as upstream and
ships only the bits TBS adds on top of the mainline Linux kernel.

The current snapshot is recorded in `UPSTREAM_VERSION` (commit SHA,
date, subject).

## Repo layout

```
sync-upstream.sh    # Pulls TBS-added driver source from upstream into src/
Makefile            # Top-level wrapper: applies patches/, then builds modules
dkms.conf           # DKMS config; module list auto-regenerated from src/Kbuild
UPSTREAM_VERSION    # Records which tbsdtv/linux_media commit src/ came from
src/                # TBS driver source — pristine copies from upstream
  frontend_extra.h  # Hand-written compat header (DVB-S2X enum values, TBS ioctls)
  Kbuild            # Auto-generated module list
  drivers/media/... # Mirrors upstream layout (dvb-frontends/, tuners/, pci/...)
patches/            # Out-of-tree compatibility patches
.gitattributes      # Preserve upstream line endings on src/
LICENSE             # GPL-2.0
```

## Building

```
make                  # apply patches, build modules
make clean            # revert patches, clean build artifacts
make modules_install  # install built .ko files (usually called by DKMS)
```

`make` looks for kernel headers at `/lib/modules/$(uname -r)/build`;
override with `make KERNELDIR=/path/to/kernel-headers`.

## Modules built

Currently 26 modules covering TBS-added drivers:

- **Bridge drivers**: `tbsecp3` (ECP3 PCI bridge), `saa716x_*` (legacy bridge for non-ECP3 cards)
- **Demodulators**: `tas2101`, `tas2971`, `m88rs6060`, `mxl58x`, `si2183`, `mn88436`, `mtv23x`, `gx1133`, `gx1503`, `cxd2878`, `stv091x`, `stid135`, `isl6422`, `avl6882`, `tbs_priv`
- **Tuners**: `av201x`, `mxl603`, `rda5816`, `r850`, `r848`, `stv6120`, `tda18273`
- **Misc**: `tbs_pcie-ci` (CAM), `tbs_pcie-mod` (modulator)

The list is regenerated from `src/Kbuild` on each upstream sync.

## Syncing from upstream

```
./sync-upstream.sh           # use upstream's "latest" branch
./sync-upstream.sh <ref>     # use a specific tag or commit SHA
```

The script auto-detects which mainline kernel TBS forked from (by
matching their Makefile's VERSION/PATCHLEVEL/SUBLEVEL/EXTRAVERSION
against ancestors), then `git diff`'s vanilla → TBS to discover which
files to sync. Regenerates `src/Kbuild` and the module-list section of
`dkms.conf`. Stages for review; never commits.

## Supported kernels

Speculatively `^[67]\.` — primary deploy target is `linux-lts` (6.18+).
Set in `dkms.conf` via `BUILD_EXCLUSIVE_KERNEL_VERSION`; tighten the
regex to fail-fast on unsupported kernels.

## License

GPL-2.0. See `LICENSE`.
