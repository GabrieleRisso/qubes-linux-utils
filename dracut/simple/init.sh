#!/bin/sh
echo "Qubes initramfs script here:"

mkdir -p /proc /sys /dev
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

# Detect hypervisor and set device paths
if [ -w /sys/devices/system/xen_memory/xen_memory0/scrub_pages ]; then
    # re-enable xen-balloon pages scrubbing, after initial balloon down
    echo 1 > /sys/devices/system/xen_memory/xen_memory0/scrub_pages
    QUBES_HV=xen
elif [ -e /sys/hypervisor/type ] && \
     [ "$(cat /sys/hypervisor/type 2>/dev/null)" = "xen" ]; then
    QUBES_HV=xen
elif [ -n "$(ls -A /sys/bus/virtio/devices/ 2>/dev/null)" ]; then
    QUBES_HV=kvm
else
    QUBES_HV=xen
fi

case "$QUBES_HV" in
    xen)
        ROOT_BLK=xvda
        PRIV_BLK=xvdb
        VOLATILE_BLK=xvdc
        MODULES_BLK=xvdd
        /sbin/modprobe xenblk || /sbin/modprobe xen-blkfront || \
            echo "Qubes: Cannot load Xen Block Frontend..."
        ;;
    kvm)
        ROOT_BLK=vda
        PRIV_BLK=vdb
        VOLATILE_BLK=vdc
        MODULES_BLK=vdd
        /sbin/modprobe virtio_blk || \
            echo "Qubes: Cannot load virtio_blk..."
        /sbin/modprobe virtio_pci 2>/dev/null
        ;;
esac

# If device-mapper is built-in then Linux creates /dev/mapper,
# but if it is a module then this script must do that.
if [ ! -d /dev/mapper ]; then
    mkdir -m 0755 /dev/mapper
elif [ -e /dev/mapper/dmroot ]; then
    echo "Qubes: FATAL error: /dev/mapper/dmroot already exists?!" >&2
fi

die() {
    echo "$@" >&2
    exit 1
}

echo "Waiting for /dev/$ROOT_BLK* devices..."
while ! [ -e "/dev/$ROOT_BLK" ]; do sleep 0.1; done
# Fix up partition tables
if /usr/sbin/gptfix fix "/dev/$ROOT_BLK"; then
    while ! [ -e "/dev/${ROOT_BLK}1" ]; do sleep 0.01; done
    if [ -d /dev/disk/by-partlabel ]; then
        ROOT_DEV=$(readlink "/dev/disk/by-partlabel/Root\\x20filesystem")
        ROOT_DEV=${ROOT_DEV##*/}
    else
        ROOT_DEV=$(grep -l "PARTNAME=Root filesystem" /sys/block/$ROOT_BLK/${ROOT_BLK}*/uevent |
            grep -o "${ROOT_BLK}[0-9]")
    fi
    if [ -z "$ROOT_DEV" ]; then
        # fallback to third partition
        ROOT_DEV=${ROOT_BLK}3
    fi
    while ! [ -b "/dev/$ROOT_DEV" ]; do sleep 0.01; done
else
    case $? in
    (1|2) # EIO, ENOMEM, or bug.  Fatal.
        die 'Fatal error reading partition table';;
    (4|5|8) # Bad or no partition table
        ROOT_DEV=$ROOT_BLK;;
    (*)
        # TODO: what should be done?
        # - "Partition table not supported"
        # - "Disk truncated"
        die 'GPT cannot be fixed or disk truncated';;
    esac
fi

SWAP_SIZE_GiB=1
SWAP_SIZE_512B=$(( SWAP_SIZE_GiB * 1024 * 1024 * 2 ))

if [ `cat /sys/class/block/$ROOT_DEV/ro` = 1 ] ; then
    echo "Qubes: Doing COW setup for AppVM..."

    while ! [ -e "/dev/$VOLATILE_BLK" ]; do sleep 0.1; done
    VOLATILE_SIZE_512B=$(cat /sys/class/block/$VOLATILE_BLK/size)
    if [ $VOLATILE_SIZE_512B -lt $SWAP_SIZE_512B ]; then
        die "volatile.img smaller than $SWAP_SIZE_GiB GiB, cannot continue"
    fi
    /sbin/sfdisk -q "/dev/$VOLATILE_BLK" >/dev/null <<EOF
${VOLATILE_BLK}1: type=82,start=1MiB,size=${SWAP_SIZE_GiB}GiB
${VOLATILE_BLK}2: type=83
EOF
    if [ $? -ne 0 ]; then
        echo "Qubes: failed to setup partitions on volatile device"
        exit 1
    fi
    while ! [ -e "/dev/${VOLATILE_BLK}1" ]; do sleep 0.1; done
    /sbin/mkswap "/dev/${VOLATILE_BLK}1"
    while ! [ -e "/dev/${VOLATILE_BLK}2" ]; do sleep 0.1; done

    echo "0 `cat /sys/class/block/$ROOT_DEV/size` snapshot /dev/$ROOT_DEV /dev/${VOLATILE_BLK}2 N 16" | \
        /sbin/dmsetup create dmroot || { echo "Qubes: FATAL: cannot create dmroot!"; exit 1; }
    /sbin/dmsetup mknodes dmroot
    echo Qubes: done.
else
    echo "Qubes: Doing R/W setup for TemplateVM..."
    while ! [ -e "/dev/$VOLATILE_BLK" ]; do sleep 0.1; done
    /sbin/sfdisk -q "/dev/$VOLATILE_BLK" >/dev/null <<EOF
${VOLATILE_BLK}1: type=82,start=1MiB,size=${SWAP_SIZE_GiB}GiB
${VOLATILE_BLK}3: type=83
EOF
    if [ $? -ne 0 ]; then
        die "Qubes: failed to setup partitions on volatile device"
    fi
    while ! [ -e "/dev/${VOLATILE_BLK}1" ]; do sleep 0.1; done
    /sbin/mkswap "/dev/${VOLATILE_BLK}1"
    ln -s ../$ROOT_DEV /dev/mapper/dmroot
    echo Qubes: done.
fi

/sbin/modprobe ext4

mkdir -p /sysroot
mount /dev/mapper/dmroot /sysroot -o rw
NEWROOT=/sysroot

kver="`uname -r`"
if ! [ -d "$NEWROOT/lib/modules/$kver/kernel" ]; then
    echo "Waiting for /dev/$MODULES_BLK device..."
    while ! [ -e "/dev/$MODULES_BLK" ]; do sleep 0.1; done

    mkdir -p /tmp/modules
    mount -n -t ext3 "/dev/$MODULES_BLK" /tmp/modules
    if /sbin/modprobe overlay; then
        # if overlayfs is supported, use that to provide fully writable /lib/modules
        if ! [ -d "$NEWROOT/lib/.modules_work" ]; then
            mkdir -p "$NEWROOT/lib/.modules_work"
        fi
        mount -t overlay none "$NEWROOT/lib/modules" -o "lowerdir=/tmp/modules,upperdir=$NEWROOT/lib/modules,workdir=$NEWROOT/lib/.modules_work"
    else
        # otherwise mount only `uname -r` subdirectory, to leave the rest of
        # /lib/modules writable
        if ! [ -d "$NEWROOT/lib/modules/$kver" ]; then
            mkdir -p "$NEWROOT/lib/modules/$kver"
        fi
        mount --bind "/tmp/modules/$kver" "$NEWROOT/lib/modules/$kver"
    fi
    umount /tmp/modules
    rmdir /tmp/modules
fi

umount /dev /sys /proc
mount "$NEWROOT" -o remount,ro

exec /sbin/switch_root $NEWROOT /sbin/init
