#!/usr/bin/env bash
# ENABLE VERBOSE DEBUGGING
set -x
START_TIME=$(date +%s)
date
set -euo pipefail

# -------------------------
# CONFIGURATION
# -------------------------
EFI_PART="/dev/sda1"
SWAP_PART="/dev/sda2"
ROOT_PART="/dev/sda3"
TARGET="/mnt/install"

# Extract the parent disk (e.g., /dev/sda or /dev/nvme0n1)
DISK=$(lsblk -no PKNAME "$EFI_PART")
DISK="/dev/$DISK"

# Extract the partition number (e.g., 1 or 2)
PART_NUM=$(lsblk -no PARTN "$EFI_PART")

NEW_USER="george"
NEW_PASS="parola"
NEW_HOSTNAME="fedora"

# -------------------------
# 0. PRE-FLIGHT CHECKS
# -------------------------
if [ "$EUID" -ne 0 ]; then
  echo "CRITICAL: Run as root." >&2
  exit 1
fi

# A. INTERNET CHECK
echo "Checking internet connectivity..."
if ! ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
    echo "#####################################################"
    echo "ERROR: No internet connection detected."
    echo "Please connect to Wi-Fi or Ethernet and try again."
    echo "#####################################################"
    exit 1
fi
echo "Internet connection confirmed."

# B. PARTITION CONFIRMATION
set +x # Disable debug for clean prompt
echo "#####################################################"
echo "INSTALLATION TARGETS:"
echo "  EFI Partition:  $EFI_PART"
echo "  Swap Partition: $SWAP_PART"
echo "  Root Partition: $ROOT_PART"
echo "  Target Mount:   $TARGET"
echo "#####################################################"
read -p "Are you sure you want to wipe these partitions and proceed? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted by user."
    exit 1
fi
set -x # Enable debug

trap 'rc=$?; set +e; umount -R "$TARGET" 2>/dev/null || true; exit $rc' EXIT

# -------------------------
# 1. LIVE SYSTEM PREP
# -------------------------
echo "#####################################################"
echo "STEP 1: CONFIGURING LIVE SYSTEM SOURCE"
echo "#####################################################"

set +e

# Enable ssh service
systemctl enable --now sshd.service

# A. CLEAN AUTOLOGIN (LIVE ENV)
echo "Sanitizing SDDM Autologin..."
if [ -f /etc/sddm.conf ]; then
    echo "Patching /etc/sddm.conf..."
    sed -i '/^User=liveuser/d' /etc/sddm.conf
    sed -i '/^Session=live/d' /etc/sddm.conf
fi

if [ -d /etc/sddm.conf.d ]; then
    echo "Cleaning /etc/sddm.conf.d/..."
    rm -vf /etc/sddm.conf.d/*autologin*
    rm -vf /etc/sddm.conf.d/*live*
fi

# Install RPM Fusion (Added -y)
dnf install -y https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
  https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm

# Install fonts first (required for vconsole setup)
dnf install -y terminus-fonts-console

# B. LOCALE, KEYMAP & TIMEZONE
echo "Configuring Locale (en_GB)..."
echo "LANG=en_GB.UTF-8" > /etc/locale.conf
export LANG=en_GB.UTF-8

echo "Configuring Console (UK)..."
cat <<VCON > /etc/vconsole.conf
KEYMAP=uk
XKBLAYOUT=gb
FONT=ter-922b
VCON

# Restart the console service for font update
systemctl restart systemd-vconsole-setup.service

echo "Configuring Timezone (London)..."
ln -sf /usr/share/zoneinfo/Europe/London /etc/localtime

# C. JOURNALD CONFIGURATION (STRICT FORMAT)
echo "Configuring Journald (MaxUse=100M)..."
mkdir -p /etc/systemd
JCONF="/etc/systemd/journald.conf"

if [ -f "$JCONF" ]; then
    if grep -q "^#\?SystemMaxUse=" "$JCONF"; then
        sed -i 's/^#\?SystemMaxUse=.*/SystemMaxUse=100M/' "$JCONF"
    else
        if grep -q "^\[Journal\]" "$JCONF"; then
             echo "SystemMaxUse=100M" >> "$JCONF"
        else
             echo -e "\n[Journal]\nSystemMaxUse=100M" >> "$JCONF"
        fi
    fi
else
    echo -e "[Journal]\nSystemMaxUse=100M" > "$JCONF"
fi

# D. HOSTNAME
echo "Setting hostname to $NEW_HOSTNAME..."
hostnamectl set-hostname "$NEW_HOSTNAME"
echo "$NEW_HOSTNAME" > /etc/hostname

# E. USER CREATION
id -u "$NEW_USER" >/dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "Creating user $NEW_USER..."
    useradd -m -G wheel "$NEW_USER"
    if [ $? -ne 0 ]; then echo "ERROR: useradd failed"; exit 1; fi
else
    echo "User $NEW_USER already exists."
fi

# F. PASSWORDS
echo "$NEW_USER:$NEW_PASS" | chpasswd
echo "root:fedora" | chpasswd

# G. USER DIRECTORIES
echo "Configuring /home/$NEW_USER..."
UHOME="/home/$NEW_USER"
mkdir -v -p "$UHOME"/.config/{gtk-3.0,gtk-4.0,htop,kitty}
mkdir -v -p "$UHOME"/{Documents,Downloads,Music,Pictures,Videos,Desktop,Templates,Public,.icons}
mkdir -v -p "$UHOME"/.local/share/color-schemes
mkdir -v -p "$UHOME"/.local/share/konsole

# H. CONFIG FILES
printf "[Settings]\ngtk-cursor-blink = 0\n" > "$UHOME"/.config/gtk-4.0/settings.ini
printf "[Settings]\ngtk-cursor-blink = 0\n" > "$UHOME"/.config/gtk-3.0/settings.ini
printf "gtk-cursor-blink = 0\n" > "$UHOME"/.gtkrc-2.0
printf "gtk-cursor-blink = 0\n" > "$UHOME"/.gtkrc-2.0-kde

echo "Downloading configs..."
curl -f -s -L -o "$UHOME"/.vimrc https://raw.githubusercontent.com/georgeabr/linux-configs/refs/heads/master/.vimrc
curl -f -s -L -o "$UHOME"/.wezterm.lua https://raw.githubusercontent.com/georgeabr/linux-configs/refs/heads/master/.wezterm.lua
curl -f -s -L -o "$UHOME"/.config/htop/htoprc \
  https://raw.githubusercontent.com/georgeabr/linux-configs/refs/heads/master/v5/.config/htop/htoprc

# Konsole Profiles
curl -f -s -L \
  -o "$UHOME"/.local/share/konsole/"Profile 1.profile" \
  "https://raw.githubusercontent.com/georgeabr/linux-configs/refs/heads/master/Profile%201.profile"
curl -f -s -L -o "$UHOME"/.local/share/konsole/WhiteOnBlack.colorscheme \
  https://raw.githubusercontent.com/georgeabr/linux-configs/refs/heads/master/WhiteOnBlack.colorscheme

# Kitty Configs
curl -f -s -L -o "$UHOME"/.config/kitty/kitty.conf \
  https://raw.githubusercontent.com/georgeabr/linux-configs/refs/heads/master/kitty.conf
curl -f -s -L -o "$UHOME"/.config/kitty/current-theme.conf \
  https://raw.githubusercontent.com/georgeabr/linux-configs/refs/heads/master/current-theme.conf

# KDE Configs
cat <<KDEEOF > "$UHOME"/.config/kxkbrc
[Layout]
Use=true
LayoutList=gb
Options=
Model=pc105
Variant=
KDEEOF

echo 'export QT_SCALE_FACTOR_ROUNDING_POLICY=Round' >> "$UHOME"/.profile

cat <<KDEEOF > "$UHOME"/.config/kdeglobals
[General]
AccentColor=104,107,111
ColorScheme=BreezeDark-new-darker
[KDE]
LookAndFeelPackage=org.kde.breezedark.desktop
CursorBlinkRate=0
AnimationDurationFactor=0
KDEEOF

cat <<KDEEOF > "$UHOME"/.config/kcminputrc
[Keyboard]
NumLock=0
[Mouse]
cursorSize=40
cursorTheme=XCursor-Pro-Dark
KDEEOF

cat <<KDEEOF > "$UHOME"/.config/klaunchrc
[BusyCursorSettings]
Bouncing=false
[FeedbackStyle]
BusyCursor=false
TaskbarButton=false
KDEEOF

cat <<KDEEOF > "$UHOME"/.config/kwalletrc
[Wallet]
Enabled=false
First Use=false
KDEEOF

cat <<KDEEOF > "$UHOME"/.config/konsolerc
[Desktop Entry]
DefaultProfile=Profile 1.profile
[General]
ConfigVersion=1
[KonsoleWindow]
AllowMenuAccelerators=true
RemoveWindowTitleBarAndFrame=true
[MainWindow]
ToolBarsMovable=Enabled
[MainWindow][Toolbar sessionToolbar]
IconSize=16
ToolButtonStyle=TextOnly
[SplitView]
SplitViewVisibility=AlwaysHideSplitHeader
[ThumbnailsSettings]
EnableThumbnails=false
[UiSettings]
ColorScheme=
KDEEOF

cat <<KDEEOF > "$UHOME"/.config/kwinrulesrc
[2c0055f0-3a1a-4cbb-83d0-1bfaa5e348bc]
Description=Window settings for org.wezfurlong.wezterm
maximizehoriz=true
maximizehorizrule=3
maximizevert=true
maximizevertrule=3
noborder=true
noborderrule=3
title=bash
types=1
wmclass=wezterm-gui org.wezfurlong.wezterm
wmclasscomplete=true
wmclassmatch=1

[6a08d7a5-ee72-4a36-915a-d3fb295eb0c4]
Description=Kitty terminal emulator
maximizehoriz=true
maximizehorizrule=3
maximizevert=true
maximizevertrule=3
noborder=true
noborderrule=3
wmclass=kitty
wmclassmatch=1

[General]
count=2
rules=2c0055f0-3a1a-4cbb-83d0-1bfaa5e348bc,6a08d7a5-ee72-4a36-915a-d3fb295eb0c4
KDEEOF

# I. THEMES
echo "Downloading themes..."
CURL_BASE="https://raw.githubusercontent.com/georgeabr/linux-configs/refs/heads/master"
SCHEMES=("BreezeDark1" "BreezeDark-new-darker" "Chocula-darker-warm" "Chocula-darker" "We10XOSDark1")
for s in "${SCHEMES[@]}"; do
  curl -f -s -L -o "$UHOME/.local/share/color-schemes/$s.colors" "$CURL_BASE/$s.colors"
done

curl -f -s -L -o /tmp/cursors.tar.xz https://github.com/ful1e5/XCursor-pro/releases/download/v2.0.2/XCursor-Pro-Dark.tar.xz
curl -f -s -L -o /tmp/hackneyed.tar.bz2 \
  https://github.com/georgeabr/linux-configs/raw/refs/heads/master/Hackneyed-Dark-36px-0.9.3-right-handed.tar.bz2

tar -xf /tmp/cursors.tar.xz -C "$UHOME"/.icons
tar -xf /tmp/hackneyed.tar.bz2 -C "$UHOME"/.icons

# Fix Ownership
chown -R "$NEW_USER:$NEW_USER" "$UHOME"

set -e

# -------------------------
# 2. DISK PREPARATION
# -------------------------
echo "#####################################################"
echo "STEP 2: PREPARING TARGET DISKS"
echo "#####################################################"

umount -R "$TARGET" 2>/dev/null || true
echo "Formatting $ROOT_PART..."
mkfs.ext4 -F -q "$ROOT_PART"
mkdir -p "$TARGET"
mount "$ROOT_PART" "$TARGET"

mkdir -p "$TARGET/boot/efi"
echo "Mounting EFI..."
mount "$EFI_PART" "$TARGET/boot/efi"

if ! blkid "$SWAP_PART" | grep -q 'TYPE="swap"'; then
  mkswap "$SWAP_PART"
fi
swapon "$SWAP_PART" || true

# -------------------------
# 3. CLONING ROOT
# -------------------------
echo "#####################################################"
echo "STEP 3: CLONING LIVE SYSTEM TO DISK"
echo "#####################################################"

# Copy root partition.
# Source is clean (no autologin, user ready, locale set, journald set)
sudo rsync -aAX --info=progress2 \
  --exclude="/dev/*" --exclude="/proc/*" --exclude="/sys/*" \
  --exclude="/tmp/*" --exclude="/run/*" --exclude="/mnt/*" \
  --exclude="/media/*" --exclude="/lost+found" \
  / "$TARGET/" 2>&1 | grep -v "lsetxattr" || true

echo "Checking for /etc/passwd..."
if [ -f "$TARGET/etc/passwd" ]; then
    echo "SUCCESS: /etc/passwd exists."
else
    echo "FATAL: /etc/passwd missing."
    exit 1
fi

# -------------------------
# 4. FINALIZING EFI
# -------------------------
echo "#####################################################"
echo "STEP 4: FINALISING EFI"
echo "#####################################################"
sudo cp -RT /boot/efi/ "$TARGET/boot/efi/" >/dev/null 2>&1
sync

# -------------------------
# 5. BOOTLOADER & PACKAGES
# -------------------------
echo "#####################################################"
echo "STEP 5: INSTALLING BOOTLOADER & PACKAGES (CHROOT)"
echo "#####################################################"

for i in dev proc sys run; do mount --bind "/$i" "$TARGET/$i"; done
mount -t efivarfs efivarfs "$TARGET/sys/firmware/efi/efivars" 2>/dev/null || true

ROOT_UUID="$(blkid -s UUID -o value "$ROOT_PART")"
EFI_UUID="$(blkid -s UUID -o value "$EFI_PART")"
SWAP_UUID="$(blkid -s UUID -o value "$SWAP_PART")"

cat <<EOF > "$TARGET/etc/fstab"
UUID=$ROOT_UUID / ext4 defaults 1 1
UUID=$EFI_UUID /boot/efi vfat defaults 0 2
UUID=$SWAP_UUID none swap sw 0 0
EOF

chroot "$TARGET" /bin/bash <<CHROOT_EOF
set -x
set -euo pipefail

# Re-affirm passwords
echo "$NEW_USER:$NEW_PASS" | chpasswd
echo "root:fedora" | chpasswd

# Re-affirm hostname
echo "$NEW_HOSTNAME" > /etc/hostname

# Re-affirm Locale & Keymap (Redundant safety)
echo "LANG=en_GB.UTF-8" > /etc/locale.conf
ln -sf /usr/share/zoneinfo/Europe/London /etc/localtime
cat <<VCON > /etc/vconsole.conf
KEYMAP=uk
XKBLAYOUT=gb
FONT=ter-922b
VCON

# Bootloader
mkdir -p /boot/efi/EFI/fedora
cat <<GRUBCFG > /boot/efi/EFI/fedora/grub.cfg
search --no-floppy --fs-uuid --set=dev $ROOT_UUID
set prefix=(\\\$dev)/boot/grub2
export \\\$prefix
configfile \\\$prefix/grub.cfg
GRUBCFG

rm -f /boot/loader/entries/*.conf
KVER="\$(ls /lib/modules | head -n 1)"
kernel-install add "\$KVER" "/lib/modules/\$KVER/vmlinuz"
grub2-mkconfig -o /boot/grub2/grub.cfg
dnf reinstall -y grub2-efi-x64 shim-x64

# Execute corrected efibootmgr command
efibootmgr -c -d "$DISK" -p "$PART_NUM" -L "FedoraNew" -l '\EFI\fedora\shimx64.efi'

# Install amenities & Multimedia (Added kitty)
dnf install -y htop mc iotop vainfo vim intel-media-driver kitty
dnf swap ffmpeg-free ffmpeg --allowerasing -y
dnf update @multimedia --setopt="install_weak_deps=False" --exclude=PackageKit-gstreamer-plugin -y

touch /.autorelabel
CHROOT_EOF

set +x
echo "#####################################################"
DURATION=$(( $(date +%s) - START_TIME ))
printf "PROCESS COMPLETE. Duration: %d minutes and %d seconds\n" "$((DURATION / 60))" "$((DURATION % 60))"
echo "Command: umount -R $TARGET && reboot"
echo "#####################################################"
date
