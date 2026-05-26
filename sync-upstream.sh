#!/bin/bash
# sync-upstream.sh — sync src/ to a snapshot of tbsdtv/linux_media
#
# Usage: ./sync-upstream.sh [REF]
#   REF defaults to "latest" (upstream's active development branch).
#   You can also pass a specific commit SHA or tag.
#
# How it works:
#   1. Maintain a local cache clone of tbsdtv/linux_media in
#      ~/.cache/tbs-dvb-drivers-git-dkms/linux_media. Includes full vanilla Linux history.
#   2. Auto-detect vanilla Linux base by reading VERSION/PATCHLEVEL/SUBLEVEL/
#      EXTRAVERSION from upstream's Makefile, then look up Linus's matching
#      release commit (e.g. "Linux 6.5-rc1") in the same git history.
#   3. Run `git diff --diff-filter=A` between vanilla and TBS's requested ref,
#      narrowed to DVB-relevant subtrees. The set of TBS-ADDED files IS the
#      file list we sync — no manual curation needed.
#   4. Wipe src/ but preserve src/frontend_extra.h (our hand-written compat shim).
#   5. Copy each diff'd file into src/ at the same upstream path.
#   6. Auto-generate src/Kbuild by parsing upstream Makefiles for the modules
#      whose source files were synced.
#   7. Write UPSTREAM_VERSION (SHA, date, subject).
#   8. Dry-run-apply patches/ and report any that no longer apply.
#   9. Stage src/, UPSTREAM_VERSION for review. NEVER commits.
#
# Review with `git diff --cached --stat` then commit yourself.

set -euo pipefail

UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/tbsdtv/linux_media.git}"
UPSTREAM_REF="${1:-latest}"
# VANILLA_BASE is auto-detected below from upstream's Makefile (override here if needed).
VANILLA_BASE="${VANILLA_BASE:-}"
CACHE_DIR="${CACHE_DIR:-$HOME/.cache/tbs-dvb-drivers-git-dkms/linux_media}"
REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$REPO_ROOT/src"
PATCHES_DIR="$REPO_ROOT/patches"

# Subtrees in upstream that contain TBS-relevant code.
# The diff is narrowed to these paths so we don't pick up unrelated upstream
# kernel changes that landed on the TBS branch.
SCAN_PATHS=(
    drivers/media/dvb-core/
    drivers/media/dvb-frontends/
    drivers/media/tuners/
    drivers/media/pci/tbsecp3/
    drivers/media/pci/saa716x/
    drivers/media/pci/tbsci/
    drivers/media/pci/tbsmod/
)

# ---------------------------------------------------------------------------
# Update local cache of upstream
# ---------------------------------------------------------------------------
if [ ! -d "$CACHE_DIR/.git" ]; then
    echo "==> First-time clone of upstream into $CACHE_DIR"
    echo "    (full Linux kernel history; this will take a while and several GB)"
    mkdir -p "$(dirname "$CACHE_DIR")"
    git clone "$UPSTREAM_REPO" "$CACHE_DIR"
fi

echo "==> Fetching upstream"
git -C "$CACHE_DIR" fetch --quiet origin

# Resolve REF to a SHA. Try origin/REF (branch), then bare REF (tag/SHA).
if RESOLVED_SHA=$(git -C "$CACHE_DIR" rev-parse --verify --quiet "origin/$UPSTREAM_REF^{commit}"); then
    :
elif RESOLVED_SHA=$(git -C "$CACHE_DIR" rev-parse --verify --quiet "$UPSTREAM_REF^{commit}"); then
    :
else
    echo "ERROR: cannot resolve ref '$UPSTREAM_REF' in upstream"
    exit 1
fi

UPSTREAM_DATE=$(git -C "$CACHE_DIR" show -s --format=%ci "$RESOLVED_SHA")
UPSTREAM_SUBJECT=$(git -C "$CACHE_DIR" log -1 --format=%s "$RESOLVED_SHA")

echo "==> Upstream snapshot: ${RESOLVED_SHA:0:10} ($UPSTREAM_DATE)"
echo "                       $UPSTREAM_SUBJECT"

# ---------------------------------------------------------------------------
# Auto-detect VANILLA_BASE by Makefile content
# ---------------------------------------------------------------------------
# We need a "vanilla Linux" commit to diff against. We find it by walking the
# ancestry of the requested upstream ref, looking for the oldest commit whose
# top-level Makefile contains the same VERSION / PATCHLEVEL / SUBLEVEL /
# EXTRAVERSION values as TBS's current Makefile. That oldest match is the
# release commit that introduced those values — i.e. the kernel TBS forked from.
#
# This grounds the lookup in actual file content rather than metadata
# (commit subject, author), so it doesn't break if Linus changes his message
# style, retires, etc.
if [ -z "$VANILLA_BASE" ]; then
    echo "==> Detecting vanilla base by Makefile content (~5s on a large tree)"
    # Read TBS's claimed version values
    read -r TARGET_V TARGET_P TARGET_S TARGET_E < <(
        git -C "$CACHE_DIR" show "$RESOLVED_SHA:Makefile" | awk '
            /^VERSION[[:space:]]*=/ {v=$3}
            /^PATCHLEVEL[[:space:]]*=/ {p=$3}
            /^SUBLEVEL[[:space:]]*=/ {s=$3}
            /^EXTRAVERSION[[:space:]]*=/ {e=$3}
            END {print v, p, s, e}
        '
    )

    # Walk ancestors of RESOLVED_SHA that touched the Makefile's version block.
    # Filter via -G '^EXTRAVERSION = ' to only commits that touched THAT line —
    # excludes most no-op Makefile churn. ~700 candidates instead of ~2000.
    # Note: don't pipe `git show | head -N` — under `set -o pipefail` the SIGPIPE
    # from head closing early makes git's exit status non-zero, killing the loop.
    # Let awk parse the whole file instead.
    export CACHE_DIR
    mapfile -t MATCHES < <(
        git -C "$CACHE_DIR" log "$RESOLVED_SHA" --format='%H' --no-merges \
            -G '^EXTRAVERSION = ' -- Makefile | while read -r sha; do
            vals=$(git -C "$CACHE_DIR" show "$sha:Makefile" 2>/dev/null | awk '
                /^VERSION = / && !v {v=$3}
                /^PATCHLEVEL = / && !p {p=$3}
                /^SUBLEVEL = / && !s {s=$3}
                /^EXTRAVERSION = / && !e {e=$3; exit}
                END {print v"|"p"|"s"|"e}
            ') || continue
            if [ "$vals" = "$TARGET_V|$TARGET_P|$TARGET_S|$TARGET_E" ]; then
                echo "$sha"
            fi
        done
    )

    if [ "${#MATCHES[@]}" -eq 0 ]; then
        echo "ERROR: no ancestor of ${RESOLVED_SHA:0:10} has a Makefile with"
        echo "       VERSION=$TARGET_V PATCHLEVEL=$TARGET_P SUBLEVEL=$TARGET_S EXTRAVERSION=$TARGET_E"
        echo "Set VANILLA_BASE=<sha> manually and re-run."
        exit 1
    fi

    # The OLDEST match is the commit that introduced these Makefile values.
    # That's the release commit. (Newer matches are non-version-bump commits
    # that touched the Makefile while the version was unchanged.)
    VANILLA_BASE="${MATCHES[-1]}"
    SUBJECT=$(git -C "$CACHE_DIR" log -1 --format='%s' "$VANILLA_BASE")
    echo "==> Detected vanilla base: ${VANILLA_BASE:0:10} (subject: \"$SUBJECT\")"
else
    echo "==> Using user-specified vanilla base: ${VANILLA_BASE:0:10}"
fi
echo "==> Diffing against vanilla ${VANILLA_BASE:0:10}"

# ---------------------------------------------------------------------------
# Get the list of TBS-added files in scope
# ---------------------------------------------------------------------------
# Filter rules:
#   - Skip Makefile / Kconfig (we generate our own Kbuild)
#   - Use --diff-filter=A to take ADDED files only — files TBS introduced.
#     Files that merely differ vs vanilla (e.g. dvb-core/dvbdev.c which TBS
#     patched) are excluded — we don't want to ship modified versions of
#     vanilla kernel files; that's what patches/ is for if ever needed.
#   - Only include regular files inside our scan paths.
mapfile -t CHANGED_FILES < <(
    git -C "$CACHE_DIR" diff --name-only --diff-filter=A \
        "$VANILLA_BASE" "$RESOLVED_SHA" -- "${SCAN_PATHS[@]}" \
        | grep -Ev '/(Makefile|Kconfig)$' \
        | sort
)

if [ ${#CHANGED_FILES[@]} -eq 0 ]; then
    echo "ERROR: diff returned zero files — something is wrong."
    exit 1
fi

echo "==> Found ${#CHANGED_FILES[@]} TBS-added files to sync"

# ---------------------------------------------------------------------------
# Wipe src/, preserve frontend_extra.h
# ---------------------------------------------------------------------------
TMP_FRONTEND_EXTRA=""
if [ -f "$SRC_DIR/frontend_extra.h" ]; then
    TMP_FRONTEND_EXTRA=$(mktemp)
    cp "$SRC_DIR/frontend_extra.h" "$TMP_FRONTEND_EXTRA"
fi

rm -rf "$SRC_DIR"
mkdir -p "$SRC_DIR"

if [ -n "$TMP_FRONTEND_EXTRA" ]; then
    mv "$TMP_FRONTEND_EXTRA" "$SRC_DIR/frontend_extra.h"
fi

# ---------------------------------------------------------------------------
# Copy diff'd files preserving upstream paths
# ---------------------------------------------------------------------------
echo "==> Copying files into src/"
for f in "${CHANGED_FILES[@]}"; do
    src_path="$CACHE_DIR/$f"
    dst_path="$SRC_DIR/$f"
    if [ ! -f "$src_path" ]; then
        echo "  WARN: $f missing in upstream cache (skipping)"
        continue
    fi
    mkdir -p "$(dirname "$dst_path")"
    cp "$src_path" "$dst_path"
done

# ---------------------------------------------------------------------------
# Pull in TBS-modified mainline driver files referenced via #include "..."
# ---------------------------------------------------------------------------
# Some TBS-added drivers (e.g. saa716x_budget.c) #include "tda18212.h" where
# tda18212 is a mainline driver TBS has modified to add new struct fields
# (loop_through, xtout, lnb_power, etc.). The kernel's vanilla tda18212.h
# doesn't have those fields, so the build fails.
#
# Resolution: walk every synced file's #include "..." directives. For each
# referenced filename that exists in upstream as a TBS-MODIFIED file (vs
# vanilla), copy it AND its sibling files (.c, _priv.h, _cfg.h, _reg.h)
# so we ship the TBS-modified versions as full additional modules. The
# resulting *.ko replace the kernel's vanilla versions at module-load time.
#
# Repeat until no new files are added (transitive closure).
echo "==> Resolving TBS-modified mainline driver dependencies"
declare -A SYNCED_PATHS=()
for f in "${CHANGED_FILES[@]}"; do
    SYNCED_PATHS["$f"]=1
done

resolve_includes() {
    local file="$1"
    grep -hE '^[[:space:]]*#[[:space:]]*include[[:space:]]*"[^"]*\.h"' "$file" 2>/dev/null \
        | sed -E 's|.*"([^"]+\.h)".*|\1|'
}

is_modified_in_upstream() {
    # Returns 0 if path exists in both vanilla and upstream and they differ
    local path="$1"
    git -C "$CACHE_DIR" cat-file -e "$VANILLA_BASE:$path" 2>/dev/null || return 1
    git -C "$CACHE_DIR" cat-file -e "$RESOLVED_SHA:$path" 2>/dev/null || return 1
    ! git -C "$CACHE_DIR" diff --quiet "$VANILLA_BASE" "$RESOLVED_SHA" -- "$path"
}

NEW_MODIFIED_PATHS=()
new_count=1
while [ "$new_count" -gt 0 ]; do
    new_count=0
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        for hdr in $(resolve_includes "$f"); do
            # Search upstream paths in scan dirs
            for sd in "${SCAN_PATHS[@]}"; do
                upstream_h="${sd%/}/$hdr"
                # Skip if not present in upstream
                [ -f "$CACHE_DIR/$upstream_h" ] || continue
                # Skip if already in src/
                [ -f "$SRC_DIR/$upstream_h" ] && continue

                # Decide whether we need this driver: ship if EITHER its .h or
                # its .c is modified vs vanilla. The .h alone isn't enough —
                # TBS often modifies just the .c (adding behaviour) leaving the
                # public struct unchanged, but we still need our build to use
                # the TBS .c at runtime.
                base="$(basename "$hdr" .h)"
                hdr_dir="$(dirname "$upstream_h")"
                upstream_c="$hdr_dir/${base}.c"
                need_ship=""
                if is_modified_in_upstream "$upstream_h"; then
                    need_ship=1
                elif [ -f "$CACHE_DIR/$upstream_c" ] && is_modified_in_upstream "$upstream_c"; then
                    need_ship=1
                fi
                [ -n "$need_ship" ] || continue

                # Copy the .h AND all sibling files for this driver basename
                for ext in c h _priv.h _cfg.h _reg.h _proc.h; do
                    case "$ext" in
                        c|h) sib="$hdr_dir/${base}.${ext}" ;;
                        *)   sib="$hdr_dir/${base}${ext}" ;;
                    esac
                    [ -f "$CACHE_DIR/$sib" ] || continue
                    [ -f "$SRC_DIR/$sib" ] && continue
                    mkdir -p "$SRC_DIR/$(dirname "$sib")"
                    cp "$CACHE_DIR/$sib" "$SRC_DIR/$sib"
                    SYNCED_PATHS["$sib"]=1
                    NEW_MODIFIED_PATHS+=("$sib")
                    new_count=$((new_count + 1))
                done
                break   # found this hdr, no need to search other scan dirs
            done
        done
    done < <(find "$SRC_DIR" -type f \( -name '*.c' -o -name '*.h' \))
done

if [ ${#NEW_MODIFIED_PATHS[@]} -gt 0 ]; then
    echo "    Pulled in ${#NEW_MODIFIED_PATHS[@]} TBS-modified mainline file(s):"
    printf '%s\n' "${NEW_MODIFIED_PATHS[@]}" | sort -u | sed 's|^|      |'
fi

# Append the new files to CHANGED_FILES so downstream Kbuild generation sees them
mapfile -t CHANGED_FILES < <(printf '%s\n' "${!SYNCED_PATHS[@]}" | sort)

# ---------------------------------------------------------------------------
# Auto-generate src/Kbuild
# ---------------------------------------------------------------------------
echo "==> Generating src/Kbuild from upstream Makefiles"

# Collect unique upstream Makefiles in directories where we have synced files.
mapfile -t TOUCHED_DIRS < <(
    for f in "${CHANGED_FILES[@]}"; do
        dirname "$f"
    done | sort -u
)

# Build a lookup of synced .c file basenames → relative path within src/.
# Includes both TBS-added files (didn't exist in vanilla) and TBS-modified
# mainline files we pulled in via the #include resolution above.
declare -A SYNCED_BASE_TO_PATH=()
for f in "${CHANGED_FILES[@]}"; do
    [[ "$f" == *.c ]] || continue
    base="$(basename "$f" .c)"
    SYNCED_BASE_TO_PATH["$base"]="$f"
done

# Helper: check if any of a space-separated list of basenames is TBS-added.
# Returns 0 (success) if at least one base is TBS-added, 1 otherwise.
has_tbs_file() {
    local bases="$1"
    for b in $bases; do
        b="${b%.o}"
        # bases may include subdir prefix (e.g. "stid135/chip"); strip to leaf
        b="${b##*/}"
        if [ -n "${SYNCED_BASE_TO_PATH[$b]:-}" ]; then
            return 0
        fi
    done
    return 1
}

KBUILD_OBJ_LINES=()
KBUILD_OBJS_LINES=()
KBUILD_CONFIG_DEFINES=()    # -DCONFIG_FOO=1 lines, one per module that needs IS_ENABLED to evaluate true

for d in "${TOUCHED_DIRS[@]}"; do
    upstream_mk="$CACHE_DIR/$d/Makefile"
    [ -f "$upstream_mk" ] || continue

    while IFS= read -r line; do
        if [[ "$line" =~ ^obj-\$\(CONFIG_([A-Z0-9_]+)\)[[:space:]]*\+?=[[:space:]]*([a-zA-Z0-9_-]+)\.o[[:space:]]*$ ]]; then
            cfg="${BASH_REMATCH[1]}"      # e.g. DVB_TAS2101 / MEDIA_TUNER_AV201X
            target="${BASH_REMATCH[2]}"

            # Single-file module: target.c must be TBS-added
            if [ -n "${SYNCED_BASE_TO_PATH[$target]:-}" ]; then
                KBUILD_OBJ_LINES+=("obj-m += ${SYNCED_BASE_TO_PATH[$target]%.c}.o")
                KBUILD_CONFIG_DEFINES+=("ccflags-y += -DCONFIG_${cfg}=1")
                continue
            fi

            # Multi-file module: look for "<target>-objs := ..." (or -y :=)
            multi=$(awk -v t="$target" '
                $0 ~ "^"t"-(objs|y)[[:space:]]*[:+]?=[[:space:]]*" {
                    inblock=1
                    sub("^"t"-(objs|y)[[:space:]]*[:+]?=[[:space:]]*", "")
                }
                inblock {
                    cont = (sub(/\\$/, ""))
                    print
                    if (!cont) inblock=0
                }
            ' "$upstream_mk")

            if [ -n "$multi" ]; then
                # Only include if at least one of the .o files corresponds to a TBS-added .c
                if has_tbs_file "$multi"; then
                    obj_paths=()
                    for tok in $multi; do
                        [[ "$tok" == *.o ]] || continue
                        base="${tok%.o}"
                        obj_paths+=("$d/$base.o")
                    done
                    # NOTE: kbuild requires the -objs variable name to match the
                    # obj-m target name exactly. We use the bare module name (not
                    # path-prefixed) for both. The resulting .ko ends up at the
                    # top of src/ rather than nested, which is fine for DKMS.
                    KBUILD_OBJS_LINES+=("$target-objs := ${obj_paths[*]}")
                    KBUILD_OBJ_LINES+=("obj-m += $target.o")
                    KBUILD_CONFIG_DEFINES+=("ccflags-y += -DCONFIG_${cfg}=1")
                fi
            fi
        fi
    done < "$upstream_mk"
done

# Deduplicate and sort obj-m lines (multi-line objs entries kept in original order)
mapfile -t KBUILD_OBJ_LINES < <(printf '%s\n' "${KBUILD_OBJ_LINES[@]}" | awk '!seen[$0]++')
mapfile -t KBUILD_CONFIG_DEFINES < <(printf '%s\n' "${KBUILD_CONFIG_DEFINES[@]}" | awk '!seen[$0]++' | sort)

cat > "$SRC_DIR/Kbuild" <<EOF
# AUTO-GENERATED by sync-upstream.sh — do not edit by hand.
# Regenerate by running ./sync-upstream.sh from the repo root.
#
# Module list and -objs entries are derived from upstream Makefiles in:
$(printf '#   %s\n' "${SCAN_PATHS[@]}")
#
# Compiler flags below are hand-curated and preserved across regenerations.

# ---- Multi-file module composition (-objs lines) ----
$(printf '%s\n' "${KBUILD_OBJS_LINES[@]}")

# ---- Module list (obj-m) ----
$(printf '%s\n' "${KBUILD_OBJ_LINES[@]}")

# ---- Per-module CONFIG_* defines ----
# Drivers use IS_ENABLED(CONFIG_DVB_FOO) to gate their public symbols. When
# building in-tree, the kernel's .config supplies these. Out-of-tree, we have
# to define them ourselves. Auto-derived from upstream Makefiles.
$(printf '%s\n' "${KBUILD_CONFIG_DEFINES[@]}")

# ---- Compiler flags ----
# Force-include linux/version.h so LINUX_VERSION_CODE / KERNEL_VERSION are
# always defined. In-tree builds get this transitively via kbuild.h; out-of-tree
# we have to ask for it explicitly, otherwise drivers using those macros fail
# with "missing binary operator before token '('".
ccflags-y += -include linux/version.h
# Force-include our compat header so DVB-S2X enum values defined in
# frontend_extra.h (FEC_29_45, FEC_R_58, APSK_128, etc.) are visible to every
# driver without requiring per-file #include patches.
ccflags-y += -include \$(M)/frontend_extra.h
ccflags-y += -DCONFIG_MEDIA_CONTROLLER=1
ccflags-y += -DCONFIG_MEDIA_CONTROLLER_DVB=1
# Gates STCHIP_* type definitions in stid135's chip.h. Upstream's
# per-directory Makefile sets this; we set it globally because it's
# stid135-only anyway (other drivers don't reference HOST_PC).
ccflags-y += -DHOST_PC
# Search paths for our own headers (synced from upstream + frontend_extra.h)
ccflags-y += -I\$(M)
ccflags-y += -I\$(M)/drivers/media/dvb-core
ccflags-y += -I\$(M)/drivers/media/dvb-frontends
ccflags-y += -I\$(M)/drivers/media/dvb-frontends/stid135
ccflags-y += -I\$(M)/drivers/media/tuners
# Search paths for mainline headers we don't ship (mb86a16.h, stv090x.h, etc.)
# Drivers like saa716x_budget.c #include "mb86a16.h" — kbuild's quoted-include
# lookup only sees the includer's directory unless we add explicit -I paths.
# \$(srctree) points at the kernel headers tree (KERNELDIR), so these paths
# track whatever kernel we're building against.
ccflags-y += -I\$(srctree)/drivers/media/dvb-core
ccflags-y += -I\$(srctree)/drivers/media/dvb-frontends
ccflags-y += -I\$(srctree)/drivers/media/tuners
ccflags-y += -Wno-unused-variable
ccflags-y += -Wno-unused-result
ccflags-y += -Wno-unused-function
ccflags-y += -Wno-unused-label
ccflags-y += -Wno-missing-prototypes
ccflags-y += -Wno-missing-declarations
ccflags-y += -Wno-enum-conversion
ccflags-y += -Wno-switch
EOF

# ---------------------------------------------------------------------------
# Write UPSTREAM_VERSION
# ---------------------------------------------------------------------------
cat > "$REPO_ROOT/UPSTREAM_VERSION" <<EOF
$RESOLVED_SHA
$UPSTREAM_DATE
$UPSTREAM_SUBJECT
EOF

# ---------------------------------------------------------------------------
# Regenerate auto-generated sections of dkms.conf
# ---------------------------------------------------------------------------
DKMS_CONF="$REPO_ROOT/dkms.conf"
if [ ! -f "$DKMS_CONF" ]; then
    echo "==> No dkms.conf yet (skipping auto-generated section update)"
else
    echo "==> Updating dkms.conf auto-generated sections"

    # Build the module list block from KBUILD_OBJ_LINES.
    # Each line "obj-m += <path>/<name>.o" → BUILT_MODULE_NAME[i]=<name>,
    # BUILT_MODULE_LOCATION[i]=src/<path>, DEST_MODULE_LOCATION[i]=/extra
    module_block=""
    i=0
    for line in "${KBUILD_OBJ_LINES[@]}"; do
        # Strip "obj-m += " prefix and ".o" suffix
        path="${line#obj-m += }"
        path="${path%.o}"
        name="$(basename "$path")"
        dir="$(dirname "$path")"
        if [ "$dir" = "." ]; then
            # Bare module name (multi-file module produced at top of src/)
            location="src"
        else
            # Nested path (single-file module produced where its .c lives)
            location="src/$dir"
        fi
        module_block+="BUILT_MODULE_NAME[$i]=\"$name\""$'\n'
        module_block+="BUILT_MODULE_LOCATION[$i]=\"$location\""$'\n'
        module_block+="DEST_MODULE_LOCATION[$i]=\"/extra\""$'\n'
        module_block+=$'\n'
        i=$((i + 1))
    done

    # Replace the module list section in dkms.conf using awk.
    awk -v mod_block="$module_block" '
        /^# BEGIN AUTO-GENERATED MODULE LIST$/ {
            print
            printf "%s", mod_block
            inside_mod = 1
            next
        }
        /^# END AUTO-GENERATED MODULE LIST$/ {
            inside_mod = 0
            print
            next
        }
        !inside_mod { print }
    ' "$DKMS_CONF" > "$DKMS_CONF.tmp"
    mv "$DKMS_CONF.tmp" "$DKMS_CONF"
fi

# ---------------------------------------------------------------------------
# Dry-run apply patches
# ---------------------------------------------------------------------------
if [ -d "$PATCHES_DIR" ] && compgen -G "$PATCHES_DIR/*.patch" >/dev/null; then
    echo "==> Checking patches still apply"
    failed=()
    for p in "$PATCHES_DIR"/*.patch; do
        if ! (cd "$SRC_DIR" && patch -p1 --dry-run --silent < "$p" >/dev/null 2>&1); then
            failed+=("$(basename "$p")")
        fi
    done
    if [ ${#failed[@]} -gt 0 ]; then
        echo
        echo "WARNING: these patches no longer apply cleanly to the new src/:"
        printf '  %s\n' "${failed[@]}"
        echo "Refresh them manually before committing. See README.md."
    else
        echo "    All patches still apply cleanly."
    fi
else
    echo "==> No patches/ yet (skipping patch dry-run)"
fi

# ---------------------------------------------------------------------------
# Stage for git review (do not commit)
# ---------------------------------------------------------------------------
echo "==> Staging changes"
cd "$REPO_ROOT"
git add src/ UPSTREAM_VERSION
[ -f dkms.conf ] && git add dkms.conf

echo
echo "=== Done. Suggested commit message: ==="
echo "Sync upstream to ${RESOLVED_SHA:0:10} ($(echo "$UPSTREAM_DATE" | cut -d' ' -f1))"
echo
echo "$UPSTREAM_SUBJECT"
echo
echo "Review staged diff with:  git diff --cached --stat"
echo "Then commit yourself."
