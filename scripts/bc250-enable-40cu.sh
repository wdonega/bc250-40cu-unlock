#!/usr/bin/env bash
# bc250-enable-40cu.sh — Build and install a patched amdgpu for 40 CU on BC-250
#
# Corrected fork of duggasco/bc250-40cu-unlock with fixes for newer kernels
# (tested on Ubuntu 26.04 / kernel 7.0.0-31-generic).
#
# Fixes relative to upstream:
#   1. Patch anchor: the original awk used /static.*gfx_v10_0_get_cu_info/ as the
#      trigger, but that matches the function PROTOTYPE first (no body). The flag
#      never reset, so the block was inserted at the first mutex_lock of whatever
#      function came next — wrong code that still compiled cleanly.
#      Now anchors on amdgpu_gfx_parse_disable_cu(...), which is unique in the
#      file and sits immediately before the correct mutex_lock.
#   2. Patch verification: upstream grepped for 'bc250-cc-clear', a string the
#      patch never emits. That check failed ALWAYS. Now greps for
#      'bc250-40cu-enable', which the inserted block actually contains.
#   3. Build: upstream called make with M=<absolute path> outside the headers
#      tree, which breaks amdgpu_trace.h's relative include. Now copies the whole
#      amd/ tree into $(MODDIR)/build and uses a relative M=.
#   4. find_source: upstream only looked for .tar.xz and extracted just the
#      amdgpu/ subdir. Ubuntu ships .tar.bz2, and amdgpu/ alone will not build
#      (needs amd/include, amd/display, amd/pm...). Now handles both formats and
#      extracts the complete amd/ tree.
#
# Usage:
#   sudo ./bc250-enable-40cu.sh build     # patch + compile + install
#   sudo ./bc250-enable-40cu.sh enable    # set 40 CU mode
#   sudo ./bc250-enable-40cu.sh disable   # return to stock 24 CU
#   sudo ./bc250-enable-40cu.sh status    # show current CU state
#   sudo ./bc250-enable-40cu.sh restore   # restore original amdgpu module
#
# Requirements: kernel headers, kernel source, gcc, make, zstd, BC-250 hardware.
#
# Authors: duggasco, Claude | License: GPL-2.0

set -euo pipefail

KVER="$(uname -r)"
MODDIR="/lib/modules/${KVER}"
MODPATH="${MODDIR}/kernel/drivers/gpu/drm/amd/amdgpu/amdgpu.ko"
MODSRC=""
BUILDDIR="/tmp/bc250-40cu-build"
CONF40="/etc/modprobe.d/bc250-40cu.conf"
BACKUP_SUFFIX=".bc250-backup-$(date +%Y%m%d)"
BC250_PCI_ID="13fe"

# Unique anchor inside gfx_v10_0_get_cu_info(). If a future kernel renames or
# removes this call, the script aborts instead of inserting in the wrong place.
ANCHOR='amdgpu_gfx_parse_disable_cu(adev, disable_masks, 4, 2);'

info() { printf '\033[0;32m[+]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[0;33m[!]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[0;31m[E]\033[0m %s\n' "$*" >&2; }
die()  { err "$@"; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || die "Must run as root: sudo $0 $*"
}

write_param_patch() {
    cat > "$1" << 'ENDPARAM'

/* BC-250 40 CU unlock: clears harvest mask + enables SPI dispatch to all WGPs */
static int bc250_cc_write_mode;
module_param(bc250_cc_write_mode, int, 0444);
MODULE_PARM_DESC(bc250_cc_write_mode,
	"BC-250: 0=off 1=probe-SE0SH0 2=clear-SE0SH0 3=clear-all-SAs 4=probe-all-SAs");
#define BC250_PCI_DEVICE_ID 0x13FE
ENDPARAM
}

write_cc_patch() {
    cat > "$1" << 'ENDCC'
	/* BC-250: unlock harvested CUs — CC (enumeration) + SPI (dispatch) + RLC (power) */
	if (bc250_cc_write_mode > 0 && adev->pdev->device == BC250_PCI_DEVICE_ID) {
		int bc_se, bc_sh;

		for (bc_se = 0; bc_se < adev->gfx.config.max_shader_engines; bc_se++) {
			for (bc_sh = 0; bc_sh < adev->gfx.config.max_sh_per_se; bc_sh++) {
				u32 bc_cc_orig, bc_cc_after, bc_spi_orig, bc_spi_after;

				if (bc250_cc_write_mode == 2 && (bc_se > 0 || bc_sh > 0))
					continue;

				gfx_v10_0_select_se_sh(adev, bc_se, bc_sh, 0xffffffff, 0);

				bc_cc_orig = RREG32_SOC15(GC, 0, mmCC_GC_SHADER_ARRAY_CONFIG);
				WREG32_SOC15(GC, 0, mmCC_GC_SHADER_ARRAY_CONFIG, 0);
				bc_cc_after = RREG32_SOC15(GC, 0, mmCC_GC_SHADER_ARRAY_CONFIG);

				bc_spi_orig = RREG32_SOC15(GC, 0, mmSPI_PG_ENABLE_STATIC_WGP_MASK);
				WREG32_SOC15(GC, 0, mmSPI_PG_ENABLE_STATIC_WGP_MASK, 0x1f);
				bc_spi_after = RREG32_SOC15(GC, 0, mmSPI_PG_ENABLE_STATIC_WGP_MASK);

				WREG32_SOC15(GC, 0, mmRLC_PG_ALWAYS_ON_WGP_MASK, 0x1f);

				if (bc250_cc_write_mode == 1 || bc250_cc_write_mode == 4) {
					WREG32_SOC15(GC, 0, mmCC_GC_SHADER_ARRAY_CONFIG, bc_cc_orig);
					WREG32_SOC15(GC, 0, mmSPI_PG_ENABLE_STATIC_WGP_MASK, bc_spi_orig);
					dev_info(adev->dev,
						"bc250-40cu-probe: se=%d sh=%d CC=0x%08x->0x%08x SPI=0x%08x->0x%08x (restored)",
						bc_se, bc_sh, bc_cc_orig, bc_cc_after, bc_spi_orig, bc_spi_after);
				} else {
					dev_info(adev->dev,
						"bc250-40cu-enable: mode=%d se=%d sh=%d CC=0x%08x->0x%08x SPI=0x%08x->0x%08x",
						bc250_cc_write_mode, bc_se, bc_sh,
						bc_cc_orig, bc_cc_after, bc_spi_orig, bc_spi_after);
				}
			}
		}
		gfx_v10_0_select_se_sh(adev, 0xffffffff, 0xffffffff, 0xffffffff, 0);
	}
ENDCC
}

check_bc250() {
    if ! lspci -nn 2>/dev/null | grep -qi "${BC250_PCI_ID}"; then
        warn "No BC-250 (PCI ID 13fe) detected. This patch is BC-250 specific."
        printf "Continue anyway? [y/N] "
        read -r ans
        case "$ans" in y|Y) ;; *) exit 1 ;; esac
    fi
}

check_deps() {
    local missing=""
    command -v gcc     >/dev/null 2>&1 || missing="${missing} gcc"
    command -v make    >/dev/null 2>&1 || missing="${missing} make"
    command -v zstd    >/dev/null 2>&1 || missing="${missing} zstd"
    command -v strings >/dev/null 2>&1 || missing="${missing} binutils"
    command -v lspci   >/dev/null 2>&1 || missing="${missing} pciutils"
    [ -d "${MODDIR}/build" ] || missing="${missing} linux-headers-${KVER}"

    [ -z "$missing" ] || die "Missing dependencies:${missing}"

    # Disk space: the amd/ tree plus object files easily exceeds 2 GB.
    local avail_mb
    avail_mb="$(df -Pm "${MODDIR}/build" | awk 'NR==2 {print $4}')"
    if [ "${avail_mb:-0}" -lt 4096 ]; then
        warn "Only ${avail_mb} MB free on ${MODDIR}/build — the build needs ~4 GB."
        printf "Continue anyway? [y/N] "
        read -r ans
        case "$ans" in y|Y) ;; *) exit 1 ;; esac
    fi
}

# Locates (or extracts) a source tree with a COMPLETE drivers/gpu/drm/amd.
find_source() {
    local d
    for d in \
        "/usr/src/linux-source-${KVER%%-*}" \
        "/usr/src/linux-source-${KVER%%+*}" \
        "/usr/src/linux-${KVER}" \
        "/usr/src/linux" \
        "${BUILDDIR}/src"; do
        if [ -f "$d/drivers/gpu/drm/amd/amdgpu/gfx_v10_0.c" ] \
        && [ -f "$d/drivers/gpu/drm/amd/include/kgd_kfd_interface.h" ]; then
            MODSRC="$d"
            info "Kernel source found: ${MODSRC}"
            return 0
        fi
    done

    local srcpkg="" p
    for p in \
        "/usr/src/linux-source-${KVER%%-*}.tar.xz" \
        "/usr/src/linux-source-${KVER%%-*}.tar.bz2" \
        "/usr/src/linux-source-${KVER%%+*}.tar.xz" \
        "/usr/src/linux-source-${KVER%%+*}.tar.bz2"; do
        [ -f "$p" ] && srcpkg="$p" && break
    done

    if [ -z "$srcpkg" ]; then
        srcpkg="$(find /usr/src -maxdepth 4 \
            \( -name 'linux-source-*.tar.xz' -o -name 'linux-source-*.tar.bz2' \) \
            2>/dev/null | head -1)"
    fi

    if [ -z "$srcpkg" ]; then
        info "Kernel source not found locally. Trying apt..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get install -y "linux-source-${KVER%%-*}" 2>/dev/null || true
            srcpkg="$(find /usr/src -maxdepth 4 \
                \( -name 'linux-source-*.tar.xz' -o -name 'linux-source-*.tar.bz2' \) \
                2>/dev/null | head -1)"
        fi
    fi

    [ -n "$srcpkg" ] || die "Cannot find kernel source. Install: apt install linux-source-${KVER%%-*}"

    # Extract the ENTIRE amd/ tree — amdgpu/ alone does not build (it needs
    # amd/include, amd/display, amd/pm, amd/amdkfd...).
    info "Extracting amd/ tree from ${srcpkg} (this takes a while)..."
    rm -rf "${BUILDDIR}/src"
    mkdir -p "${BUILDDIR}/src"
    tar xf "$srcpkg" -C "${BUILDDIR}/src" --strip-components=1 \
        --wildcards '*/drivers/gpu/drm/amd/*' 2>/dev/null || true

    if [ -f "${BUILDDIR}/src/drivers/gpu/drm/amd/amdgpu/gfx_v10_0.c" ] \
    && [ -f "${BUILDDIR}/src/drivers/gpu/drm/amd/include/kgd_kfd_interface.h" ]; then
        MODSRC="${BUILDDIR}/src"
        info "Source extracted to ${MODSRC}"
        return 0
    fi

    die "Incomplete extraction — amd/ tree is not usable at ${BUILDDIR}/src"
}

patch_source() {
    local gfx="${MODSRC}/drivers/gpu/drm/amd/amdgpu/gfx_v10_0.c"
    [ -f "$gfx" ] || die "gfx_v10_0.c not found at ${gfx}"

    if grep -q 'bc250_cc_write_mode' "$gfx"; then
        info "Source already patched."
        return 0
    fi

    # GUARD RAIL: the anchor must exist and be UNIQUE. If the kernel changed this
    # function, aborting beats inserting the block somewhere else.
    local anchor_count
    anchor_count="$(grep -cF "$ANCHOR" "$gfx" || true)"
    if [ "$anchor_count" -eq 0 ]; then
        die "Anchor not found in gfx_v10_0.c: '${ANCHOR}'
    The layout of gfx_v10_0_get_cu_info() changed in this kernel (${KVER}).
    Update the ANCHOR variable at the top of this script to a unique line that
    sits immediately before that function's mutex_lock(&adev->grbm_idx_mutex)."
    elif [ "$anchor_count" -gt 1 ]; then
        die "Ambiguous anchor: '${ANCHOR}' appears ${anchor_count}x in gfx_v10_0.c.
    Pick a unique line before continuing."
    fi

    info "Patching gfx_v10_0.c (anchor at line $(grep -nF "$ANCHOR" "$gfx" | cut -d: -f1))..."
    cp "$gfx" "${gfx}.orig"

    # Step 1: module parameter before '#include "amdgpu.h"'
    grep -q '#include "amdgpu.h"' "$gfx" || die "Anchor not found: #include \"amdgpu.h\""

    local param_file
    param_file="$(mktemp)"
    write_param_patch "$param_file"
    sed -i "/#include \"amdgpu.h\"/r ${param_file}" "$gfx"
    rm -f "$param_file"

    # Step 2: CC/SPI block right after the mutex_lock that follows the anchor.
    local cc_file
    cc_file="$(mktemp)"
    write_cc_patch "$cc_file"

    awk -v insertfile="$cc_file" -v anchor="$ANCHOR" '
    {
        print
        if (index($0, anchor) > 0) { found = 1 }
        if (found && /mutex_lock/ && !inserted) {
            while ((getline line < insertfile) > 0) print line
            close(insertfile)
            inserted = 1
        }
    }
    END {
        if (!inserted) exit 3
    }
    ' "$gfx" > "${gfx}.new" || {
        rm -f "${gfx}.new" "$cc_file"
        mv "${gfx}.orig" "$gfx"
        die "Anchor found, but no mutex_lock after it. Unexpected layout."
    }

    # Verification: grep for the string the patch ACTUALLY emits.
    if grep -q 'bc250-40cu-enable' "${gfx}.new"; then
        mv "${gfx}.new" "$gfx"
        rm -f "$cc_file"
        info "Patch applied successfully (line $(grep -n 'bc250-40cu-enable' "$gfx" | head -1 | cut -d: -f1))."
    else
        rm -f "${gfx}.new" "$cc_file"
        mv "${gfx}.orig" "$gfx"
        die "CC write block was not inserted. Kernel source layout may differ."
    fi
}

build_module() {
    local rel_amd="drivers/gpu/drm/amd"
    local dest_amd="${MODDIR}/build/${rel_amd}"

    [ -d "${MODSRC}/${rel_amd}" ] || die "amd/ tree not found under ${MODSRC}"

    # amdgpu_trace.h's relative include only resolves when the module sits INSIDE
    # the tree kbuild treats as srctree. Hence: a real copy (not a symlink — make
    # resolves the link and loses the M= reference) plus a relative M=.
    info "Copying amd/ tree into ${dest_amd}..."
    rm -rf "${dest_amd}"
    mkdir -p "$(dirname "${dest_amd}")"
    cp -a "${MODSRC}/${rel_amd}" "${dest_amd}"

    info "Building amdgpu module for kernel ${KVER} (5-15 min)..."
    ( cd "${MODDIR}/build" && make M="${rel_amd}/amdgpu" -j"$(nproc)" modules ) 2>&1 | tail -20 >&2

    local built="${dest_amd}/amdgpu/amdgpu.ko"
    [ -f "$built" ] || die "Build failed - amdgpu.ko not produced"


    if ! modinfo "$built" 2>/dev/null | grep 'bc250_cc_write_mode' >/dev/null; then
        die "Built module missing bc250_cc_write_mode - patch failed"
    fi

    info "Build successful: ${built} ($(du -h "$built" | cut -f1))"
    echo "$built"
}

install_module() {
    local built="$1"
    local target="${MODPATH}"

    [ -f "$built" ] || die "Module not found at: ${built}"

    if [ -f "${target}.zst" ]; then
        target="${target}.zst"
    elif [ ! -f "$target" ]; then
        target="${target}.zst"
    fi

    # Back up only once — never overwrite a stock-module backup with a patched one.
    if [ -f "$target" ] && [ ! -f "${target}${BACKUP_SUFFIX}" ]; then
        if ls "${target}.bc250-backup-"* >/dev/null 2>&1; then
            info "Existing backup found, keeping the original."
        else
            info "Backing up original to ${target}${BACKUP_SUFFIX}"
            cp "$target" "${target}${BACKUP_SUFFIX}"
        fi
    fi

    # Out-of-tree builds keep debug symbols (~700 MB). Strip before installing.
    info "Stripping debug symbols..."
    local stripped="${built}.stripped"
    strip --strip-debug "$built" -o "$stripped"
    info "Stripped: $(du -h "$stripped" | cut -f1) (was $(du -h "$built" | cut -f1))"

    if [ "${target%.zst}" != "$target" ]; then
        info "Compressing and installing module..."
        zstd -q -f "$stripped" -o "$target"
    else
        cp "$stripped" "$target"
    fi
    rm -f "$stripped"

    depmod -a "$KVER"
    info "Module installed at ${target}"
}

do_build() {
    require_root build
    check_bc250
    check_deps
    find_source
    patch_source
    local built
    built="$(build_module)"
    install_module "$built"
    echo ""
    info "Done! Patched amdgpu module installed."
    warn "A kernel upgrade reverts this — re-run 'build' after upgrades."
    info "Before enabling, check your board's harvest map: ./scripts/cu_map.sh"
    info "Next: sudo $0 enable"
}

do_enable() {
    require_root enable

    if ! modinfo amdgpu 2>/dev/null | grep 'bc250_cc_write_mode' >/dev/null; then
        die "Patched module not detected. Run first: sudo $0 build"
    fi

    printf '# BC-250 40 CU re-enablement\noptions amdgpu bc250_cc_write_mode=3\n' > "$CONF40"
    info "40 CU mode configured in ${CONF40}"

    # Ubuntu/Debian: modprobe.d must make it into the initramfs.
    if command -v update-initramfs >/dev/null 2>&1; then
        info "Updating initramfs..."
        update-initramfs -u -k "$KVER"
    elif command -v dracut >/dev/null 2>&1; then
        info "Updating initramfs (dracut)..."
        dracut -f
    fi

    printf "Reboot now? [y/N] "
    read -r ans
    case "$ans" in
        y|Y) info "Rebooting..."; sleep 2; reboot ;;
        *)   info "Config written. Reboot when ready to apply." ;;
    esac
}

do_disable() {
    require_root disable
    rm -f "$CONF40"
    if command -v update-initramfs >/dev/null 2>&1; then
        update-initramfs -u -k "$KVER"
    elif command -v dracut >/dev/null 2>&1; then
        dracut -f
    fi
    info "40 CU config removed. Reboot to return to stock 24 CU."
}

do_restore() {
    require_root restore
    local target="${MODPATH}"
    [ -f "${target}.zst" ] && target="${target}.zst"

    local backup
    backup="$(ls -1 "${target}.bc250-backup-"* 2>/dev/null | head -1)"
    [ -n "$backup" ] || die "No backup found"

    cp "$backup" "$target"
    rm -f "$CONF40"
    depmod -a "$KVER"

    if command -v update-initramfs >/dev/null 2>&1; then
        update-initramfs -u -k "$KVER"
    fi

    info "Original module restored from ${backup}. Reboot to apply."
}

do_status() {
    printf '\033[1m=== BC-250 CU Status ===\033[0m\n\n'
    printf ' kernel:        %s\n' "$KVER"

    if lspci -nn 2>/dev/null | grep -qi "${BC250_PCI_ID}"; then
        printf ' PCI device:    \033[0;32mBC-250 detected\033[0m\n'
    else
        printf ' PCI device:    \033[0;31mBC-250 not found\033[0m\n'
    fi

    if modinfo amdgpu 2>/dev/null | grep 'bc250_cc_write_mode' >/dev/null; then
        printf ' amdgpu module: \033[0;32mpatched\033[0m\n'
    else
        printf ' amdgpu module: \033[0;33mstock (unpatched)\033[0m\n'
    fi

    local mode
    mode="$(cat /sys/module/amdgpu/parameters/bc250_cc_write_mode 2>/dev/null || echo 'N/A')"
    printf ' write_mode:    %s\n' "$mode"

    local cu_line cus
    cu_line="$(dmesg 2>/dev/null | grep 'active_cu_number' | tail -1 || true)"
    if [ -n "$cu_line" ]; then
        cus="$(echo "$cu_line" | grep -o 'active_cu_number [0-9]*' | awk '{print $2}')"
        if [ "$cus" = "40" ]; then
            printf ' active CUs:    \033[0;32m\033[1m40\033[0m (full die)\n'
        elif [ "$cus" = "24" ]; then
            printf ' active CUs:    \033[0;33m24\033[0m (stock)\n'
        else
            printf ' active CUs:    %s\n' "$cus"
        fi
    else
        printf ' active CUs:    (no dmesg info — run as root)\n'
    fi

    if [ -f "$CONF40" ]; then
        printf ' modprobe conf: \033[0;32m%s (40 CU enabled)\033[0m\n' "$CONF40"
    else
        printf ' modprobe conf: (none - stock mode)\n'
    fi
    echo ""
}

case "${1:-}" in
    build)   do_build ;;
    enable)  do_enable ;;
    disable) do_disable ;;
    restore) do_restore ;;
    status)  do_status ;;
    *)
        echo "BC-250 40 CU Re-enablement Tool (corrected fork)"
        echo ""
        echo "Usage: sudo $0 <command>"
        echo ""
        echo "  build    Patch, compile, install patched amdgpu (~5-15 min)"
        echo "  enable   Activate 40 CU mode (writes modprobe.d + initramfs)"
        echo "  disable  Return to stock 24 CU"
        echo "  status   Show current CU state"
        echo "  restore  Restore original amdgpu module from backup"
        echo ""
        echo "Quick start:"
        echo "  sudo $0 build && sudo $0 enable"
        ;;
esac
