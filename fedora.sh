#!/bin/bash

# Bump this number whenever you push a change to GitHub, so the self-update
# check below can tell an older local copy from a newer (or unpushed) one.
SCRIPT_VERSION=32

# --- root check ---
if [[ $EUID -ne 0 ]]; then
   printf "\n\e[1;31mError: This script must be run as root (use sudo).\e[0m\n\n"
   exit 1
fi

# --- self-update check ---
# Compares SCRIPT_VERSION against the version on GitHub; only updates if the
# remote version is strictly higher, so an unpushed local copy that's ahead
# of GitHub is never overwritten by an older remote one.
# Set FEDORA_SH_SKIP_UPDATE=1 to skip this (also set automatically after an update,
# to prevent a re-download loop).
if [[ -z "$FEDORA_SH_SKIP_UPDATE" ]] && ! command -v curl &>/dev/null; then
    printf "\ncurl not found - skipping self-update check.\n"
fi

if [[ -z "$FEDORA_SH_SKIP_UPDATE" ]] && command -v curl &>/dev/null; then
    script_url="https://raw.githubusercontent.com/georgeabr/fedora-installer/main/fedora.sh?_=$(date +%s)"
    script_path="$(readlink -f "$0")"
    tmp_script=$(mktemp)

    printf "\nChecking for a newer version of this script...\n"
    if curl -fsS --max-time 5 -H "Cache-Control: no-cache, no-store" -H "Pragma: no-cache" -o "$tmp_script" "$script_url"; then
        remote_version="$(grep -m1 '^SCRIPT_VERSION=' "$tmp_script" | cut -d= -f2)"
        remote_version="${remote_version:-0}"

        if ! [[ "$remote_version" =~ ^[0-9]+$ ]]; then
            printf "Could not determine the version of the script on GitHub - skipping update to be safe.\n"
        elif (( remote_version > SCRIPT_VERSION )); then
            if cp "$tmp_script" "$script_path"; then
                printf "A newer version is available (local: %s, GitHub: %s) - updating and restarting...\n\n" "$SCRIPT_VERSION" "$remote_version"
                chmod +x "$script_path"
                rm -f "$tmp_script"
                export FEDORA_SH_SKIP_UPDATE=1
                exec "$script_path" "$@"
            else
                printf "A newer version is available, but the update failed (couldn't write to %s) - continuing with current version.\n" "$script_path"
            fi
        elif (( remote_version < SCRIPT_VERSION )); then
            printf "Local version (%s) is newer than the version on GitHub (%s) - skipping update. Don't forget to push your changes.\n" "$SCRIPT_VERSION" "$remote_version"
        else
            printf "Script is already up to date (version %s).\n" "$SCRIPT_VERSION"
        fi
    else
        printf "Could not check for updates (no internet or GitHub unreachable) - continuing with current version.\n"
    fi
    rm -f "$tmp_script" 2>/dev/null
fi

# --- start self-logging ---
timestamp=$(date +%Y%m%d_%H%M)
logfile="fedora-install-${timestamp}.log"
# redirect all output (stdout+stderr) into tee => logfile _and_ console
exec > >(tee -a "$logfile") 2>&1

# --- Configuration ---
hostname="fed-$(tr -dc 'a-z' </dev/urandom | head -c3)"
username="george"
# can be ext4 or xfs
filesystem="ext4"

# --- Installation Profile Selection ---
printf "\n\e[1;36m=== Installation Profile ===\e[0m\n"
printf "1. Multiuser/Server (no GUI, CLI only)\n"
printf "2. Full Desktop (KDE Plasma, Firefox, GUI tools)\n"
printf "\nSelect profile (default: 1): "
read -r profile_choice
profile_choice="${profile_choice:-1}"

if [[ ! "$profile_choice" =~ ^[12]$ ]]; then
    printf "\n\e[1;31mError: Invalid profile selection. Using default (1).\e[0m\n"
    profile_choice="1"
fi

if [[ "$profile_choice" == "1" ]]; then
    printf "Selected: Multiuser/Server (CLI only)\n"
else
    printf "Selected: Full Desktop (Graphical)\n"
fi

# New: Function to check if a value is in "X-Y" format (e.g., 1-1, 2-3)
is_disk_partition_format() {
  [[ "$1" =~ ^[0-9]+-[0-9]+$ ]]
}

check_and_install_dnf5() {
    if command -v dnf5 &>/dev/null; then
        printf "dnf5 is available.\n"
        return 0
    fi
    
    printf "dnf5 not found. Installing...\n"
    
    if command -v pacman &>/dev/null; then
        pacman -Sy --noconfirm dnf5 appstream
        if [[ $? -ne 0 ]]; then
            printf "\n\e[1;31mError: pacman failed to install dnf5 and appstream.\e[0m\n"
            printf "This may be due to network issues or DNS resolution failure.\n"
            printf "Try one of the following:\n"
            printf "  1. Check your network connection with \`nmtui\`\n"
            printf "  2. Verify DNS works: \`getent hosts archive.fedoraproject.org\`\n"
            printf "  3. Install dnf5 manually: \`sudo pacman -S dnf5 appstream\` (outside this script)\n"
            exit 1
        fi
    elif command -v apt-get &>/dev/null; then
        apt-get update && apt-get install -y dnf5 appstream
        if [[ $? -ne 0 ]]; then
            printf "\n\e[1;31mError: apt-get failed to install dnf5 and appstream.\e[0m\n"
            printf "This may be due to network issues or DNS resolution failure.\n"
            printf "Try one of the following:\n"
            printf "  1. Check your network connection\n"
            printf "  2. Verify DNS works: \`getent hosts archive.fedoraproject.org\`\n"
            printf "  3. Install dnf5 manually: \`sudo apt-get install dnf5 appstream\` (outside this script)\n"
            exit 1
        fi
    else
        printf "\n\e[1;31mError: dnf5 not found and no known package manager detected.\e[0m\n"
        printf "Please install dnf5 manually before running this script.\n"
        exit 1
    fi
    
    if ! command -v dnf5 &>/dev/null; then
        printf "\n\e[1;31mError: Failed to install dnf5.\e[0m\n"
        exit 1
    fi
    printf "dnf5 installed successfully.\n"
}

cleanup_mounts() {
	printf "\nCleaning up mounted filesystems under /mnt.\n"
	swapoff "$swap_part" 2>/dev/null || true
	umount -l /mnt/sys/firmware/efi/efivars 2>/dev/null || true
	umount -l /mnt/boot/efi 2>/dev/null || true
	umount -l /mnt/dev/pts 2>/dev/null || true
	umount -l /mnt/dev 2>/dev/null || true
	umount -l /mnt/proc 2>/dev/null || true
	umount -l /mnt/sys 2>/dev/null || true
	umount -l /mnt/run 2>/dev/null || true
	umount -R /mnt 2>/dev/null || true
}

get_fedora_releasever() {
    # Try to detect from host /etc/os-release first
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        if [[ "$ID" == "fedora" ]] && [[ -n "$VERSION_ID" ]]; then
            printf "%s\n" "$VERSION_ID"
            return 0
        fi
    fi
    
    # Query Fedora's live-respins to detect latest stable
    if command -v curl &>/dev/null; then
        local latest_release=$(curl -fsS --max-time 5 "https://dl.fedoraproject.org/pub/alt/live-respins/" \
            | grep -oP 'F\d+' | sort -u | tail -1 | sed 's/F//')
        
        if [[ -n "$latest_release" ]]; then
            printf "%s\n" "$latest_release"
            return 0
        fi
    fi
    
    # Fallback: ask user
    printf "\n\e[1;33mWarning: Could not detect Fedora release automatically.\e[0m\n"
    printf "Enter target Fedora release version (e.g., 44): "
    read -r releasever
    printf "%s\n" "$releasever"
}

show_instructions() {
printf "\n\e[1mFedora Linux Installer (Generic Workstation)\e[0m\n"
    printf "Hostname: \e[1m$hostname\e[0m | User: \e[1m$username\e[0m | Filesystem: \e[1m$filesystem\e[0m\n"
    printf "Usage: \e[1m$0 UEFI-PART ROOT-PART SWAP-PART\e[0m (e.g., $0 1-1 1-3 1-2)\n\n"
    
    printf "1. Use \e[1mcfdisk\e[0m to partition your primary disk before running this.\n"
    printf "2. UEFI partition should already exist; \e[1mRoot will be formatted\e[0m.\n"
    printf "3. Identifiers below use 'DISK-PART' format based on /dev/nvme0n1 or /dev/sda.\n\n"
    
    printf "Available partitions:\n"
	
	# Create a temporary awk script for display
    local awk_script_display=$(mktemp)
    cat << 'EOF' > "$awk_script_display"
BEGIN {
    current_disk_line = ""; current_disk_buffer = ""; has_partitions = 0; disk_counter = 0; partition_on_disk_count = 0;
    # Updated exclude_regex to be more general for partition headers, accounting for potential leading spaces and variations
    exclude_regex = "^\\s*(Units: sectors of|Sector size \\(|I/O size \\(|Device\\s+(Boot\\s+)?Start\\s+End\\s+Sectors\\s+Size\\s+(Id\\s+)?Type)$";
}
$0 ~ exclude_regex { next }
/^Disk \/dev\// {
    if (has_partitions) { if (current_disk_buffer != "") { print current_disk_buffer; } } else { current_disk_buffer = ""; }
    current_disk_line = $0; current_disk_buffer = ""; has_partitions = 0; next;
}
/^\/dev\// && !/Disklabel/ {
    if (!has_partitions) {
        disk_counter++; partition_on_disk_count = 0;
        print current_disk_line;
        if (current_disk_buffer != "") { print current_disk_buffer; }
        # Removed leading newline from printf to remove blank line
        printf "  %-28s %-10s %-10s %-10s %-8s %s\n", "Device", "Start", "End", "Sectors", "Size", "Type";
        has_partitions = 1; current_disk_buffer = "";
    }
    partition_on_disk_count++;
    
    device = $1;
    local_start = ""; local_end = ""; local_sectors = ""; local_size = "";
    
    # Dynamically find the 'Size' field (e.g., 402M, 23.3G)
    size_field_idx = 0;
    for (k = 1; k <= NF; k++) {
        if ($k ~ /^[0-9.]+(M|G|T|K|B)$/) { # Match fields like 402M, 23.3G, 18.4G
            size_field_idx = k;
            local_size = $k;
            break;
        }
    }

    # Deduce Start, End, Sectors based on size_field_idx relative to Device ($1)
    # This assumes consistent relative positioning before Size
    if (size_field_idx > 5) { # Likely DOS with Boot flag, or more complex output
        local_start = $(size_field_idx - 3);
        local_end = $(size_field_idx - 2);
        local_sectors = $(size_field_idx - 1);
        type_start_field = size_field_idx + 2; # Type after Id
    } else { # Likely GPT or DOS without Boot flag
        local_start = $2;
        local_end = $3;
        local_sectors = $4;
        type_start_field = size_field_idx + 1; # Type after Size (or Id if present)
        # Refine type_start_field if there's an 'Id' field after Size
        if ($(size_field_idx + 1) ~ /^[0-9a-fA-F]+$/) { # Check if next field is an ID (hex/numeric)
            type_start_field = size_field_idx + 2;
        }
    }

    local_type = "";
    for (j = type_start_field; j <= NF; j++) {
        local_type = local_type $j (j < NF ? " " : "");
    }
    sub(/^ /, "", local_type); # Remove leading space if any

    printf "  %-28s %-10s %-10s %-10s %-8s %s\n", (disk_counter "-" partition_on_disk_count ". " device), local_start, local_end, local_sectors, local_size, local_type;
    next;
}
{ # Rule for accumulating other relevant lines (like Disklabel, etc.)
    if (current_disk_line != "") {
        if (current_disk_buffer != "") { current_disk_buffer = current_disk_buffer "\n" $0; } else { current_disk_buffer = $0; }
    }
}
END { # Handle the very last disk's output
    if (has_partitions) { if (current_disk_buffer != "") { print current_disk_buffer; } }
}
EOF
    # Use the temporary awk script
    fdisk -l | awk -f "$awk_script_display"
    rm "$awk_script_display" # Clean up the temporary file
}


start_install() {
# --- Internet check ---
    printf "\nChecking for internet connectivity...\n"
    if ! ping -c 1 -W 3 8.8.8.8 > /dev/null 2>&1; then
        printf "\n\e[1;31mError: No internet connection detected.\e[0m\n"
        printf "Please connect to the network using \`nmtui\` before running this script.\n\n"
		# CLOSE the logging pipe so the terminal returns to prompt immediately 
        exec >&- 2>&-
		
		# This kills the script process immediately and returns to prompt
        { sleep 0.1; kill -9 -$$; } &
        exit 1
    fi
    
    # Also verify DNS resolution works (not just ICMP)
    if ! getent hosts archive.fedoraproject.org > /dev/null 2>&1; then
        printf "\n\e[1;33mWarning: DNS resolution failed. Pacman/dnf5 may not be able to download packages.\e[0m\n"
        printf "Try to configure DNS before continuing, or ensure your network is properly configured.\n"
        printf "Continue anyway? (Y/y to continue, any other input to stop): "
        read -r dns_continue
        if ! [[ "$dns_continue" == "y" ]] && ! [[ "$dns_continue" == "Y" ]]; then
            printf "Exiting.\n"
            exit 1
        fi
    fi
    printf "Internet connection detected.\n"

# --- Fedora release version detection ---
    printf "\nDetecting Fedora release version...\n"
    releasever=$(get_fedora_releasever)
    printf "Using Fedora release: %s\n" "$releasever"

# --- Partition resolution function ---
# Takes a user input like "1-2" and resolves it to the actual partition device
# (e.g., /dev/sda2 or /dev/nvme0n1p2)
resolve_partition() {
    local user_input="$1"
    
    # Parse DISK-PART format (e.g., "1-2" means 1st disk, 2nd partition)
    local disk_num="${user_input%-*}"
    local part_num="${user_input#*-}"
    
    # Get the actual disk device name and partition index
    local disk_idx=0
    local current_disk=""
    local part_idx=0
    
    # Use fdisk to find the disk and partition
    while IFS= read -r line; do
        # Check for disk line, but skip zram and mapper devices
        if [[ "$line" =~ ^Disk\ /dev/ ]] && ! [[ "$line" =~ /dev/zram || "$line" =~ /dev/mapper ]]; then
            disk_idx=$((disk_idx + 1))
            current_disk=$(echo "$line" | awk '{print $2}' | sed 's/:$//')
            continue
        fi
        
        # Check for partition line on the target disk
        if [[ "$line" =~ ^/dev/ ]] && [[ "$disk_idx" -eq "$disk_num" ]]; then
            local device=$(echo "$line" | awk '{print $1}')
            
            # Extract partition number from device name
            local suffix="${device#${current_disk}}"
            part_idx="${suffix#p}"
            [[ "$part_idx" == "$suffix" ]] && part_idx="$suffix"
            
            # If this is the partition we're looking for
            if [[ "$part_idx" == "$part_num" ]]; then
                echo "$device"
                return 0
            fi
        fi
    done < <(fdisk -l)
    
    return 1
}

    printf "\nResolving partition identifiers...\n"
    uefi_part="$(resolve_partition "$1")"
    root_part="$(resolve_partition "$2")"
    swap_part="$(resolve_partition "$3")"

    # Validate if the lookups were successful
    if [[ -z "$uefi_part" || -z "$root_part" || -z "$swap_part" ]]; then
        printf "\n\e[1;31mError: One or more partition identifiers were invalid or not found.\e[0m\n"
        printf "Please ensure the identifiers (e.g., '1-1') match available partitions.\n"
        show_instructions; # Show instructions again with valid partitions
        exit 1;
    fi

# --- Duplicate partition check ---
    if [[ "$uefi_part" == "$root_part" || "$uefi_part" == "$swap_part" || "$root_part" == "$swap_part" ]]; then
        printf "\n\e[1;31mError: You cannot use the same partition for multiple roles.\e[0m\n"
        printf "Your input: UEFI: $1 | Root: $2 | Swap: $3\n"
        exit 1
    fi

    # Check UEFI format
    if [[ $(lsblk -no FSTYPE "$uefi_part") != "vfat" ]]; then
        printf "\n\e[1;31mError: UEFI partition is not FAT32.\e[0m\n"
        exec >&- 2>&-
        { sleep 0.1; kill -9 -$$; } &
        exit 1
    fi

	printf "\nThe Fedora install script will use the settings:\n";
 	printf "%s\n" "* Fedora version = $releasever";
 	printf "%s\n" "* host name  = $hostname";
 	printf "%s\n" "* user name  = $username";
	printf "%s\n" "* filesystem = $filesystem";

 
	printf "\nThe Fedora install script will use the below partitions:\
	\n* $uefi_part for UEFI \t(keep existing data for dual boot with Windows)"
 	printf "\n* $root_part for root (/) \t(partition will be formatted)"
	printf "\n* $swap_part for swap \t(partition will be formatted if not already)\n"
	printf "\n"

    # Simplified display for chosen partitions within start_install
    printf "\t\t\t   Device\t\tSize\t\tType\n"

    local parts_to_display=("$uefi_part" "$root_part" "$swap_part")
    local labels=("* UEFI partition" "* Root (/) partition" "* Swap partition")

    # Create a temporary awk script for displaying selected partitions
    local awk_script_selected_display=$(mktemp)
    cat << 'EOF' > "$awk_script_selected_display"
# No BEGIN block needed here for -v variables
/^\/dev\// {
    # p_dev_awk_var is directly available from the -v flag
    if ($1 == p_dev_awk_var) {
        local_size = "";
        local_type = "";
        
        # Dynamically find the 'Size' field (e.g., 402M, 23.3G)
        size_field_idx = 0;
        for (k = 1; k <= NF; k++) {
            if ($k ~ /^[0-9.]+(M|G|T|K|B)$/) { # Match fields like 402M, 23.3G, 18.4G
                size_field_idx = k;
                local_size = $k;
                break;
            }
        }

        # Deduce where 'Type' starts based on size_field_idx
        type_start_field = size_field_idx + 1; # Default: Type starts right after Size

        # If the field *after* Size is an ID (hex/numeric), then Type starts two fields after Size
        if ($(size_field_idx + 1) ~ /^[0-9a-fA-F]+$/ || $(size_field_idx + 1) ~ /^[0-9]+$/) {
            type_start_field = size_field_idx + 2;
        }
        
        for (j=type_start_field; j<=NF; ++j) local_type = local_type $j (j<NF ? " " : "");
        sub(/^ /, "", local_type); # Remove leading space from type
        printf "%-20s\t%-8s\t%s\n", $1, local_size, local_type;
        exit;
    }
}
EOF

    for i in "${!parts_to_display[@]}"; do
        local part_dev="${parts_to_display[$i]}"
        local label="${labels[$i]}"
        printf "%s \t = " "$label"
        # Pass p_dev as an argument to awk using the -v flag
        fdisk -l | awk -v p_dev_awk_var="$part_dev" -f "$awk_script_selected_display"
    done
    rm "$awk_script_selected_display" # Clean up the temporary file
	printf "\n"

	read -p "Do you wish to continue? (Y/y to continue, any other input to stop): " response

	if ! [[ "$response" == "y" ]] && ! [[ "$response" == "Y" ]]; then
	  printf "\nExiting script.\n"
	  exit 1
	fi

	printf "\n\nWill continue to installing Fedora Linux.\n"

# --- dnf5 check (install dependencies) ---
	printf "\nChecking for dnf5 package manager...\n"
	check_and_install_dnf5

	printf "\nPart 1 - Initial Fedora bootstrap/installation.\n";
	printf "\nActivating swap partition.\n"
	swapon "$swap_part" > /dev/null 2>&1;
    if [[ $? -ne 0 ]]; then
  		printf "Swap partition not formatted. Formatting with mkswap.\n";
    		mkswap "$swap_part" > /dev/null 2>&1;
    		if [[ $? -ne 0 ]]; then
    			printf "\n\e[1;31mError: Failed to format swap partition $swap_part with mkswap.\e[0m\n"
    			exit 1
    		fi
    		
            swapon "$swap_part" > /dev/null 2>&1;
            if [[ $? -ne 0 ]]; then
                printf "\n\e[1;31mError: Failed to activate swap partition $swap_part after formatting.\e[0m\n"
                exit 1
            fi
	fi
    printf "Swap partition has been enabled.\n"

	case "$filesystem" in
 		ext4)
			printf "\nFormatting root (/) partition as ext4.\n";
			mkfs.ext4 -F "$root_part" > /dev/null 2>&1;
 		;;
      		xfs)
			printf "\nFormatting root (/) partition as xfs.\n";
			mkfs.xfs -f "$root_part" > /dev/null 2>&1;
   		;;
 	esac
    if [[ $? -ne 0 ]]; then
        printf "\n\e[1;31mError: Failed to format root partition $root_part.\e[0m\n"
        exit 1
    fi
	
	printf "\nMounting UEFI, root (/) partitions.\n"
	mount "$root_part" /mnt
    if [[ $? -ne 0 ]]; then
        printf "\n\e[1;31mError: Failed to mount root partition $root_part on /mnt.\e[0m\n"
        exit 1
    fi
 	mkdir -p /mnt/boot/efi
 	mount "$uefi_part" /mnt/boot/efi
    if [[ $? -ne 0 ]]; then
        printf "\n\e[1;31mError: Failed to mount UEFI partition $uefi_part on /mnt/boot/efi.\e[0m\n"
        exit 1
    fi

	printf "\nSetting systemd NTP clock sync.\n"
	timedatectl set-ntp true

	printf "\nConfiguring Fedora repositories in target root.\n"
	mkdir -p /mnt/etc/yum.repos.d
	
	# Detect host architecture (e.g. x86_64)
	arch=$(uname -m)

	cat << EOF > /mnt/etc/yum.repos.d/fedora.repo
[fedora]
name=Fedora $releasever - $arch
metalink=https://mirrors.fedoraproject.org/metalink?repo=fedora-$releasever&arch=$arch
enabled=1
repo_gpgcheck=0
gpgcheck=0
skip_if_unavailable=False
EOF
	cat /mnt/etc/yum.repos.d/fedora.repo

	cat << EOF > /mnt/etc/yum.repos.d/fedora-updates.repo
[updates]
name=Fedora $releasever - $arch - Updates
metalink=https://mirrors.fedoraproject.org/metalink?repo=updates-released-f$releasever&arch=$arch
enabled=1
repo_gpgcheck=0
gpgcheck=0
skip_if_unavailable=False
EOF
	cat /mnt/etc/yum.repos.d/fedora-updates.repo

	printf "\nInstalling Fedora base packages with dnf5.\n"
	dnf5 install --installroot=/mnt --releasever="$releasever" -y \
		@core \
		kernel \
		grub2-efi-modules \
		grub2-efi-x64 \
		efibootmgr \
		systemd \
		systemd-udev \
		bash \
		xfsprogs \
		microcode_ctl \
		linux-firmware
    if [[ $? -ne 0 ]]; then
        printf "\n\e[1;31mError: dnf failed to install the base system.\e[0m\n"
        cleanup_mounts
        exit 1
    fi

	printf "\nGenerating fstab with UUIDs.\n"
	
	# Create minimal fstab using blkid for UUIDs
	> /mnt/etc/fstab
	
	# Add root partition
	root_uuid=$(blkid -s UUID -o value "$root_part")
	if [[ -n "$root_uuid" ]]; then
		printf "UUID=%s / %s defaults 0 1\n" "$root_uuid" "$filesystem" >> /mnt/etc/fstab
	else
		printf "\n\e[1;31mError: Could not get UUID for root partition.\e[0m\n"
		exit 1
	fi
	
	# Add swap partition
	swap_uuid=$(blkid -s UUID -o value "$swap_part")
	if [[ -n "$swap_uuid" ]]; then
		printf "UUID=%s none swap sw 0 0\n" "$swap_uuid" >> /mnt/etc/fstab
	else
		printf "\n\e[1;31mError: Could not get UUID for swap partition.\e[0m\n"
		exit 1
	fi
	
	# Add UEFI partition
	uefi_uuid=$(blkid -s UUID -o value "$uefi_part")
	if [[ -n "$uefi_uuid" ]]; then
		printf "UUID=%s /boot/efi vfat defaults 0 2\n" "$uefi_uuid" >> /mnt/etc/fstab
	else
		printf "\n\e[1;31mError: Could not get UUID for UEFI partition.\e[0m\n"
		exit 1
	fi
	
	printf "\nCopying required files to rootfs.\n"
	
	# Copy /etc/resolv.conf for DNS in chroot
	mkdir -p /mnt/etc
	cp /etc/resolv.conf /mnt/etc/
	
	printf "\nPreparing chroot environment.\n"
	
	# Extract disk device from root partition
	# Works for: /dev/nvme0n1p5 → /dev/nvme0n1, /dev/sda1 → /dev/sda, /dev/mmcblk0p2 → /dev/mmcblk0
	disk=$(echo "$root_part" | sed 's/p\?[0-9]*$//')
	
	# Extract partition number from root partition
	# Works for: /dev/nvme0n1p5 → 5, /dev/sda1 → 1, /dev/mmcblk0p2 → 2
	part_num=$(echo "$root_part" | sed 's/.*[^0-9]//')
	
	# Extract partition number from UEFI partition
	# Works for: /dev/nvme0n1p1 → 1, /dev/sda1 → 1
	uefi_part_num=$(echo "$uefi_part" | sed 's/.*[^0-9]//')
	printf "DEBUG: uefi_part=$uefi_part → uefi_part_num=$uefi_part_num\n"
	
	# Get ROOT_UUID for GRUB configuration
	root_uuid=$(blkid -s UUID -o value "$root_part")
	if [[ -z "$root_uuid" ]]; then
		printf "\n\e[1;31mError: Could not retrieve UUID for root partition.\e[0m\n"
		exit 1
	fi
	
	# Mount necessary filesystems for chroot
	mount --bind /dev /mnt/dev
	mount --bind /dev/pts /mnt/dev/pts
	mount --bind /proc /mnt/proc
	mount --bind /sys /mnt/sys
	mount --bind /run /mnt/run
	mount --bind /sys/firmware/efi/efivars /mnt/sys/firmware/efi/efivars 2>/dev/null || true
	
	printf "\nDownloading fedora-2.sh from GitHub.\n"
    curl -fsS --max-time 5 -H "Cache-Control: no-cache, no-store" -H "Pragma: no-cache" "https://raw.githubusercontent.com/georgeabr/fedora-installer/main/fedora-2.sh?_=$(date +%s)" > fedora-2.sh; \
 		chmod +x fedora-2.sh; cp ./fedora-2.sh /mnt; \
		chroot /mnt /bin/bash -c "./fedora-2.sh \"$hostname\" \"$username\" \"$disk\" \"$part_num\" \"$root_uuid\" \"$releasever\" \"$profile_choice\" \"$uefi_part_num\"";
    if [[ $? -ne 0 ]]; then
        printf "\n\e[1;31mError: fedora-2.sh failed inside the chroot.\e[0m\n"
        cleanup_mounts
        exit 1
    fi
   	# Delete after chroot exits
    	rm -f /mnt/fedora-2.sh
	
	
	cleanup_mounts
	
	printf "\n\e[1;32mFedora installation complete! Reboot to test the new system.\e[0m\n"
}

# This is the entry point for the script, validating parameters
if is_disk_partition_format "$1" && is_disk_partition_format "$2" && is_disk_partition_format "$3";
then
	start_install "$1" "$2" "$3";
else
  printf "\n\e[1;31mError: Missing or invalid arguments.\e[0m\n"
  arg_labels=("UEFI-PART" "ROOT-PART" "SWAP-PART")
  for i in 1 2 3; do
    arg_val="${!i}"
    if [[ -z "$arg_val" ]]; then
      printf "  - %-10s not provided\n" "${arg_labels[$((i-1))]}"
    elif ! is_disk_partition_format "$arg_val"; then
      printf "  - %-10s '%s' is not in DISK-PART format (e.g. '1-1')\n" "${arg_labels[$((i-1))]}" "$arg_val"
    fi
  done
  printf "\n"
  show_instructions;
  exit 1;
fi
