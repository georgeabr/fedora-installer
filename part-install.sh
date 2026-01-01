#!/bin/bash

# Configuration
EFI_PART="/dev/sda1"
SWAP_PART="/dev/sda2"
ROOT_PART="/dev/sda3"
TARGET="/mnt/install"
THREADS=$(nproc)

if [ "$EUID" -ne 0 ]; then 
  echo "Run as root (sudo ./script.sh)"
  exit 1
fi

set -e

echo "--- 1. CLEANUP ---"
setenforce 0 || true
umount -R $TARGET 2>/dev/null || true
swapoff $SWAP_PART 2>/dev/null || true

echo "--- 2. FORMAT AND MOUNT ---"
mkfs.ext4 -F "$ROOT_PART"
mkdir -p $TARGET
mount "$ROOT_PART" $TARGET

mkdir -p $TARGET/boot/efi
mount "$EFI_PART" $TARGET/boot/efi

if ! blkid "$SWAP_PART" | grep -q 'TYPE="swap"'; then
    mkswap "$SWAP_PART"
fi
swapon "$SWAP_PART" || true

echo "--- 3. CREATING SKELETON & SYSTEM COPY ---"
mkdir -p $TARGET/{dev,proc,sys,run,tmp,var/tmp,mnt,media,home,root,etc,usr,bin,lib,lib64}
chmod 1777 $TARGET/tmp $TARGET/var/tmp

# Main copy excluding virtual dirs and the EFI mount
rsync -aAX --quiet --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/lost+found","/boot/efi/*"} / "$TARGET/" || {
    RET=$?
    if [ $RET -ne 23 ] && [ $RET -ne 24 ]; then exit $RET; fi
}

# Sync EFI files separately (vfat compatible)
rsync -rt /boot/efi/ "$TARGET/boot/efi/"
sync

echo "--- 4. BINDING VIRTUAL FILESYSTEMS ---"
for i in dev proc sys run; do
    mount --bind /$i $TARGET/$i
done
mount -t efivarfs efivarfs $TARGET/sys/firmware/efi/efivars || true

ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")
SWAP_UUID=$(blkid -s UUID -o value "$SWAP_PART")

cat <<EOF > $TARGET/etc/fstab
UUID=$ROOT_UUID / ext4 defaults 1 1
UUID=$EFI_UUID /boot/efi vfat defaults 0 2
UUID=$SWAP_UUID none swap sw 0 0
EOF

echo "--- 5. REPAIRING KERNEL ENTRIES (CHROOT) ---"
chroot $TARGET /bin/bash <<CHROOT_DELIMITER
set -e

echo "Creating Fedora EFI stub..."
mkdir -p /boot/efi/EFI/fedora
cat <<EOF > /boot/efi/EFI/fedora/grub.cfg
search --no-floppy --fs-uuid --set=dev $ROOT_UUID
set prefix=(\\\$dev)/boot/grub2
export \\\$prefix
configfile \\\$prefix/grub.cfg
EOF

echo "Cleaning broken build paths..."
# Delete the entries pointing to /home/fedora/Livecds/...
rm -f /boot/loader/entries/*.conf

echo "Generating local boot entries..."
# Get the currently installed kernel version
KERNEL_VERSION=\$(ls /lib/modules | head -n 1)
# Create a valid local entry for this kernel
kernel-install add \$KERNEL_VERSION /lib/modules/\$KERNEL_VERSION/vmlinuz

echo "Updating GRUB and NVRAM..."
grub2-mkconfig -o /boot/grub2/grub.cfg
dnf reinstall -y grub2-efi-x64 shim-x64
efibootmgr -c -d /dev/sda -p 1 -L "fedora" -l "\\EFI\\fedora\\shimx64.efi" || true

echo "Setting root password..."
echo "root:fedora" | chpasswd

echo "Enabling SELinux relabeling..."
touch /.autorelabel
CHROOT_DELIMITER

echo "--- 6. FINAL VERIFICATION ---"
echo "New Boot Entry Contents:"
cat $TARGET/boot/loader/entries/*.conf | grep -E 'linux|initrd'
efibootmgr | grep -i fedora

echo "----------------------------------------------------"
echo "DONE. Run: umount -R $TARGET && reboot"
