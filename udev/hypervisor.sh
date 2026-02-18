#!/bin/bash
# Detect the active hypervisor (Xen or KVM) for Qubes OS.
# Used by udev rules, dracut modules, and other scripts to select
# the correct device paths and drivers.
#
# Output: "xen" or "kvm" or "unknown"
# Also sets QUBES_HYPERVISOR environment variable.
#
# Ref: QubesOS/qubes-issues#7051

QUBES_HOST_ARCH="$(uname -m)"

detect_hypervisor() {
    # Check for Xen first (most common for Qubes on x86)
    if [ -e /sys/hypervisor/type ]; then
        local hv_type
        hv_type=$(cat /sys/hypervisor/type 2>/dev/null)
        if [ "$hv_type" = "xen" ]; then
            echo "xen"
            return 0
        fi
    fi

    # ARM64: Check device tree for hypervisor info
    # KVM on ARM64 exposes hypervisor details via /sys/firmware/devicetree
    if [ "$QUBES_HOST_ARCH" = "aarch64" ]; then
        if [ -f /sys/firmware/devicetree/base/hypervisor/compatible ]; then
            local dt_compat
            dt_compat=$(cat /sys/firmware/devicetree/base/hypervisor/compatible 2>/dev/null | tr '\0' ' ')
            case "$dt_compat" in
                *kvm*)
                    echo "kvm"
                    return 0
                    ;;
                *xen*)
                    echo "xen"
                    return 0
                    ;;
            esac
        fi
    fi

    # Check for KVM via DMI (may not exist on ARM64)
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

    # Check for KVM via hypervisor cpuid leaf (x86 only)
    if [ -e /sys/hypervisor/type ] && \
       grep -q "KVM" /sys/hypervisor/type 2>/dev/null; then
        echo "kvm"
        return 0
    fi

    # Check for virtio devices as a KVM indicator (works on all arches)
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

    # Default: ARM64 defaults to kvm (no Xen), x86 returns unknown
    if [ "$QUBES_HOST_ARCH" = "aarch64" ]; then
        echo "kvm"
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
