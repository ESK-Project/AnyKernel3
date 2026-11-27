### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers
## cyberknight777 @ xda-developers
## bachnxuan @ esk-project

### AnyKernel setup
# global properties
properties() { '
kernel.string=ESK Kernel for xaga by bachnxuan @ esk-project
do.devicecheck=0
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=
device.name2=
device.name3=
device.name4=
supported.versions=
supported.vendorpatchlevels=
'; } # end properties

### AnyKernel install

# boot shell variables
BLOCK=boot
IS_SLOT_DEVICE=1
RAMDISK_COMPRESSION=auto
PATCH_VBMETA_FLAG=auto
NO_MAGISK_CHECK=true

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh

KEYCODE_UP=42
KEYCODE_DOWN=41

fail() {
    abort " " "[!] $1"
}

require() {
    local message="$1"
    shift
    "$@" || fail "$message"
}

reset_dir() {
    rm -rf "$1" && mkdir -p "$1"
}

keycode_select() {
    local key_press key_release

    ui_print " " "$1" "- Vol+  $2" "- Vol-  $3"
    while true; do
        "$BIN/keycheck"
        key_press=$?
        case "$key_press" in
            0|126|127) fail "Could not read the volume keys." ;;
        esac
        "$BIN/keycheck"
        key_release=$?
        case "$key_release" in
            0|126|127) fail "Could not read the volume keys." ;;
        esac
        [ "$key_press" = "$key_release" ] || continue
        case "$key_release" in
            "$KEYCODE_UP") return 0 ;;
            "$KEYCODE_DOWN") return 1 ;;
        esac
    done
}

fix_hyperos_wlan() {
    local dir="$module_extract_dir/vendor_dlkm/lib/modules"
    local config="$AKHOME/config/vendor_dlkm_fs_config"
    local name="wmt_chrdev_wifi_connac2.ko"

    ui_print "- Applying HyperOS Wi-Fi fix"
    require "The package is missing vendor_dlkm_fs_config for the Wi-Fi fix." test -f "$config"
    require "Could not create the HyperOS Wi-Fi module $name." \
        cp -p "$dir/wmt_chrdev_wifi.ko" "$dir/$name"
    if ! grep -Fq "vendor_dlkm/lib/modules/$name " "$config"; then
        printf 'vendor_dlkm/lib/modules/%s 0 0 0644\n' "$name" >> "$config" ||
            fail "Could not add $name to vendor_dlkm_fs_config."
    fi
}

confirm_hyperos() {
    local prompt

    if [ -f /system/framework/MiuiBooster.jar ]; then
        prompt="HyperOS detected. Choose your ROM."
    else
        prompt="HyperOS was not detected. Choose your ROM."
    fi
    if keycode_select "$prompt" HyperOS AOSP; then
        is_hyperos=true
        ui_print "- Selected HyperOS"
    else
        is_hyperos=false
        ui_print "- Selected AOSP"
    fi
}

prepare_kernel() {
    ui_print " " "Preparing the kernel" "- Checking the image checksum"
    require "Kernel image checksum check failed. Download the installer ZIP again." \
        "$BIN/busybox" sha256sum -cs Image.zst.sha256
    ui_print "- Unpacking the kernel image"
    require "Could not unpack Image.zst. Download the installer ZIP again." \
        "$BIN/zstd" -d -q --no-progress \
        -o "$AKHOME/Image" "$AKHOME/Image.zst"
}

prepare_modules() {
    local archive="$AKHOME/module.tar.xz"

    [ -f "$archive" ] || return 0
    ui_print " " "Preparing kernel modules" "- Unpacking the module archive"
    require "Could not create the module working directory." reset_dir "$module_extract_dir"
    require "Could not unpack module.tar.xz. Download the installer ZIP again." \
        busybox tar -xpf "$archive" -C "$module_extract_dir"
    if [ "$is_hyperos" = true ] && [ -d "$module_extract_dir/vendor_dlkm" ]; then
        fix_hyperos_wlan
    fi
}

remove_boot_kernelsu_lkm() {
    local archive="$1"
    local magiskboot="$BIN/magiskboot"

    "$magiskboot" cpio "$archive" "exists kernelsu.ko"
    case "$?" in
        0) ;;
        1) return 0 ;;
        *) fail "Could not check the boot ramdisk for KernelSU LKM." ;;
    esac

    keycode_select "KernelSU LKM detected. It can prevent ESK from booting." \
        "Remove LKM and continue" "Cancel installation" ||
        fail "Installation cancelled. Boot was left untouched."
    require "Missing init.real. Restore your ROM's boot image and try again." \
        "$magiskboot" cpio "$archive" "exists init.real"
    require "Could not restore init or remove KernelSU LKM from the boot ramdisk." \
        "$magiskboot" cpio "$archive" "rm kernelsu.ko" "mv init.real init"
    ui_print "- KernelSU LKM removed"
}

install_boot() {
    local archive="$SPLITIMG/ramdisk.cpio"

    ui_print " " "Updating boot"
    split_boot
    if [ -f "$archive" ]; then
        remove_boot_kernelsu_lkm "$archive"
        unpack_ramdisk
        write_boot
    else
        flash_boot
    fi
    require "Could not remove the temporary kernel image after flashing boot." \
        rm -f "$AKHOME/Image"
}

replace_modules() {
    local source="$1" destination="$2"

    rm -rf "$destination" &&
        mkdir -p "${destination%/*}" &&
        mv "$source" "$destination"
}

update_vendor_ramdisk() {
    local work="$AKHOME/_vendor_boot_ramdisk"
    local archive="$SPLITIMG/vendor_ramdisk/ramdisk.cpio"

    # some roms' vendor ramdisk are monolithic
    if [ ! -f "$archive" ]; then
        archive="$SPLITIMG/ramdisk.cpio"
    fi

    [ -f "$archive" ] || fail "Could not find a ramdisk in vendor_boot."
    require "Could not create the vendor_boot working directory." reset_dir "$work"

    ui_print "- Unpacking the vendor ramdisk"
    (
        cd "$work" &&
            "$BIN/busybox" cpio -i -d <"$archive"
    ) || fail "Could not unpack the vendor_boot ramdisk."

    ui_print "- Replacing kernel modules"
    require "Could not replace the kernel modules in the vendor_boot ramdisk." \
        replace_modules "$module_extract_dir/vendor_boot/lib/modules" "$work/lib/modules"

    ui_print "- Repacking the vendor ramdisk"
    (
        cd "$work" &&
            busybox find . | busybox cpio -o -H newc >"$archive" 2>/dev/null
    ) || fail "Could not repack the vendor_boot ramdisk."

    require "Could not clean up the vendor_boot working directory." rm -rf "$work"
}

unpack_vendor_boot() {
    "$BIN/magiskboot" "$@"
    local result=$?
    [ "$result" -eq 1 ] || return "$result"
    "$BIN/fix_vendor_ramdisk" "$BOOTIMG" || return 1
    ui_print "- Retrying with the corrected vendor ramdisk size"
    "$BIN/magiskboot" "$@"
}

install_vendor_boot() {
    BLOCK="${BLOCK%/*}/vendor_boot$SLOT"
    IS_SLOT_DEVICE=1
    RAMDISK_COMPRESSION=auto
    PATCH_VBMETA_FLAG=auto
    ui_print " " "Updating vendor_boot"
    reset_ak
    split_boot unpack_vendor_boot

    if [ -d "$module_extract_dir/vendor_boot" ]; then
        update_vendor_ramdisk
    fi

    ui_print "- Flashing the vendor_boot image"
    flash_boot
}

merge_module_metadata() {
    local fs_config="$1/vendor_dlkm_fs_config"
    local contexts="$1/vendor_dlkm_file_contexts"
    local new_modules="$1/new_modules"

    awk 'NR == FNR { seen[$1] = 1; next }
         /^vendor_dlkm\/lib\/modules\// && !seen[$1]++ { print }' \
        "$fs_config" "$AKHOME/config/vendor_dlkm_fs_config" >"$new_modules" &&
        awk 'NR == FNR {
                 if ($1 == "/vendor_dlkm/lib/modules") label = $2
                 next
             }
             {
                 path = "/" $1
                 gsub(/[^[:alnum:]_\/-]/, "\\\\&", path)
                 print path, (label ? label : "u:object_r:vendor_file:s0")
             }' "$contexts" "$new_modules" >>"$contexts" &&
        cat "$new_modules" >>"$fs_config"
}

repack_vendor_dlkm() {
    local work="$1" image="$2"

    rm -f "$image" &&
        "$BIN/mkfs.erofs" \
            --mount-point /vendor_dlkm \
            --fs-config-file "$work/config/vendor_dlkm_fs_config" \
            --file-contexts "$work/config/vendor_dlkm_file_contexts" \
            -z lz4hc,level=12 -b 4096 -C 262144 -T 1230768000 \
            "$image" "$work/vendor_dlkm"
}

install_vendor_dlkm() {
    local work="$AKHOME/_extract_vendor_dlkm"
    local image="$AKHOME/vendor_dlkm.img"
    local partition block_size image_size

    [ -d "$module_extract_dir/vendor_dlkm" ] || return 0
    reset_ak
    partition="/dev/block/mapper/vendor_dlkm${SLOT}"

    ui_print " " "Updating vendor_dlkm" "- Reading vendor_dlkm${SLOT}"
    require "Could not read $partition." dd if="$partition" of="$image" bs=1048576

    ui_print "- Extracting the EROFS image"
    require "Could not create the vendor_dlkm working directory." reset_dir "$work"
    "$BIN/extract.erofs" -i "$image" -x -T8 -o "$work" >/dev/null ||
        fail "Could not extract the vendor_dlkm EROFS image."

    ui_print "- Replacing kernel modules"
    require "Could not replace the kernel modules in vendor_dlkm." \
        replace_modules "$module_extract_dir/vendor_dlkm/lib/modules" "$work/vendor_dlkm/lib/modules"
    require "Could not merge permissions and SELinux labels for the vendor_dlkm modules." \
        merge_module_metadata "$work/config"

    ui_print "- Rebuilding the EROFS image"
    require "Could not rebuild the vendor_dlkm EROFS image." repack_vendor_dlkm "$work" "$image"
    require "Could not clean up the vendor_dlkm working directory." rm -rf "$work"

    block_size=$(blockdev --getsize64 "$partition") ||
        fail "Could not read the size of $partition."
    image_size=$(wc -c <"$image") || fail "Could not read the size of the rebuilt vendor_dlkm image."
    if [ "$image_size" -lt "$block_size" ]; then
        ui_print "- Padding the image to fit the partition"
        require "Could not pad vendor_dlkm.img to $block_size bytes." truncate -c -s "$block_size" "$image"
    fi

    ui_print "- Flashing the vendor_dlkm image"
    flash_generic vendor_dlkm "$partition"
}

# Ref: https://github.com/Pzqqt/AnyKernel3/blob/Marble-Bouquet/anykernel.sh
backup_partitions() {
    ROLLBACK_DIR="$AKHOME/_orig"
    require "Could not create the partition backup directory." mkdir -p "$ROLLBACK_DIR"
    require "Could not back up boot." \
        dd if="$BLOCK" of="$ROLLBACK_DIR/boot.img" bs=1048576
    require "Could not back up vendor_boot." \
        dd if="${BLOCK%/*}/vendor_boot$SLOT" of="$ROLLBACK_DIR/vendor_boot.img" bs=1048576
    if [ -d "$module_extract_dir/vendor_dlkm" ]; then
        require "Could not back up vendor_dlkm." \
            dd if="/dev/block/mapper/vendor_dlkm$SLOT" of="$ROLLBACK_DIR/vendor_dlkm.img" bs=1048576
    fi
    printf '%s\n' "$SLOT" >"$ROLLBACK_DIR/slot" || fail "Could not save the backup slot."
    getprop ro.product.device >"$ROLLBACK_DIR/device" || fail "Could not save the backup device."
}

create_restore_zip() {
    local archive="/sdcard/ESK-restore-$(cat "$ROLLBACK_DIR/device")$SLOT-$(date +%Y%m%d-%H%M%S).zip"

    ui_print "- Creating the restore ZIP"
    (
        cd "$AKHOME" &&
            "$BIN/7za" a -tzip -bd "$archive" META-INF LICENSE _restore_anykernel.sh _orig \
                tools/ak3-core.sh tools/busybox tools/fec tools/httools_static tools/lptools_static \
                tools/snapshotupdater_static &&
            "$BIN/7za" rn -bd "$archive" _restore_anykernel.sh anykernel.sh
    ) || {
        rm -f "$archive"
        fail "Could not create the restore ZIP in /sdcard."
    }
    sync
    ui_print "- Restore ZIP saved to $archive"
}

main() {
    local module_extract_dir="$AKHOME/_module"
    local is_hyperos

    confirm_hyperos
    prepare_kernel
    prepare_modules
    backup_partitions
    create_restore_zip
    install_boot
    install_vendor_boot
    install_vendor_dlkm
    rm -rf "$module_extract_dir"
}

main
