#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME=$(basename "$0")

usage() {
  cat <<USAGE
Usage: $SCRIPT_NAME --iso <path> [--disk <device> | --efi-part <device> --os-part <device>]
                   [--efi-size <size>] [--index <wim-index>]
                   [--efi-label <label>] [--os-label <label>]
                   [--no-format] [--skip-efibootmgr] [--yes]

Required:
  --iso <path>           Path to Windows 10/11 ARM64 ISO

Partition selection (choose one):
  --disk <device>        Wipe and partition a disk (creates EFI + Windows partitions)
  --efi-part <device>    Existing EFI system partition
  --os-part <device>     Existing Windows partition

Optional:
  --efi-size <size>      EFI partition size when using --disk (default: 512M)
  --index <wim-index>    WIM/ESD image index to apply (default: 1)
  --efi-label <label>    Filesystem label for EFI (default: EFI)
  --os-label <label>     Filesystem label for Windows (default: Windows)
  --no-format            Skip formatting partitions (use with existing partitions)
  --skip-efibootmgr      Do not create a UEFI boot entry
  --yes                  Skip destructive-operation prompt when using --disk
USAGE
}

die() {
  echo "error: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

partition_path() {
  local device_path="$1"
  local partition_number="$2"
  local suffix=""

  if [[ "$device_path" =~ [0-9]$ ]]; then
    suffix="p"
  fi

  echo "${device_path}${suffix}${partition_number}"
}

confirm_disk_wipe() {
  local disk="$1"

  if [[ "$YES" -eq 1 ]]; then
    return 0
  fi

  read -r -p "WARNING: This will PERMANENTLY ERASE all data on ${disk}. Continue? [y/N]: " reply
  case "$reply" in
    [yY]) return 0 ;;
    *) exit 1 ;;
  esac
}

resolve_disk_from_part() {
  local part="$1"
  local device_name

  device_name=$(lsblk -no PKNAME "$part" | head -n 1)
  [[ -n "$device_name" ]] || return 1
  echo "/dev/${device_name}"
}

resolve_partnum() {
  local part="$1"
  lsblk -no PARTNUM "$part" | head -n 1
}

ISO=""
DISK=""
EFI_PART=""
OS_PART=""
EFI_SIZE="512M"
INDEX="1"
EFI_LABEL="EFI"
OS_LABEL="Windows"
FORMAT=1
SKIP_EFIBOOTMGR=0
YES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iso)
      ISO="$2"
      shift 2
      ;;
    --disk)
      DISK="$2"
      shift 2
      ;;
    --efi-part)
      EFI_PART="$2"
      shift 2
      ;;
    --os-part)
      OS_PART="$2"
      shift 2
      ;;
    --efi-size)
      EFI_SIZE="$2"
      shift 2
      ;;
    --index)
      INDEX="$2"
      shift 2
      ;;
    --efi-label)
      EFI_LABEL="$2"
      shift 2
      ;;
    --os-label)
      OS_LABEL="$2"
      shift 2
      ;;
    --no-format)
      FORMAT=0
      shift
      ;;
    --skip-efibootmgr)
      SKIP_EFIBOOTMGR=1
      shift
      ;;
    --yes)
      YES=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

[[ -n "$ISO" ]] || { usage; die "--iso is required"; }
[[ -f "$ISO" ]] || die "ISO not found: $ISO"

if [[ -n "$DISK" ]]; then
  [[ -b "$DISK" ]] || die "Disk not found: $DISK"
  [[ -z "$EFI_PART" && -z "$OS_PART" ]] || die "Use either --disk or --efi-part/--os-part, not both"
else
  [[ -n "$EFI_PART" && -n "$OS_PART" ]] || die "Provide --disk or both --efi-part and --os-part"
  [[ -b "$EFI_PART" ]] || die "EFI partition not found: $EFI_PART"
  [[ -b "$OS_PART" ]] || die "Windows partition not found: $OS_PART"
fi

[[ $EUID -eq 0 ]] || die "This script must be run as root (use sudo)"

require_cmd lsblk
require_cmd mount
require_cmd umount
require_cmd mktemp
require_cmd wimlib-imagex
require_cmd mkfs.fat
require_cmd mkfs.ntfs
require_cmd mountpoint
require_cmd partprobe
NTFS_MOUNT_TYPE=""
if command -v ntfs-3g >/dev/null 2>&1; then
  NTFS_MOUNT_TYPE="ntfs-3g"
elif command -v mount.ntfs >/dev/null 2>&1; then
  NTFS_MOUNT_TYPE="ntfs"
else
  die "Missing NTFS mount helper (install ntfs-3g, which provides ntfs-3g and mount.ntfs)"
fi

if [[ -n "$DISK" ]]; then
  require_cmd sgdisk
  confirm_disk_wipe "$DISK"
  sgdisk --zap-all "$DISK"
  sgdisk -n 1:0:+"${EFI_SIZE}" -t 1:EF00 -c 1:"EFI System Partition" "$DISK"
  sgdisk -n 2:0:0 -t 2:0700 -c 2:"Windows" "$DISK"
  partprobe "$DISK"
  EFI_PART=$(partition_path "$DISK" 1)
  OS_PART=$(partition_path "$DISK" 2)
  FORMAT=1
fi

ISO_MNT=$(mktemp -d -t windows-iso.XXXXXX)
WIN_MNT=$(mktemp -d -t windows-os.XXXXXX)
EFI_MNT=$(mktemp -d -t windows-efi.XXXXXX)

cleanup() {
  set +e
  mountpoint -q "$EFI_MNT" && umount "$EFI_MNT"
  mountpoint -q "$WIN_MNT" && umount "$WIN_MNT"
  mountpoint -q "$ISO_MNT" && umount "$ISO_MNT"
  rmdir "$EFI_MNT" "$WIN_MNT" "$ISO_MNT" 2>/dev/null || true
}
trap cleanup EXIT

mount -o loop,ro "$ISO" "$ISO_MNT"

WIM_PATH=""
if [[ -f "$ISO_MNT/sources/install.wim" ]]; then
  WIM_PATH="$ISO_MNT/sources/install.wim"
elif [[ -f "$ISO_MNT/sources/install.esd" ]]; then
  WIM_PATH="$ISO_MNT/sources/install.esd"
else
  die "Could not find install.wim or install.esd in ISO"
fi

if [[ $FORMAT -eq 1 ]]; then
  mkfs.fat -F 32 -n "$EFI_LABEL" "$EFI_PART" || die "Failed to format EFI partition: $EFI_PART"
  mkfs.ntfs -f -L "$OS_LABEL" "$OS_PART" || die "Failed to format Windows partition: $OS_PART"
fi

mount -t "$NTFS_MOUNT_TYPE" "$OS_PART" "$WIN_MNT" || die "Failed to mount Windows partition: $OS_PART"

wimlib-imagex apply "$WIM_PATH" "$INDEX" "$WIN_MNT" || die "Failed to apply Windows image from $WIM_PATH"

mount "$EFI_PART" "$EFI_MNT" || die "Failed to mount EFI partition: $EFI_PART"
mkdir -p "$EFI_MNT/EFI/Microsoft/Boot" "$EFI_MNT/EFI/Boot"

if [[ -d "$WIN_MNT/Windows/Boot/EFI" ]]; then
  cp -a "$WIN_MNT/Windows/Boot/EFI/." "$EFI_MNT/EFI/Microsoft/Boot/"
elif [[ -d "$ISO_MNT/efi/microsoft/boot" ]]; then
  cp -a "$ISO_MNT/efi/microsoft/boot/." "$EFI_MNT/EFI/Microsoft/Boot/"
else
  die "Could not locate EFI boot files in applied image or ISO"
fi

if [[ -f "$EFI_MNT/EFI/Microsoft/Boot/bootmgfw.efi" ]]; then
  cp -a "$EFI_MNT/EFI/Microsoft/Boot/bootmgfw.efi" "$EFI_MNT/EFI/Boot/bootaa64.efi"
elif [[ -f "$ISO_MNT/efi/boot/bootaa64.efi" ]]; then
  cp -a "$ISO_MNT/efi/boot/bootaa64.efi" "$EFI_MNT/EFI/Boot/bootaa64.efi"
else
  die "Could not locate bootmgfw.efi or bootaa64.efi"
fi

sync

if [[ $SKIP_EFIBOOTMGR -eq 0 ]]; then
  if command -v efibootmgr >/dev/null 2>&1; then
    EFI_DISK="$DISK"
    EFI_PARTNUM=""

    if [[ -z "$EFI_DISK" ]]; then
      EFI_DISK=$(resolve_disk_from_part "$EFI_PART" || true)
    fi
    EFI_PARTNUM=$(resolve_partnum "$EFI_PART" || true)
    if [[ -z "$EFI_PARTNUM" && -n "$DISK" ]]; then
      EFI_PARTNUM="1"
    fi

    if [[ -n "$EFI_DISK" && -n "$EFI_PARTNUM" ]]; then
      if ! efibootmgr -c -d "$EFI_DISK" -p "$EFI_PARTNUM" -L "Windows Boot Manager" \
        -l '\\EFI\\Microsoft\\Boot\\bootmgfw.efi'; then
        echo "warning: efibootmgr failed to create a boot entry. Ensure efivars are mounted and the firmware allows NVRAM writes." >&2
      fi
    else
      echo "warning: Unable to determine disk/partition number from $EFI_PART for efibootmgr; skipping" >&2
    fi
  else
    echo "warning: efibootmgr not found; skipping boot entry creation" >&2
  fi
fi

echo "Windows image applied to $OS_PART and EFI files installed to $EFI_PART."
echo "If Windows fails to boot, boot into WinPE, identify the Windows and EFI drive letters,"
echo "then run: bcdboot <WindowsDrive>:\Windows /s <EfiDrive>: /f UEFI"
echo "Replace <WindowsDrive> and <EfiDrive> with the drive letters assigned in WinPE."
