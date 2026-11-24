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

require() {
    local message="$1"
    shift
    "$@" || abort "[!] $message"
}

reset_dir() {
    rm -rf "$1" && mkdir -p "$1"
}

keycode_select() {
    local key_press key_release

    ui_print "- [*] $1"
    ui_print "- [*] Vol+ = Yes (HyperOS), Vol- = No (AOSP)."
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
    require "Missing vendor_dlkm fs_config" test -f "$config"
    require "Failed to create WLAN module alias" cp -p "$dir/wmt_chrdev_wifi.ko" "$dir/$name"
    if ! grep -Fq "vendor_dlkm/lib/modules/$name " "$config"; then
        printf 'vendor_dlkm/lib/modules/%s 0 0 0644\n' "$name" >> "$config" ||
            abort "[!] Failed to update WLAN fs_config"
    fi
    ui_print "- [*] HyperOS WLAN fix applied"
}

confirm_hyperos() {
    local prompt

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
}

prepare_kernel() {
    ui_print " " "- [+] Starting kernel image flashing..."
    ui_print "- [*] Checking kernel image..."
    require "SHA256 mismatch" "$BIN/busybox" sha256sum -cs Image.zst.sha256
    ui_print "- [*] SHA256 OK"

    ui_print "- [*] Unpacking kernel image..."
    require "Failed to decompress kernel image" "$BIN/zstd" -d -q --no-progress \
        -o "$AKHOME/Image" "$AKHOME/Image.zst"
    ui_print "- [*] Kernel image unpacked"
}

prepare_modules() {
    local archive="$AKHOME/module.tar.xz"

    [ -f "$archive" ] || return 0
    ui_print " " "- [+] Unpacking module package..."
    require "Failed to prepare module directory" reset_dir "$module_extract_dir"
    require "Failed to extract module.tar.xz" busybox tar -xpf "$archive" -C "$module_extract_dir"
    if [ "$is_hyperos" = true ] && [ -d "$module_extract_dir/vendor_dlkm" ]; then
        fix_hyperos_wlan
    fi
}

install_boot() {
    ui_print "- [+] Flashing kernel image..."
    split_boot
    if [ -f "$SPLITIMG/ramdisk.cpio" ]; then
        unpack_ramdisk
        write_boot
    else
        flash_boot
    fi
    require "Failed to remove extracted Image" rm -f "$AKHOME/Image"
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

    [ -f "$archive" ] || abort "[!] Vendor ramdisk not found"
    ui_print " " "- [+] Starting vendor_ramdisk modules update..."
    require "Failed to prepare vendor ramdisk directory" reset_dir "$work"

    ui_print "- [*] Unpacking ramdisk..."
    (
        cd "$work" &&
            "$BIN/busybox" cpio -i -d <"$archive"
    ) || abort "[!] Failed to unpack ramdisk.cpio"

    ui_print "- [*] Updating ramdisk.cpio modules..."
    require "Failed to replace vendor_boot modules" \
        replace_modules "$module_extract_dir/vendor_boot/lib/modules" "$work/lib/modules"

    ui_print "- [*] Repacking ramdisk.cpio..."
    (
        cd "$work" &&
            busybox find . | busybox cpio -o -H newc >"$archive" 2>/dev/null
    ) || abort "[!] Failed to repack ramdisk.cpio"

    require "Failed to remove vendor ramdisk directory" rm -rf "$work"
}

install_vendor_boot() {
    BLOCK=vendor_boot
    IS_SLOT_DEVICE=1
    RAMDISK_COMPRESSION=auto
    PATCH_VBMETA_FLAG=auto
    reset_ak
    split_boot

    if [ -d "$module_extract_dir/vendor_boot" ]; then
        update_vendor_ramdisk
    fi

    ui_print "- [+] Flashing new vendor_boot image..."
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
            -z lz4 -b 4096 -C 262144 -T 1230768000 \
            "$image" "$work/vendor_dlkm"
}

install_vendor_dlkm() {
    local work="$AKHOME/_extract_vendor_dlkm"
    local image="$AKHOME/vendor_dlkm.img"
    local partition block_size image_size

    [ -d "$module_extract_dir/vendor_dlkm" ] || return 0
    reset_ak
    partition="/dev/block/mapper/vendor_dlkm${SLOT}"

    ui_print " " "$partition"
    ui_print " " "- [+] Starting /vendor_dlkm modules update..."
    ui_print "- [*] Pulling /vendor_dlkm image from current slot (${SLOT})..."
    require "Failed to pull vendor_dlkm${SLOT}.img" dd if="$partition" of="$image" bs=1048576

    ui_print "- [*] Unpacking /vendor_dlkm image..."
    require "Failed to prepare vendor_dlkm directory" reset_dir "$work"
    "$BIN/extract.erofs" -i "$image" -x -T8 -o "$work" >/dev/null 2>&1 ||
        abort "[!] Failed to unpack the vendor_dlkm image"

    ui_print "- [*] Updating /vendor_dlkm modules..."
    require "Failed to replace vendor_dlkm modules" \
        replace_modules "$module_extract_dir/vendor_dlkm/lib/modules" "$work/vendor_dlkm/lib/modules"
    require "Failed to merge vendor_dlkm module metadata" merge_module_metadata "$work/config"

    ui_print "- [*] Repacking /vendor_dlkm image..."
    require "Failed to repack the vendor_dlkm image" repack_vendor_dlkm "$work" "$image"
    require "Failed to remove vendor_dlkm working directory" rm -rf "$work"

    block_size=$(blockdev --getsize64 "$partition") ||
        abort "[!] Failed to get vendor_dlkm partition size"
    image_size=$(wc -c <"$image") || abort "[!] Failed to get vendor_dlkm image size"
    if [ "$image_size" -lt "$block_size" ]; then
        ui_print "- [*] Truncating to fill the erofs image file..."
        require "Failed to pad the vendor_dlkm image" truncate -c -s "$block_size" "$image"
    fi

    ui_print "- [+] Flashing new /vendor_dlkm image..."
    flash_generic vendor_dlkm
}

main() {
    local module_extract_dir="$AKHOME/_module"
    local is_hyperos

    confirm_hyperos
    prepare_kernel
    prepare_modules
    install_boot
    install_vendor_boot
    install_vendor_dlkm
    rm -rf "$module_extract_dir"
}

main
