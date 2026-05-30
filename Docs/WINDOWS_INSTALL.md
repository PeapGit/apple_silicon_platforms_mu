# Windows installation helper (ARM64)

This repository includes a helper script that prepares an EFI system partition and applies a Windows 10/11 ARM64 image from an ISO onto a target partition.

> **Warning**
> - This script is destructive when used with `--disk` (it will wipe the entire disk).
> - The firmware in this repository is still experimental. The Windows loader may still fail on handoff as noted in the project README.

## Dependencies

Install these tools on the Linux host running the script:

- `wimlib-imagex`
- `ntfs-3g` (for `mkfs.ntfs` and NTFS mounts)
- `dosfstools` (for `mkfs.fat`)
- `gptfdisk` (for `sgdisk` when using `--disk`)
- `efibootmgr` (optional, to create a boot entry automatically)

## Usage

### Wipe and partition a disk

```
sudo Scripts/windows-install.sh --iso /path/to/Win11_ARM64.iso --disk /dev/nvme0n1 --yes
```

### Use existing partitions

```
sudo Scripts/windows-install.sh --iso /path/to/Win11_ARM64.iso \
  --efi-part /dev/nvme0n1p1 --os-part /dev/nvme0n1p2
```

## Notes

- The script copies EFI boot files and creates `EFI/Boot/bootaa64.efi` as a fallback path.
- If Windows fails to boot, boot into WinPE and run:
  `bcdboot C:\\Windows /s S: /f UEFI`
  (Replace `S:` with the drive letter assigned to the EFI partition in WinPE.)
