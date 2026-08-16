#!/bin/bash

hostname="$1"
username="$2"
disk="$3"
part_num="$4"
root_uuid="$5"
releasever="$6"
profile="${7:-1}"  # Default to 1 (multiuser/server) if not provided
uefi_part_num="$8"

printf "DEBUG fedora-2.sh: Received uefi_part_num=$uefi_part_num (8th param)\n"

# dnf5 is already available in the chroot from Part 1 bootstrap

if [[ "$profile" == "1" ]]; then
    install_profile="multiuser"
    printf "\nPart 2 - Server Installation (CLI only)\n"
else
    install_profile="desktop"
    printf "\nPart 2 - Desktop Installation (Graphical)\n"
fi

printf "Configuring locale to London/UK.\n"

printf "\nRefreshing package cache and upgrading system.\n"
dnf5 upgrade --refresh -y

dnf5 install -y terminus-fonts

rm -rf /etc/localtime
ln -sf /usr/share/zoneinfo/Europe/London /etc/localtime
hwclock --systohc --utc

# Set locale using localectl
localectl set-locale LANG=en_GB.UTF-8

# Set console keymap and font
echo "KEYMAP=uk" >> /etc/vconsole.conf
echo "XKBLAYOUT=gb" >> /etc/vconsole.conf
echo "FONT=ter-922b" >> /etc/vconsole.conf

printf "\nConfiguring hostname\n"
echo "$hostname" > /etc/hostname

printf "\nEnabling SSH.\n"
dnf5 install -y openssh-server
systemctl enable sshd.service

echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/00-wheel-sudo
chmod 0440 /etc/sudoers.d/00-wheel-sudo

printf "\nEnabling RPMFusion repositories.\n"
dnf5 install -y "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${releasever}.noarch.rpm" "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${releasever}.noarch.rpm"

printf "\nUpgrading core group packages.\n"
dnf5 group upgrade -y core

# Create /etc/default/grub with standard Fedora settings BEFORE installing GRUB
# This ensures the file exists when RPM scriptlets run
cat << 'EOF' > /etc/default/grub
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="$(sed 's, release .*$,,g' /etc/system-release)"
GRUB_DEFAULT=saved
GRUB_DISABLE_SUBMENU=true
GRUB_TERMINAL_OUTPUT="console"
GRUB_CMDLINE_LINUX="rhgb quiet"
GRUB_DISABLE_RECOVERY="true"
GRUB_ENABLE_BLSCFG=true
EOF

printf "\nInstalling GRUB bootloader.\n"
dnf5 install -y grub2-efi-x64 shim-x64 efibootmgr dosfstools os-prober mtools

# Create Fedora GRUB directory and chainloader config
mkdir -p /boot/efi/EFI/fedora
cat <<GRUBCFG > /boot/efi/EFI/fedora/grub.cfg
search --no-floppy --fs-uuid --set=dev $root_uuid
set prefix=(\$dev)/boot/grub2
export \$prefix
configfile \$prefix/grub.cfg
GRUBCFG

# Register kernel with kernel-install
rm -f /boot/loader/entries/*.conf
KVER="$(ls /lib/modules | head -n 1)"

if [[ -z "$KVER" ]] || [[ ! -f "/lib/modules/$KVER/vmlinuz" ]]; then
    printf "\n\e[1;31mError: Kernel version string is empty or /lib/modules/$KVER/vmlinuz does not exist.\e[0m\n"
    exit 1
fi

printf "Detected kernel version: $KVER\n"
kernel-install add "$KVER" "/lib/modules/$KVER/vmlinuz"

# Generate main GRUB config
grub2-mkconfig -o /boot/grub2/grub.cfg

# Register Fedora entry in UEFI/NVRAM boot manager
# Note: grub2-install is NOT used here to preserve Secure Boot compatibility
# The pre-signed binaries from dnf5 install are already in place
# Use $uefi_part_num (EFI partition) not $part_num (root partition)
printf "DEBUG efibootmgr: disk=$disk, uefi_part_num=$uefi_part_num, hostname=$hostname\n"
efibootmgr -c -d "$disk" -p "$uefi_part_num" -L "Fedora-$hostname" -l '\EFI\fedora\shimx64.efi'

if [[ "$install_profile" == "desktop" ]]; then
	printf "\nInstalling Intel video drivers and utilities.\n"
	dnf5 install -y zram-generator
	dnf5 install -y perf strace
	dnf5 install -y intel-media-driver libva-utils

	printf "\nInstalling KDE Plasma desktop environment.\n"
	dnf5 environment install -y kde-desktop-environment
	dnf5 install -y plasma-workspace-x11 plasma-login-manager

	# KDE applications
	dnf5 install -y ark dolphin kate konsole gwenview

	# Audio and multimedia
	dnf5 install -y pipewire pipewire-alsa pavucontrol alsa-sof-firmware
else
	printf "\nSkipping desktop environment (server profile selected).\n"
	# Still need zram-generator for server profile
	dnf5 install -y zram-generator
fi

# System utilities (both profiles)
dnf5 install -y mc nano vim htop wget less man-pages mandoc bc unzip unrar aria2 7zip

if [[ "$install_profile" == "desktop" ]]; then
	# Fonts (desktop only)
	dnf5 install -y liberation-fonts dejavu-fonts google-roboto-mono-fonts bitstream-vera-fonts fontawesome-fonts google-noto-fonts google-noto-cjk-fonts

	# Internet applications (Firefox is desktop only)
	dnf5 install -y firefox

	### wezterm (from COPR, desktop only)
	printf "\nInstalling wezterm from COPR.\n"
	dnf5 copr enable -y wezfurlong/wezterm-nightly
	dnf5 install -y wezterm
	### wezterm

	### Cousine Nerd Font (desktop only)
	REPO="ryanoasis/nerd-fonts"
	FONT="Cousine"
	INSTALL_DIR="/usr/local/share/fonts/${FONT}NerdFont"

	echo "Looking up latest ${FONT} Nerd Font release"
	API_URL="https://api.github.com/repos/${REPO}/releases/latest"
	ASSET_URL=$(
	  curl -s "${API_URL}" \
		| grep -E 'browser_download_url.*Cousine.*\.zip"' \
		| head -n1 \
		| cut -d '"' -f4
	)

	if [[ -z "$ASSET_URL" ]]; then
	  echo "Failed to find a download URL for ${FONT}.zip, skipping install" >&2
	else
	  echo "Found download URL: $ASSET_URL"

	  FONT_TMPDIR=$(mktemp -d)
	  ZIPFILE="${FONT_TMPDIR}/${FONT}.zip"
	  echo "Downloading ZIP to $ZIPFILE"
	  curl -sfL --retry 3 --retry-connrefused --connect-timeout 10 -o "$ZIPFILE" "$ASSET_URL"

	  if [[ ! -s "$ZIPFILE" ]] || ! unzip -tq "$ZIPFILE" >/dev/null 2>&1; then
		echo "Download failed or file is not a valid zip, skipping install" >&2
	  else
		echo "Installing into $INSTALL_DIR"
		mkdir -p "$INSTALL_DIR"
		unzip -o "$ZIPFILE" -d "$INSTALL_DIR" >/dev/null
		fc-cache -fv "$INSTALL_DIR" >/dev/null 2>&1 || echo "fc-cache failed, but fonts may still work"
	  fi

	  rm -rf "$FONT_TMPDIR"
	fi
	### end Cousine Nerd Font
fi

# Network and utilities (both profiles)
dnf5 install -y git NetworkManager NetworkManager-tui NetworkManager-wifi NetworkManager-vpnc nm-connection-editor

### NTP Configuration
printf "\nConfiguring NTP servers and systemd-timesyncd.\n"
TIMESYNCD_CONF="/etc/systemd/timesyncd.conf"
SERVICE_UNIT="/usr/lib/systemd/system/systemd-timesyncd.service"
WANTS_DIR="/etc/systemd/system/multi-user.target.wants"
WANTS_LINK="${WANTS_DIR}/systemd-timesyncd.service"

mkdir -p "${WANTS_DIR}"
sed -E -i 's@^#?NTP=.*@NTP=0.fedora.pool.ntp.org 1.fedora.pool.ntp.org@' \
    "${TIMESYNCD_CONF}"

ln -sf "${SERVICE_UNIT}" "${WANTS_LINK}"

echo "Verifying NTP configuration"
grep '^NTP=' "${TIMESYNCD_CONF}"
ls -l "${WANTS_LINK}"

echo ""
echo ">> NTP configured. Systemd-timesyncd will sync on boot."
### NTP Configuration

### Disable cursor blink globally
mkdir -p /etc/xdg

# 1) Disable cursor blink in GTK3 apps
mkdir -p /etc/gtk-3.0
echo '[Settings]'                                > /etc/gtk-3.0/settings.ini
echo 'gtk-cursor-blink = false'                 >> /etc/gtk-3.0/settings.ini
echo 'gtk-cursor-blink-timeout = 0'             >> /etc/gtk-3.0/settings.ini
chmod 644 /etc/gtk-3.0/settings.ini

# 2) Disable cursor blink in GTK4 apps
mkdir -p /etc/gtk-4.0
echo '[Settings]'                                > /etc/gtk-4.0/settings.ini
echo 'gtk-cursor-blink = false'                 >> /etc/gtk-4.0/settings.ini
echo 'gtk-cursor-blink-timeout = 0'             >> /etc/gtk-4.0/settings.ini
chmod 644 /etc/gtk-4.0/settings.ini

echo "GTK3/4 cursor blink globally disabled."
### Cursor blink

# Enable ZRAM
printf "\nEnabling ZRAM.\n"
printf "[zram0]\n" > /etc/systemd/zram-generator.conf
systemctl enable systemd-zram-setup@zram0.service

if [[ "$install_profile" == "desktop" ]]; then
	systemctl enable plasmalogin.service
	# Set default target to graphical
	systemctl set-default graphical.target
else
	# Server profile: use multi-user target
	systemctl set-default multi-user.target
fi

systemctl enable NetworkManager.service
systemctl start NetworkManager.service

# Do user creation
printf "\nEnter password for root user...\n"
passwd root
printf "\nAdding user <$username> with sudo permission.\n"
useradd -m -G wheel -s /bin/bash "$username"
printf "Enter password for user <$username>...\n"
passwd "$username"

# Configure user's GTK settings
mkdir -p "/home/$username/.config"
chown "$username:$username" "/home/$username/.config"

mkdir -p "/home/$username/.config/gtk-3.0"
printf "[Settings]\n" > "/home/$username/.config/gtk-3.0/settings.ini"
printf "gtk-cursor-blink = 0\n" >> "/home/$username/.config/gtk-3.0/settings.ini"
chown "$username:$username" "/home/$username/.config/gtk-3.0/settings.ini"

mkdir -p "/home/$username/.config/gtk-4.0"
printf "[Settings]\n" > "/home/$username/.config/gtk-4.0/settings.ini"
printf "gtk-cursor-blink = 0\n" >> "/home/$username/.config/gtk-4.0/settings.ini"
chown "$username:$username" "/home/$username/.config/gtk-4.0/settings.ini"

# GTK2 settings
printf "gtk-cursor-blink = 0\n" >> "/home/$username/.gtkrc-2.0"
printf "gtk-cursor-blink = 0\n" >> "/home/$username/.gtkrc-2.0-kde"
chown "$username:$username" "/home/$username/.gtkrc-2.0"
chown "$username:$username" "/home/$username/.gtkrc-2.0-kde"

# Download user dotfiles from GitHub
curl -s -L -o "/home/$username/.vimrc" https://raw.githubusercontent.com/georgeabr/linux-configs/refs/heads/master/.vimrc

if [[ "$install_profile" == "desktop" ]]; then
	curl -s -L -o "/home/$username/.wezterm.lua" https://raw.githubusercontent.com/georgeabr/linux-configs/refs/heads/master/.wezterm.lua
	chown "$username:$username" "/home/$username/.wezterm.lua"
fi

chown "$username:$username" "/home/$username/.vimrc"

if [[ "$install_profile" == "desktop" ]]; then
	# KDE keyboard layout config (kxkbrc)
	echo '[Layout]'                                > "/home/$username/.config/kxkbrc"
	echo 'Use=true'                                >> "/home/$username/.config/kxkbrc"
	echo 'LayoutList=gb'                           >> "/home/$username/.config/kxkbrc"
	echo 'Options='                                >> "/home/$username/.config/kxkbrc"
	echo 'Model=pc105'                             >> "/home/$username/.config/kxkbrc"
	echo 'Variant='                                >> "/home/$username/.config/kxkbrc"

	chown "$username:$username" "/home/$username/.config/kxkbrc"
	chmod 644 "/home/$username/.config/kxkbrc"

	# KDE environment and appearance
	echo '# Better icon scaling in KDE' >> "/home/$username/.profile"
	echo 'export QT_SCALE_FACTOR_ROUNDING_POLICY=Round' >> "/home/$username/.profile"

	echo '[General]'                              >> "/home/$username/.config/kdeglobals"
	echo 'AccentColor=104,107,111'               >> "/home/$username/.config/kdeglobals"
	echo 'ColorScheme=BreezeDark-new-darker'     >> "/home/$username/.config/kdeglobals"

	echo '[KDE]'                                  >> "/home/$username/.config/kdeglobals"
	echo 'CursorBlinkRate=0'                     >> "/home/$username/.config/kdeglobals"
	echo 'AnimationDurationFactor=0'             >> "/home/$username/.config/kdeglobals"

	chown "$username:$username" "/home/$username/.config/kdeglobals"
	chmod 644 "/home/$username/.config/kdeglobals"

	echo '[Keyboard]'                             >> "/home/$username/.config/kcminputrc"
	echo 'NumLock=0'                              >> "/home/$username/.config/kcminputrc"

	echo '[Mouse]'                                >> "/home/$username/.config/kcminputrc"
	echo 'cursorSize=40'                          >> "/home/$username/.config/kcminputrc"
	echo 'cursorTheme=XCursor-Pro-Dark'           >> "/home/$username/.config/kcminputrc"

	chown "$username:$username" "/home/$username/.config/kcminputrc"
	chmod 644 "/home/$username/.config/kcminputrc"

	echo "KDE input configuration set."
fi

if [[ "$install_profile" == "desktop" ]]; then
	### KDE/XCursor theme configuration
	printf "\nConfiguring KDE colour schemes and XCursor themes...\n"

	mkdir -p "/home/$username/.local/share/color-schemes"
	chown "$username:$username" "/home/$username/.local/share/color-schemes/"

	curl -s -L -o "/home/$username/.local/share/color-schemes/BreezeDark1.colors" \
		https://raw.githubusercontent.com/georgeabr/linux-configs/refs/heads/master/BreezeDark1.colors
	curl -s -L -o "/home/$username/.local/share/color-schemes/BreezeDark-new-darker.colors" \
		https://raw.githubusercontent.com/georgeabr/linux-configs/refs/heads/master/BreezeDark-new-darker.colors
	curl -s -L -o "/home/$username/.local/share/color-schemes/Chocula-darker-warm.colors" \
	 	https://raw.githubusercontent.com/georgeabr/linux-configs/refs/heads/master/Chocula-darker-warm.colors
	curl -s -L -o "/home/$username/.local/share/color-schemes/Chocula-darker.colors" \
	 	https://raw.githubusercontent.com/georgeabr/linux-configs/refs/heads/master/Chocula-darker.colors
	curl -s -L -o "/home/$username/.local/share/color-schemes/We10XOSDark1.colors" \
	 	https://raw.githubusercontent.com/georgeabr/linux-configs/refs/heads/master/We10XOSDark1.colors

	chown "$username:$username" "/home/$username/.local/share/color-schemes/"*

	ls -lha "/home/$username/.local/share/color-schemes/"

	# Function to download and extract theme archives safely
	fetch_and_extract() {
		local url="$1" dest="$2" extract_dir="$3" label="$4"

		echo "Downloading ${label}"
		if ! curl -sfL --retry 3 --retry-connrefused --connect-timeout 10 -o "$dest" "$url"; then
			echo "Warning: failed to download ${label} from ${url}, skipping" >&2
			rm -f "$dest"
			return 1
		fi

		if [[ ! -s "$dest" ]] || ! tar -tf "$dest" >/dev/null 2>&1; then
			echo "Warning: downloaded file for ${label} is missing or not a valid archive, skipping" >&2
			rm -f "$dest"
			return 1
		fi

		tar -xf "$dest" -C "$extract_dir"
		rm -f "$dest"
		echo "Installed ${label} into ${extract_dir}"
		return 0
	}

	mkdir -p "/home/$username/.icons"
	chown "$username:$username" "/home/$username/.icons/"

	fetch_and_extract \
		"https://github.com/ful1e5/XCursor-pro/releases/download/v2.0.2/XCursor-Pro-Dark.tar.xz" \
		"/home/$username/XCursor-Pro-Dark.tar.xz" \
		"/home/$username/.icons" \
		"XCursor-Pro-Dark cursor theme"

	fetch_and_extract \
		"https://github.com/georgeabr/linux-configs/raw/refs/heads/master/Hackneyed-Dark-36px-0.9.3-right-handed.tar.bz2" \
		"/home/$username/Hackneyed-Dark-36px-0.9.3-right-handed.tar.bz2" \
		"/home/$username/.icons" \
		"Hackneyed-Dark cursor theme"

	mkdir -p "/home/$username/.local/share/icons"

	fetch_and_extract \
		"https://raw.githubusercontent.com/georgeabr/linux-configs/refs/heads/master/YAMIS-Muted.tar.gz" \
		"/home/$username/YAMIS-Muted.tar.gz" \
		"/home/$username/.local/share/icons" \
		"YAMIS-Muted icon theme"

	ls -lha "/home/$username/.icons/"
	ls -lha "/home/$username/.local/share/icons/"
fi

# htop configuration (both profiles)
mkdir -p "/home/$username/.config/htop"
curl -s -L -o "/home/$username/.config/htop/htoprc" \
	https://raw.githubusercontent.com/georgeabr/linux-configs/refs/heads/master/v5/.config/htop/htoprc

# Ensure user owns everything in their home directory
chown -R "$username:$username" "/home/$username/"

if [[ "$install_profile" == "desktop" ]]; then
	printf "\nInstallation completed. Please reboot and log into KDE Plasma.\n"
else
	printf "\nInstallation completed. Server is ready. Please reboot to access the system.\n"
fi
