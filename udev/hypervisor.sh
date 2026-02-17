#!/bin/bash
# Detect the active hypervisor (Xen or KVM) for Qubes OS.
# Used by udev rules, dracut modules, and other scripts to select
# the correct device paths and drivers.
#
# Output: "xen" or "kvm" or "unknown"
# Also sets QUBES_HYPERVISOR environment variable.
#
# Ref: QubesOS/qubes-issues#7051

detect_hypervisor() {
    # Check for Xen first (most common for Qubes)
    if [ -e /sys/hypervisor/type ]; then
        local hv_type
        hv_type=$(cat /sys/hypervisor/type 2>/dev/null)
        if [ "$hv_type" = "xen" ]; then
            echo "xen"
            return 0
        fi
    fi

    # Check for KVM via cpuid
    if [ -e /sys/devices/virtual/dmi/id/sys_vendor ]; then
        local vendor
        vendor=$(cat /sys/devices/virtual/dmi/id/sys_vendor 2>/dev/null)
        case "$vendor" in
            QEMU|"Red Hat"|"Amazon EC2")
                echo "kvm"
                return 0
                ;;
        esac
    fi

    # Check for KVM via hypervisor cpuid leaf
    if [ -e /sys/hypervisor/type ] && \
       grep -q "KVM" /sys/hypervisor/type 2>/dev/null; then
        echo "kvm"
        return 0
    fi

    # Check for virtio devices as a KVM indicator
    if ls /sys/bus/virtio/devices/ >/dev/null 2>&1; then
        if [ -n "$(ls -A /sys/bus/virtio/devices/ 2>/dev/null)" ]; then
            echo "kvm"
            return 0
        fi
    fi

    # Check for Xen bus as fallback
    if [ -e /sys/bus/xen ]; then
        echo "xen"
        return 0
    fi

    echo "unknown"
    return 1
}

# Device path helpers for hypervisor-agnostic scripts
get_root_dev() {
    local hv
    hv=$(detect_hypervisor)
    case "$hv" in
        xen) echo "/dev/xvda" ;;
        kvm) echo "/dev/vda" ;;
        *)   echo "/dev/sda" ;;
    esac
}

get_private_dev() {
    local hv
    hv=$(detect_hypervisor)
    case "$hv" in
        xen) echo "/dev/xvdb" ;;
        kvm) echo "/dev/vdb" ;;
        *)   echo "/dev/sdb" ;;
    esac
}

get_volatile_dev() {
    local hv
    hv=$(detect_hypervisor)
    case "$hv" in
        xen) echo "/dev/xvdc" ;;
        kvm) echo "/dev/vdc" ;;
        *)   echo "/dev/sdc" ;;
    esac
}

get_kernel_dev() {
    local hv
    hv=$(detect_hypervisor)
    case "$hv" in
        xen) echo "/dev/xvdd" ;;
        kvm) echo "/dev/vdd" ;;
        *)   echo "/dev/sdd" ;;
    esac
}

get_blkfront_module() {
    local hv
    hv=$(detect_hypervisor)
    case "$hv" in
        xen) echo "xen-blkfront" ;;
        kvm) echo "virtio_blk" ;;
        *)   echo "virtio_blk" ;;
    esac
}

get_netfront_module() {
    local hv
    hv=$(detect_hypervisor)
    case "$hv" in
        xen) echo "xen-netfront" ;;
        kvm) echo "virtio_net" ;;
        *)   echo "virtio_net" ;;
    esac
}

# When sourced, export the hypervisor type
if [ -z "$QUBES_HYPERVISOR" ]; then
    QUBES_HYPERVISOR=$(detect_hypervisor)
    export QUBES_HYPERVISOR
fi
