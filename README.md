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
patches/            # Out-of-tree compatibility patches (applied at build time)
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

Currently 38 modules covering:

- **Bridge drivers**: `tbsecp3` (ECP3 PCI bridge), `saa716x_*` (legacy bridge for non-ECP3 cards)
- **Demodulators**: `tas2101`, `tas2971`, `m88rs6060`, `mxl58x`, `si2168`, `si2183`, `mn88436`, `mtv23x`, `gx1133`, `gx1503`, `cxd2878`, `stv091x`, `stid135`, `cx24117`, `mb86a16`, `stv090x`, `stb6100`, `tda1004x`, `zl10353`, `isl6422/3`, `avl6882`, `tbs_priv`
- **Tuners**: `av201x`, `mxl603`, `rda5816`, `r850`, `r848`, `si2157`, `stv6120`, `tda18212`, `tda18273`
- **Misc**: `tbs_pcie-ci` (CAM), `tbs_pcie-mod` (modulator)

The list is regenerated from `src/Kbuild` on each upstream sync.

## TBS-modified mainline drivers

For some drivers (`cx24117`, `tda18212`, `stv090x`, `mb86a16`, `stb6100`,
`isl6422/3`, `stv6110x`, `si2168`, `si2157`, `tda1004x`, `zl10353`,
`cxd2820r`), TBS extended the mainline driver with extra struct fields
that their bridge drivers depend on. We ship TBS-modified versions of
these as full modules; DKMS installs them to `/extra/dkms/`, overriding
the kernel's vanilla copies at module-load time.

## Patches

The `patches/` directory contains the minimum-viable set of changes
needed to compile TBS source against current mainline kernels. They
are applied by the top-level `Makefile` (not via DKMS's PATCH[i]),
because `patch -p1` needs to run from inside `src/`.

Current patches:

- `0001-strip-tbs-dvb-core-extensions.patch` — comment out
  TBS-only `dvb_frontend_ops` callbacks (`.spi_read`, `.eeprom_read`,
  `.set_property`, etc.) and stub the corresponding implementations.
- `0002-stub-out-DTV_MODCODE-usage.patch` — gate `c->modcode` /
  `MODCODE_ALL` references on `#ifdef DTV_MODCODE` (TBS-only enum).
- `0003-rename-apsk-enum-references.patch` — `APSK_8L` → `APSK_8_L`
  etc., matching mainline enum names.
- `0004-remove-unused-dvb_math-include.patch` — drop unused
  `<media/dvb_math.h>` include from `m88rs6060.c`.
- `0005-stub-out-audio-get-pts.patch` — wrap removed `AUDIO_GET_PTS`
  ioctl case in `#ifdef`.
- `0006-port-saa716x-ir-to-timer-setup.patch` — port saa716x_ff IR
  driver from pre-4.14 timer API to `timer_setup()`.

### Adding a new patch

1. `make patch` to apply existing patches
2. Edit files in `src/`
3. `cd src && git diff <file> > ../patches/00NN-description.patch`
4. Edit the patch file: add a `Subject:` and explanation in the header
5. `make clean` to revert
6. Verify the new patch applies cleanly: `make patch && make clean`

### Refreshing a patch after upstream sync

If `sync-upstream.sh` reports a patch no longer applies:

1. `cd src && patch -p1 --merge < ../patches/00NN-name.patch`
2. Resolve any conflict markers in affected files
3. `git diff <files> > ../patches/00NN-name.patch` (regenerate)
4. `git checkout <files>` to restore pristine
5. Commit the new patch file

## Syncing from upstream

```
./sync-upstream.sh           # use upstream's "latest" branch
./sync-upstream.sh <ref>     # use a specific tag or commit SHA
```

The script auto-detects which mainline kernel TBS forked from (by
matching their Makefile's VERSION/PATCHLEVEL/SUBLEVEL/EXTRAVERSION
against ancestors), then `git diff`'s vanilla → TBS to discover which
files to sync. Regenerates `src/Kbuild` and the module-list section of
`dkms.conf`. Dry-runs `patches/*.patch` and reports any that no longer
apply. Stages for review; never commits.

## Supported kernels

`^[67]\.` — verified on 6.x and 7.x. Set in `dkms.conf` via
`BUILD_EXCLUSIVE_KERNEL_VERSION`; tighten the regex to fail-fast on
unsupported kernels.

## License

GPL-2.0. See `LICENSE`. Driver source files retain their individual
upstream copyrights and licenses.
