# Ref: https://github.com/Pzqqt/AnyKernel3/blob/Marble-Bouquet/_rollback_anykernel.sh
properties() { '
kernel.string=Restore ESK partitions
do.devicecheck=0
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
'; }

BLOCK=boot
IS_SLOT_DEVICE=1
NO_BLOCK_DISPLAY=true
CUSTOMDD=bs=1048576
. tools/ak3-core.sh
unset NO_BLOCK_DISPLAY

original="$AKHOME/_orig"
if [ "$1" != rollback ]; then
    [ "$(cat "$original/slot")" = "$SLOT" ] || abort "[!] Switch to the slot from the restore ZIP."
    device=$(cat "$original/device")
    [ -n "$device" ] && [ "$device" = "$(getprop ro.product.device)" ] ||
        abort "[!] This restore ZIP belongs to a different device."
fi

failed=0
for partition in vendor_dlkm vendor_boot boot; do
    if [ "$1" = rollback ]; then
        [ -f "$original/$partition.writing" ] || continue
        target=$(cat "$original/$partition.writing")
    else
        [ -f "$original/$partition.img" ] || continue
        case "$partition" in
            boot) target="$BLOCK" ;;
            vendor_boot) target="${BLOCK%/*}/vendor_boot$SLOT" ;;
            vendor_dlkm) target="/dev/block/mapper/vendor_dlkm$SLOT" ;;
        esac
    fi

    ui_print "- Restoring $partition$SLOT"
    (
        [ -n "$target" ] &&
            ln -f "$original/$partition.img" "$AKHOME/$partition.img" &&
            rm -f "$AKHOME/${partition}_flashed" &&
            flash_generic "$partition" "$target"
    ) || failed=1
done
sync
exit "$failed"
