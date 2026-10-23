### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers
## cyberknight777 @ xda-developers
## bachnxuan @ esk-project

### AnyKernel setup
# global properties
properties() { '
kernel.string=ESK ACK 6.12 for xaga by bachnxuan @ esk-project
do.devicecheck=1
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=xaga
device.name2=xagain
device.name3=xagapro
device.name4=xagaproin
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

find_partition() {
  local path file;
  for path in /dev/block/mapper /dev/block/by-name /dev/block/bootdevice/by-name; do
    for file in "$1$SLOT" "$1"; do
      if [ -e "$path/$file" ]; then
        echo "$path/$file";
        return 0;
      fi;
    done;
  done;
  return 1;
}

write_image() {
  blockdev --setrw "$2" 2>/dev/null || abort "Cannot make partition writable: $2";
  dd if="$1" of="$2" bs=1048576 conv=fsync || abort "Flashing image failed: $2";
}

reset_dir() {
    rm -rf "$1" || abort "[!] Failed to reset $1"
    mkdir -p "$1" || abort "[!] Failed to create $1"
}

step_begin() {
    local rest
    ak3_step_label=$1
    read -r ak3_step_started rest < /proc/uptime
    ak3_step_started=${ak3_step_started%%.*}
    ui_print "- [*] $ak3_step_label..."
}

step_end() {
    local now rest
    read -r now rest < /proc/uptime
    ui_print "- [timing] $ak3_step_label: $((${now%%.*} - ak3_step_started))s"
}

update_vendor_modules() (
    archive=$1
    cd "$module_extract_dir/vendor_boot" || abort "[!] Missing vendor_boot payload"
    entries="$AKHOME/_vendor_module_entries"
    "$BIN/busybox" cpio -t < "$archive" > "$entries" ||
        abort "[!] Failed to list vendor ramdisk modules"
    set --
    while IFS= read -r entry; do
        case "$entry" in
            lib/modules|lib/modules/*|./lib/modules|./lib/modules/*)
                set -- "$@" "rm ${entry#./}"
                ;;
        esac
    done < "$entries"
    rm -f "$entries"
    set -- "$@" "mkdir 0755 lib/modules"
    for module in lib/modules/*; do
        [ -f "$module" ] || abort "[!] Missing vendor_boot module files"
        set -- "$@" "add 0644 $module $module"
    done
    "$BIN/magiskboot" cpio "$archive" "$@" || abort "[!] Failed to update vendor ramdisk modules"
)

module_archive="$AKHOME/module.tar.xz"
module_extract_dir="$AKHOME/_module"
prepared_dir="$AKHOME/_prepared"
reset_dir "$prepared_dir"

[ -s "$AKHOME/dt/dtb" ] && [ -s "$AKHOME/dt/dtbo.img" ] || abort "[!] Missing 6.12 device trees"
step_begin "module archive extraction"
reset_dir "$module_extract_dir"
"$BIN/busybox" tar -xpf "$module_archive" -C "$module_extract_dir" ||
    abort "[!] Failed to extract module.tar.xz"
step_end

step_begin "kernel decompression"
"$BIN/zstd" -d -q --no-progress -o "$AKHOME/Image" "$AKHOME/Image.zst" ||
    abort "[!] Failed to decompress kernel image"
step_end
step_begin "kernel gzip compression"
"$BIN/magiskboot" compress=gzip "$AKHOME/Image" "$AKHOME/Image.gz" ||
    abort "[!] Failed to compress 6.12 kernel"
step_end
rm -f "$AKHOME/Image" || abort "[!] Failed to remove raw kernel"
ui_print "- [*] Kernel image unpacked"

ui_print "- [+] Preparing kernel image..."
# boot install
step_begin "boot read and unpack"
split_boot
step_end
patch_cmdline "clk_ignore_unused" "clk_ignore_unused"

if [ -f "$SPLITIMG/ramdisk.cpio" ]; then
    step_begin "boot ramdisk repack"
    unpack_ramdisk
    repack_ramdisk
    step_end
fi
step_begin "boot image repack"
repack_boot
step_end
mv -f "$AKHOME/boot-new.img" "$prepared_dir/boot.img" || abort "[!] Failed to stage boot"
boot_block=$BLOCK
## end boot install

rm -f "$AKHOME/Image.gz" || abort "[!] Failed to remove extracted Image.gz"

# vendor_boot shell variables
BLOCK=vendor_boot
IS_SLOT_DEVICE=1
RAMDISK_COMPRESSION=auto
PATCH_VBMETA_FLAG=auto

# reset for vendor_boot patching
reset_ak

# vendor_boot install
step_begin "vendor_boot read and unpack"
split_boot
step_end

[ -f "$SPLITIMG/dtb" ] || abort "[!] Unsupported vendor_boot DTB layout"
cp -f "$AKHOME/dt/dtb" "$SPLITIMG/dtb" || abort "[!] Failed to stage DTB"

updated=0
for ramdisk in "$SPLITIMG"/vendor_ramdisk/*.cpio; do
    [ -f "$ramdisk" ] || continue
    "$BIN/magiskboot" cpio "$ramdisk" "exists lib/modules" || continue
    step_begin "vendor_boot modules ($(basename "$ramdisk"))"
    update_vendor_modules "$ramdisk" || abort "[!] Failed to update vendor ramdisk modules"
    step_end
    step_begin "vendor_boot LZ4 compression ($(basename "$ramdisk"))"
    "$BIN/magiskboot" compress=lz4_legacy "$ramdisk" "$ramdisk.lz4" ||
        abort "[!] Failed to compress vendor ramdisk"
    mv -f "$ramdisk.lz4" "$ramdisk" || abort "[!] Failed to stage vendor ramdisk"
    step_end
    updated=$((updated + 1))
done
[ "$updated" -gt 0 ] || abort "[!] No supported vendor ramdisk with lib/modules"

step_begin "vendor_boot image repack"
repack_boot
step_end
mv -f "$AKHOME/boot-new.img" "$prepared_dir/vendor_boot.img" || abort "[!] Failed to stage vendor_boot"
vendor_boot_block=$BLOCK
## end vendor_boot install

## vendor_dlkm install
# reset for vendor_dlkm patching
reset_ak

ui_print " " "/dev/block/mapper/vendor_dlkm${SLOT}"
ui_print " " "- [+] Starting /vendor_dlkm modules update..."

step_begin "vendor_dlkm read"
vendor_dlkm_block=$(find_partition vendor_dlkm) || abort "[!] Missing vendor_dlkm partition"
dd if="$vendor_dlkm_block" of="${AKHOME}"/vendor_dlkm.img ||
    abort "[!] Failed to pull vendor_dlkm${SLOT}.img"
step_end
extract_vendor_dlkm_dir=${AKHOME}/_extract_vendor_dlkm
reset_dir "$extract_vendor_dlkm_dir"

step_begin "vendor_dlkm extraction"
"${BIN}"/extract.erofs -i "${AKHOME}"/vendor_dlkm.img -x -T8 -o "${extract_vendor_dlkm_dir}" >/dev/null 2>&1 ||
    abort "[!] Failed to unpack the vendor_dlkm image"
step_end
step_begin "filesystem sync"
sync
step_end

step_begin "vendor_dlkm module replacement"
extract_vendor_dlkm_modules_dir=${extract_vendor_dlkm_dir}/vendor_dlkm/lib/modules
rm -f "${extract_vendor_dlkm_modules_dir}"/* ||
    abort "[!] Failed to remove pre-existing files in ${extract_vendor_dlkm_modules_dir}"
rm -f "${extract_vendor_dlkm_dir}"/config/vendor_dlkm_fs_config "${extract_vendor_dlkm_dir}"/config/vendor_dlkm_file_contexts ||
    abort "[!] Failed to remove pre-existing fs_config and file_contexts in ${extract_vendor_dlkm_dir}/config"
cp -a "$module_extract_dir/vendor_dlkm/lib/modules/." "${extract_vendor_dlkm_modules_dir}/" ||
    abort "[!] Failed to copy vendor_dlkm modules"
mv "${AKHOME}"/config/vendor_dlkm* "${extract_vendor_dlkm_dir}"/config/ ||
    abort "[!] Failed to move fs_config and file_contexts to ${extract_vendor_dlkm_dir}/config"

step_end
step_begin "vendor_dlkm EROFS generation"
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
step_end
rm -rf "${extract_vendor_dlkm_dir}" ||
    abort "[!] Failed to remove working directory"
unset extract_vendor_dlkm_dir extract_vendor_dlkm_modules_dir

mv -f "$AKHOME/vendor_dlkm.img" "$prepared_dir/vendor_dlkm.img" ||
    abort "[!] Failed to stage vendor_dlkm"

rm -rf "$module_extract_dir"
## end vendor_dlkm install

step_begin "image preparation"
cp -f "$AKHOME/dt/dtbo.img" "$prepared_dir/dtbo.img" || abort "[!] Failed to stage DTBO"
dtbo_block=$(find_partition dtbo) || abort "[!] Missing dtbo partition"
for image in "$prepared_dir"/*.img; do
    [ -s "$image" ] || abort "[!] Missing image: $image"
done

step_end

mv -f "$prepared_dir/vendor_dlkm.img" "$AKHOME/vendor_dlkm.img" || abort "[!] Failed to stage vendor_dlkm"
mv -f "$prepared_dir/dtbo.img" "$AKHOME/dtbo.img" || abort "[!] Failed to stage DTBO"
ui_print "- [+] Flashing prepared images..."
step_begin "boot write and flush"
write_image "$prepared_dir/boot.img" "$boot_block"
step_end
step_begin "vendor_boot write and flush"
write_image "$prepared_dir/vendor_boot.img" "$vendor_boot_block"
step_end
step_begin "vendor_dlkm write and flush"
write_image "$AKHOME/vendor_dlkm.img" "$vendor_dlkm_block"
step_end
step_begin "dtbo write and flush"
write_image "$AKHOME/dtbo.img" "$dtbo_block"
step_end
