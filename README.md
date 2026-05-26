# tbs-dvb-drivers-git-dkms

DKMS package for TBS DVB drivers tracking
[`tbsdtv/linux_media`](https://github.com/tbsdtv/linux_media) upstream.

## What this is

Out-of-tree TBS DVB driver modules, packaged for DKMS so they survive
kernel upgrades. Targets `tbsdtv/linux_media` `latest` as upstream and
ships only the bits TBS adds on top of the mainline Linux kernel.

## Repo layout

```
sync-upstream.sh   # Pulls TBS-added driver source from upstream into src/
src/               # Driver source (populated by sync-upstream.sh)
patches/           # Out-of-tree compatibility patches (empty until populated)
LICENSE            # GPL-2.0
```

## Syncing from upstream

```
./sync-upstream.sh           # use upstream's "latest" branch
./sync-upstream.sh <ref>     # use a specific tag or commit SHA
```

The script auto-detects which mainline kernel TBS forked from (by
matching their Makefile's VERSION/PATCHLEVEL/SUBLEVEL/EXTRAVERSION
against ancestors), then `git diff`'s vanilla → TBS to discover which
files to sync. Adds `src/Kbuild` (auto-generated) listing the modules
to build. Stages the result for review; never commits.

## License

GPL-2.0. See `LICENSE`.
