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

reset_dir() {
    rm -rf "$1" || abort "[!] Failed to reset $1"
    mkdir -p "$1" || abort "[!] Failed to create $1"
}

keycode_select() {
    local key_press key_release

    ui_print "- [*] $1"
    ui_print "- [*] Vol+ = Yes, Vol- = No."
    ui_print "- [*] Please press the key..."
    while true; do
        "$BIN/keycheck"
        key_press=$?
        case "$key_press" in
            0|126|127) abort "[!] Failed to read volume keys" ;;
        esac
        "$BIN/keycheck"
        key_release=$?
        case "$key_release" in
            0|126|127) abort "[!] Failed to read volume keys" ;;
        esac
        [ "$key_press" = "$key_release" ] || continue
        case "$key_release" in
            "$KEYCODE_UP")
                ui_print "- [*] You chose Yes."
                return 0
                ;;
            "$KEYCODE_DOWN")
                ui_print "- [*] You chose No."
                return 1
                ;;
        esac
    done
}

fix_hyperos_wlan() {
    local dir="$module_extract_dir/vendor_dlkm/lib/modules"
    local config="$AKHOME/config/vendor_dlkm_fs_config"
    local name="wmt_chrdev_wifi_connac2.ko"

    ui_print "- [*] Applying HyperOS WLAN fix..."
    [ -f "$config" ] || abort "[!] Missing vendor_dlkm fs_config"
    cp -p "$dir/wmt_chrdev_wifi.ko" "$dir/$name" ||
        abort "[!] Failed to create WLAN module alias"
    if ! grep -Fq "vendor_dlkm/lib/modules/$name " "$config"; then
        printf 'vendor_dlkm/lib/modules/%s 0 0 0644\n' "$name" >> "$config" ||
            abort "[!] Failed to update WLAN fs_config"
    fi
    ui_print "- [*] HyperOS WLAN fix applied"
}

if [ -f /system/framework/MiuiBooster.jar ]; then
    prompt="HyperOS detected. Is this correct?"
else
    prompt="HyperOS not detected. Are you using HyperOS?"
fi
if keycode_select "$prompt"; then
    is_hyperos=true
else
    is_hyperos=false
fi
ui_print "- [*] HyperOS: $is_hyperos"

ui_print " " "- [+] Starting kernel image flashing..."
ui_print "- [*] Checking kernel image..."
"$BIN/busybox" sha256sum -cs Image.zst.sha256 || abort "[!] SHA256 mismatch"
ui_print "- [*] SHA256 OK"

ui_print "- [*] Unpacking kernel image..."
"$BIN/zstd" -d -q --no-progress -o "$AKHOME/Image" "$AKHOME/Image.zst" ||
    abort "[!] Failed to decompress kernel image"
ui_print "- [*] Kernel image unpacked"

module_archive="$AKHOME/module.tar.xz"
module_extract_dir="$AKHOME/_module"

if [ -f "$module_archive" ]; then
    ui_print " " "- [+] Unpacking module package..."
    reset_dir "$module_extract_dir"
    busybox tar -xpf "$module_archive" -C "$module_extract_dir" ||
        abort "- [!] Failed to extract module.tar.xz"
    if [ "$is_hyperos" = true ] && [ -d "$module_extract_dir/vendor_dlkm" ]; then
        fix_hyperos_wlan
    fi
fi

ui_print "- [+] Flashing kernel image..."
# boot install
split_boot # use split_boot to skip ramdisk unpack, e.g. for devices with init_boot ramdisk

if [ -f "$SPLITIMG/ramdisk.cpio" ]; then
    unpack_ramdisk
    write_boot
else
    flash_boot # use flash_boot to skip ramdisk repack, e.g. for devices with init_boot ramdisk
fi
## end boot install

rm -f "$AKHOME/Image" || abort "[!] Failed to remove extracted Image"

# vendor_boot shell variables
BLOCK=vendor_boot
IS_SLOT_DEVICE=1
RAMDISK_COMPRESSION=auto
PATCH_VBMETA_FLAG=auto

# reset for vendor_boot patching
reset_ak

# vendor_boot install
split_boot # use split_boot to skip ramdisk unpack, e.g. for dtb on devices with hdr v4 but no vendor_kernel_boot

if [ -d "$module_extract_dir/vendor_boot" ]; then
    ui_print " " "- [+] Starting vendor_ramdisk modules update..."

    vendor_boot_ramdisk_dir="$AKHOME/_vendor_boot_ramdisk"

    reset_dir "$vendor_boot_ramdisk_dir"

    ui_print "- [*] Unpacking ramdisk..."
    (
        cd "$vendor_boot_ramdisk_dir" &&
            "$BIN/busybox" cpio -i -d <"$SPLITIMG/vendor_ramdisk/ramdisk.cpio"
    ) || abort "- [!] Failed to unpack ramdisk.cpio"

    ui_print "- [*] Updating ramdisk.cpio modules..."
    rm -rf "$vendor_boot_ramdisk_dir/lib/modules" ||
        abort "- [!] Failed to remove old modules"
    mkdir -p "$vendor_boot_ramdisk_dir/lib" ||
        abort "- [!] Failed to prepare ramdisk modules directory"
    mv "$module_extract_dir/vendor_boot/lib/modules" "$vendor_boot_ramdisk_dir/lib/modules" ||
        abort "- [!] Failed to move vendor_boot modules"

    ui_print "- [*] Repacking ramdisk.cpio..."
    (
        cd "$vendor_boot_ramdisk_dir" &&
            busybox find . | busybox cpio -o -H newc >"$SPLITIMG/vendor_ramdisk/ramdisk.cpio" 2>/dev/null
    ) || abort "[!] Failed to repack ramdisk.cpio"

    rm -rf "$vendor_boot_ramdisk_dir" ||
        abort "- [!] Failed to remove working directory"
fi

ui_print "- [+] Flashing new vendor_boot image..."
flash_boot # use flash_boot to skip ramdisk repack, e.g. for dtb on devices with hdr v4 but no vendor_kernel_boot
## end vendor_boot install

## vendor_dlkm install
if [ -d "$module_extract_dir/vendor_dlkm" ]; then
    # reset for vendor_dlkm patching
    reset_ak

    ui_print " " "/dev/block/mapper/vendor_dlkm${SLOT}"
    ui_print " " "- [+] Starting /vendor_dlkm modules update..."

    ui_print "- [*] Pulling /vendor_dlkm image from current slot (${SLOT})..."
    dd if="/dev/block/mapper/vendor_dlkm${SLOT}" of="$AKHOME/vendor_dlkm.img" bs=1048576 ||
        abort "[!] Failed to pull vendor_dlkm${SLOT}.img"
    extract_vendor_dlkm_dir=${AKHOME}/_extract_vendor_dlkm
    reset_dir "$extract_vendor_dlkm_dir"

    ui_print "- [*] Unpacking /vendor_dlkm image..."
    "${BIN}"/extract.erofs -i "${AKHOME}"/vendor_dlkm.img -x -T8 -o "${extract_vendor_dlkm_dir}" >/dev/null 2>&1 ||
        abort "[!] Failed to unpack the vendor_dlkm image"
    ui_print "- [*] Updating /vendor_dlkm modules..."
    extract_vendor_dlkm_modules_dir=${extract_vendor_dlkm_dir}/vendor_dlkm/lib/modules
    rm -rf "$extract_vendor_dlkm_modules_dir" ||
        abort "[!] Failed to remove pre-existing files in ${extract_vendor_dlkm_modules_dir}"
    mv "$module_extract_dir/vendor_dlkm/lib/modules" "$extract_vendor_dlkm_modules_dir" ||
        abort "[!] Failed to move vendor_dlkm modules"
    dlkm_config_dir=${extract_vendor_dlkm_dir}/config
    awk 'NR == FNR { seen[$1] = 1; next }
         /^vendor_dlkm\/lib\/modules\// && !seen[$1]++ { print }' \
        "$dlkm_config_dir/vendor_dlkm_fs_config" "$AKHOME/config/vendor_dlkm_fs_config" > "$dlkm_config_dir/new_modules" ||
        abort "[!] Failed to prepare module fs_config entries"
    awk 'NR == FNR {
             if ($1 == "/vendor_dlkm/lib/modules") label = $2
             next
         }
         {
             path = "/" $1
             gsub(/[^[:alnum:]_\/-]/, "\\\\&", path)
             print path, (label ? label : "u:object_r:vendor_file:s0")
         }' "$dlkm_config_dir/vendor_dlkm_file_contexts" "$dlkm_config_dir/new_modules" >> "$dlkm_config_dir/vendor_dlkm_file_contexts" ||
        abort "[!] Failed to add module file contexts"
    cat "$dlkm_config_dir/new_modules" >> "$dlkm_config_dir/vendor_dlkm_fs_config" ||
        abort "[!] Failed to add module fs_config entries"

    ui_print "- [*] Repacking /vendor_dlkm image..."
    rm -f "${AKHOME}"/vendor_dlkm.img ||
        abort "[!] Failed to remove pre-existing vendor_dlkm.img"
    "${BIN}"/mkfs.erofs \
        --mount-point /vendor_dlkm \
        --fs-config-file "${extract_vendor_dlkm_dir}"/config/vendor_dlkm_fs_config \
        --file-contexts "${extract_vendor_dlkm_dir}"/config/vendor_dlkm_file_contexts \
        -z lz4 \
        -b 4096 \
        -C 262144 \
        -T 1230768000 \
        "${AKHOME}"/vendor_dlkm.img "${extract_vendor_dlkm_dir}"/vendor_dlkm ||
        abort "[!] Failed to repack the vendor_dlkm image"
    rm -rf "${extract_vendor_dlkm_dir}" ||
        abort "[!] Failed to remove working directory"
    unset extract_vendor_dlkm_dir extract_vendor_dlkm_modules_dir dlkm_config_dir

    vendor_dlkm_block_size=$(blockdev --getsize64 /dev/block/mapper/vendor_dlkm"${SLOT}")
    if [ "$(wc -c <"$AKHOME"/vendor_dlkm.img)" -lt "${vendor_dlkm_block_size}" ]; then
        ui_print "- [*] Generated /vendor_dlkm image size is smaller than the block device..."
        ui_print "- [*] Truncating to fill the erofs image file..."
        truncate -c -s "$vendor_dlkm_block_size" "$AKHOME"/vendor_dlkm.img
    fi

    ui_print "- [+] Flashing new /vendor_dlkm image..."
    flash_generic vendor_dlkm
fi

rm -rf "$module_extract_dir"
## end vendor_dlkm install
