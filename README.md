# Fedora Linux Installer

A two-part Bash installer that bootstraps Fedora from any Linux live environment (Arch, Debian, Ubuntu, Fedora, etc.).

## Overview

This is a **Gentoo-style bootstrap installer** for Fedora Linux. It can be executed from any Linux live ISO and will:

- Create and format disk partitions (UEFI/systemd-boot compatible)
- Bootstrap Fedora using `dnf5` from the live environment
- Configure SELinux in permissive mode (automatic relabeling on first boot)
- Install either a **text-mode server** or **full KDE Plasma desktop** environment
- Set up GRUB bootloader with Secure Boot compatibility
- Create a user account with sudo privileges

## Prerequisites

### Live Environment Requirements

Should work on Arch Linux, Fedora, Ubuntu, Debian live environments.

The installer will obtain `dnf5` and other required tools depending on your live distro.

### Hardware Requirements

- UEFI firmware (BIOS mode not currently supported)
- At least 20 GiB of disk space (more for desktop)
- 2+ CPU cores recommended
- Internet connectivity during installation

### Partitions Required

The installer expects **three pre-existing partitions**:

1. **EFI partition** (500 MiB–1 GiB, FAT32): `1-1`
2. **Swap partition** (optional, but recommended): `1-2` 
3. **Root partition** (remaining space, ext4 or xfs): `1-3`

**Important:** Create these partitions before running the installer.

### Creating Partitions with `diskviz`

`diskviz` is a C-based interactive disk partition visualiser that makes partitioning intuitive and safe.

**Pre-installed on Arch Linux live CD:**

If you're booting from [georgeabr/arch-iso](https://github.com/georgeabr/arch-iso), `diskviz` is already available:

```bash
# Run the interactive partition visualiser
sudo diskviz /dev/nvme0n1   # (or /dev/sda, /dev/vda, etc.)
```

**Compiling from source (for other live environments):**

See the [diskviz repository](https://github.com/georgeabr/systems-programming/tree/main/diskviz) for compilation instructions and source code.

**Creating partitions in diskviz:**

1. Start `diskviz` pointing to your target disk
2. Create EFI partition: Select free space → New → 512 MiB → Type: EFI System
3. Create Swap partition: Select free space → New → (e.g., 8 GiB) → Type: Linux Swap
4. Create Root partition: Select remaining free space → New → Type: Linux Filesystem
5. Exit and write changes

Then proceed to running `fedora.sh`.

### Alternative: Using `fdisk` or `parted`

If `diskviz` is not available, use traditional tools:

```bash
# Using fdisk (interactive)
sudo fdisk /dev/nvme0n1

# Using parted (command-line)
sudo parted /dev/nvme0n1
```

## How It Works

### Part 1: `fedora.sh` (Run from Live Environment)

Executed on the live ISO, this script:

1. Validates partitions and checks internet connectivity
2. Detects current Fedora release version
3. Creates `/etc/yum.repos.d/` with Fedora repo metalinks in the target (`/mnt`)
4. Runs `dnf5 install --installroot=/mnt` with:
   - `@core` package group
   - Linux kernel and firmware
   - SELinux policy packages
   - GRUB and systemd-boot components
5. Generates `/etc/fstab` with partition UUIDs
6. Mounts `/dev`, `/proc`, `/sys`, `/run`, `/sys/firmware/efi/efivars` into chroot
7. Downloads Part 2 script from GitHub (with cache-busting headers)
8. Executes `fedora-2.sh` inside the chroot
9. Cleans up mounts and confirms successful installation

**Usage:**

```bash
sudo ./fedora.sh <EFI_PARTITION> <SWAP_PARTITION> <ROOT_PARTITION> [PROFILE]
```

**Arguments:**

- `<EFI_PARTITION>`: EFI partition in DISK-PART format (e.g., `1-1`)
- `<SWAP_PARTITION>`: Swap partition in DISK-PART format (e.g., `1-2`)
- `<ROOT_PARTITION>`: Root partition in DISK-PART format (e.g., `1-3`)
- `[PROFILE]`: Installation profile (optional, default: 1)
  - `1` = Server (text mode, minimal)
  - `2` = Desktop (KDE Plasma, Firefox, GUI tools)

### Part 2: `fedora-2.sh` (Run Inside Chroot)

Automatically downloaded and executed from within the chroot, this script:

1. Upgrades core packages
2. Configures locale (en_GB.UTF-8), timezone (Europe/London), keyboard (uk)
3. Installs SELinux policies and sets permissive mode
4. Configures GRUB bootloader with:
   - Secure Boot–compatible pre-signed binaries
   - Kernel parameters: `selinux=1 security=selinux enforcing=0`
5. Creates system user with sudo access
6. **Profile 1 (Server):** SSH, htop, git, development tools
7. **Profile 2 (Desktop):** Intel video drivers, KDE Plasma, Firefox, Wezterm, theming
8. Applies SELinux context labels across system directories
9. Triggers `.autorelabel` for comprehensive relabel on first boot
10. Creates `SELINUX_SETUP.txt` in user home with enforcement transition guide

## Usage Examples

### Example 1: Server Installation on NVMe

Boot from live ISO, then:

```bash
# Find your partitions
sudo lsblk

# Install to /dev/nvme0n1 (EFI: p1, Swap: p2, Root: p3)
sudo ./fedora.sh 1-1 1-2 1-3 1
```

**Output:**
```
DEBUG: uefi_part=/dev/nvme0n1p1 → uefi_part_num=1
Fedora 44 detected
Validating partitions...
Installing Fedora base packages with dnf5...
Downloading fedora-2.sh from GitHub...
Installation completed. Server is ready. Please reboot to access the system.
```

### Example 2: Desktop Installation on SATA Drive

```bash
# Find your partitions
sudo lsblk

# Install to /dev/sda (EFI: p1, Swap: p2, Root: p3)
sudo ./fedora.sh 1-1 1-2 1-3 2
```

**Output:**
```
1. Multiuser/Server (no GUI, CLI only)
2. Full Desktop (KDE Plasma, Firefox, GUI tools)
Select profile (default 1): 2

Installing Fedora base packages with dnf5...
Installing Intel video drivers and utilities...
Installing KDE Plasma desktop environment...
Installation completed. Please reboot and log into KDE Plasma.

=== SELinux Configuration ===
SELinux is set to PERMISSIVE mode for the initial boot.
The system will automatically relabel all files on first boot.

After successful first boot:
  1. Edit /etc/selinux/config and change SELINUX=permissive to SELINUX=enforcing
  2. Remove 'enforcing=0' from kernel parameters in /etc/default/grub
  3. Run: sudo setenforce 1
  4. Reboot for final enforcement
```

### Example 3: Check Your Partition Format

To find your DISK-PART format:

```bash
# List partitions (shows device names like /dev/nvme0n1p1, /dev/sda2, etc.)
sudo lsblk

# Your DISK-PART format mapping:
# /dev/nvme0n1p1 → 1-1
# /dev/nvme0n1p2 → 1-2
# /dev/nvme0n1p3 → 1-3
#
# /dev/sda1 → 1-1
# /dev/sda2 → 1-2
# /dev/sda3 → 1-3
#
# /dev/sdb1 → 2-1  (if you have a second disk)
```

## SELinux Configuration

SELinux is **enabled in permissive mode** by default to ensure safe first boot:

### First Boot (Permissive)

- Kernel starts with `selinux=1 security=selinux enforcing=0`
- `/.autorelabel` trigger runs → full filesystem relabeling
- System boots successfully even with unlabeled files
- User logs in and finds `SELINUX_SETUP.txt` in home directory

### Switching to Enforcing Mode

After first successful boot, you can enable full SELinux enforcement:

**Quick commands (from `SELINUX_SETUP.txt`):**

```bash
# Step 1: Change config to enforcing
sudo sed -i 's/SELINUX=permissive/SELINUX=enforcing/' /etc/selinux/config

# Step 2: Remove kernel permissive override
sudo sed -i 's/ enforcing=0//' /etc/default/grub

# Step 3: Apply GRUB changes
sudo grub2-mkconfig -o /boot/grub2/grub.cfg

# Step 4: Set enforcing mode
sudo setenforce 1

# Step 5: Reboot
sudo reboot
```

Or use the one-liner:

```bash
sudo sed -i 's/SELINUX=permissive/SELINUX=enforcing/' /etc/selinux/config && \
  sudo sed -i 's/ enforcing=0//' /etc/default/grub && \
  sudo grub2-mkconfig -o /boot/grub2/grub.cfg && \
  sudo setenforce 1 && \
  echo "SELinux set to enforcing. Reboot to finalize: sudo reboot"
```

## System Configuration

### Default Settings

| Setting | Value |
|---------|-------|
| Locale | en_GB.UTF-8 |
| Timezone | Europe/London |
| Keyboard | UK (gb) |
| Filesystem | ext4 (root), vfat (EFI) |
| Init System | systemd |
| Boot Method | systemd-boot (UEFI) |
| Bootloader | GRUB 2 (Secure Boot compatible) |
| Shell | bash |
| Package Manager | dnf5 |

### User Account

- Username: `george` (hardcoded; modify scripts to change)
- Sudo access: Yes (member of `wheel` group)
- Home directory: `/home/george`
- Initial shell: `/bin/bash`

## Important Notes

### Limitations

- **UEFI only** — BIOS/CSM mode not supported
- **Secure Boot** — Compatible, uses pre-signed binaries
- **RPMFusion repos** — Automatically enabled (free and nonfree)
- **Live environment** — Must have `curl` and `chroot` support

### Safety

- **Backup your data** — This script will format partitions without confirmation
- **Live USB nearby** — Keep your live environment available in case of boot failure
- **Test in VM first** — Recommended for first-time users
- **SELinux permissive mode** — First boot is safe; enforce after verification

### Troubleshooting

**System fails to boot after installation:**
- Boot the live USB again
- Mount the root partition: `sudo mount /dev/nvme0n1p3 /mnt`
- Check boot logs: `sudo cat /mnt/var/log/messages | tail -50`
- Verify EFI variables: `sudo efibootmgr -v`

**Installation hangs during `dnf5 install`:**
- Check internet connectivity: `ping 8.8.8.8`
- Verify live environment has `dnf5`: `which dnf5`
- Try from a different live ISO

**SELinux prevents login after enforcing mode:**
- Boot with `selinux=0` kernel parameter
- Change `/etc/selinux/config` back to `SELINUX=permissive`
- Reboot and investigate denial logs: `sudo journalctl | grep denied`

## Logging

Both scripts log output to:

```
fedora-install-YYYYMMDD_HHMM.log
```

Check this file for detailed debug information if installation fails.

## Repository

Source code:
- Fedora Installer: https://github.com/georgeabr/fedora-installer/
- Arch Linux ISO (includes diskviz): https://github.com/georgeabr/arch-iso
- Diskviz (standalone, requires compilation): https://github.com/georgeabr/systems-programming/tree/main/diskviz

## License

Source-available: NC-SA-BIN-CL v1.2  
Contact: support@georgetech.co.uk

---

**Last updated:** August 2026  
**Tested with:** Arch Linux 2026.08
