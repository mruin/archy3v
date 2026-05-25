#!/bin/bash
# ==============================================================================
# archy3v Post-Installation Chroot Script
# ==============================================================================

set -e

# Target parameters passed from host script
USERNAME="$1"
HOSTNAME="$2"
ZRAM_SIZE_GB="$3"
KERNEL_FLAVOR="$4"
DE_CHOICE="$5"

echo "================================================================================"
echo " Starting post-install configuration inside chroot..."
echo "================================================================================"

# 1. Localization & Clock
echo "--> Configuring timezone and locale..."
ln -sf /usr/share/zoneinfo/Europe/Rome /etc/localtime
hwclock --systohc

echo "it_IT.UTF-8 UTF-8" > /etc/locale.gen
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen

echo "LANG=it_IT.UTF-8" > /etc/locale.conf
echo "KEYMAP=it" > /etc/vconsole.conf

# 2. Hostname & Network
echo "--> Configuring hostname..."
echo "$HOSTNAME" > /etc/hostname
cat <<EOF > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF

# 3. Users & Privileges
echo "--> Setting passwords and creating user..."
echo "Imposta la password di ROOT:"
passwd

echo "Creazione dell'utente $USERNAME..."
useradd -m -G wheel,sys,audio,video,storage,power -s /bin/bash "$USERNAME"
echo "Imposta la password per l'utente $USERNAME:"
passwd "$USERNAME"

# Allow wheel group sudo privileges
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/10-wheel

# 4. CPU Microcode Detection & Installation
echo "--> Detecting CPU for microcode..."
if grep -q "GenuineIntel" /proc/cpuinfo; then
    echo "Intel CPU detected. Installing intel-ucode..."
    pacman -S --noconfirm intel-ucode
elif grep -q "AuthenticAMD" /proc/cpuinfo; then
    echo "AMD CPU detected. Installing amd-ucode..."
    pacman -S --noconfirm amd-ucode
fi

# 5. Graphics Drivers Detection & Installation
echo "--> Detecting GPU for drivers..."
GPU_INFO=$(lspci | grep -i -E "vga|3d")
if echo "$GPU_INFO" | grep -q -i "nvidia"; then
    echo "Nvidia GPU detected. Installing Nvidia drivers..."
    pacman -S --noconfirm nvidia nvidia-utils nvidia-settings
elif echo "$GPU_INFO" | grep -q -i "amd"; then
    echo "AMD GPU detected. Installing AMD drivers..."
    pacman -S --noconfirm mesa lib32-mesa xf86-video-amdgpu vulkan-radeon
elif echo "$GPU_INFO" | grep -q -i "intel"; then
    echo "Intel GPU detected. Installing Intel drivers..."
    pacman -S --noconfirm mesa vulkan-intel intel-media-driver
else
    echo "Generic/Virtual GPU detected. Installing fallback drivers..."
    pacman -S --noconfirm mesa
fi

# 6. Zram Setup (systemd-zram-generator)
echo "--> Configuring Zram ($ZRAM_SIZE_GB GB)..."
pacman -S --noconfirm systemd-zram-generator
ZRAM_SIZE_MB=$((ZRAM_SIZE_GB * 1024))
sed "s/@ZRAM_SIZE_MB@/$ZRAM_SIZE_MB/g" /root/zram-generator.conf.template > /etc/systemd/zram-generator.conf
rm -f /root/zram-generator.conf.template

# 7. Temporarily grant passwordless sudo for paru installation
echo "--> Installing paru AUR helper..."
echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/99-temp-sudo

# Build and install paru-bin as the created user
sudo -u "$USERNAME" bash -c "
  cd /home/$USERNAME
  git clone https://aur.archlinux.org/paru-bin.git
  cd paru-bin
  makepkg -si --noconfirm
"
rm -rf "/home/$USERNAME/paru-bin"

# 8. Install AUR Dependencies (Limine Snapper Sync & Hooks)
echo "--> Installing Limine Snapper Sync & mkinitcpio hooks from AUR..."
sudo -u "$USERNAME" paru -S --noconfirm limine-snapper-sync limine-mkinitcpio-hook snapper

# Remove temporary passwordless sudo privileges
rm -f /etc/sudoers.d/99-temp-sudo

# 9. Snapper Layout Configuration
echo "--> Configuring Snapper..."
# Get the root Btrfs device name
ROOT_DEV=$(findmnt -n -o SOURCE /)

# Initialize snapper config for /
# This will temporarily fail to create /.snapshots directory if it's already mounted,
# but we intentionally didn't mount it in the host script yet.
snapper -c root create-config /

# Delete the default folder created by snapper
umount /.snapshots 2>/dev/null || true
rm -rf /.snapshots
mkdir /.snapshots

# Mount the subvolume @snapshots to /.snapshots
mount -t btrfs -o subvol=@snapshots "$ROOT_DEV" /.snapshots
chmod 750 /.snapshots

# Add Btrfs snapshots mount point to fstab
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_DEV")
echo "UUID=$ROOT_UUID /.snapshots btrfs subvol=@snapshots,noatime,compress=zstd:3,ssd 0 0" >> /etc/fstab

# Allow the user to manage snapshots without sudo
snapper -c root set-config "ALLOW_USERS=$USERNAME"
chown -R :wheel /.snapshots

# Configure Snapper limits to be capped at 10 snapshots total
# Set hourly=5, daily=5, others=0
sed -i 's/TIMELINE_LIMIT_HOURLY="[0-9]*"/TIMELINE_LIMIT_HOURLY="5"/' /etc/snapper/configs/root
sed -i 's/TIMELINE_LIMIT_DAILY="[0-9]*"/TIMELINE_LIMIT_DAILY="5"/' /etc/snapper/configs/root
sed -i 's/TIMELINE_LIMIT_WEEKLY="[0-9]*"/TIMELINE_LIMIT_WEEKLY="0"/' /etc/snapper/configs/root
sed -i 's/TIMELINE_LIMIT_MONTHLY="[0-9]*"/TIMELINE_LIMIT_MONTHLY="0"/' /etc/snapper/configs/root
sed -i 's/TIMELINE_LIMIT_YEARLY="[0-9]*"/TIMELINE_LIMIT_YEARLY="0"/' /etc/snapper/configs/root

# 10. Configure mkinitcpio Btrfs overlayfs hook
echo "--> Configuring mkinitcpio hooks for read-only snapshot booting..."
if ! grep -q "btrfs-overlayfs" /etc/mkinitcpio.conf; then
    sed -i 's/\(filesystems\)/\1 btrfs-overlayfs/' /etc/mkinitcpio.conf
fi
mkinitcpio -P

# 11. Bootloader Installation & Setup (Limine)
echo "--> Installing and configuring Limine Bootloader..."
if [ -d "/sys/firmware/efi" ]; then
    echo "UEFI mode detected. Deploying Limine UEFI..."
    mkdir -p /boot/EFI/BOOT
    cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI
    
    # Register boot entry in NVRAM
    ESP_DEV=$(findmnt -n -o SOURCE /boot)
    ESP_DISK=$(lsblk -no PKNAME "$ESP_DEV")
    ESP_DISK="/dev/$ESP_DISK"
    ESP_PART_NUM=$(lsblk -no PARTNUM "$ESP_DEV")
    
    efibootmgr --create --disk "$ESP_DISK" --part "$ESP_PART_NUM" --label "Arch Linux (Limine)" --loader '\EFI\BOOT\BOOTX64.EFI' --unicode || true
else
    echo "BIOS mode detected. Deploying Limine BIOS..."
    ROOT_DISK=$(lsblk -no PKNAME "$ROOT_DEV")
    ROOT_DISK="/dev/$ROOT_DISK"
    
    mkdir -p /boot/limine
    cp /usr/share/limine/limine-bios.sys /boot/limine/
    limine bios-install "$ROOT_DISK"
fi

# Generate machine-id if missing, then retrieve it
[ -s /etc/machine-id ] || systemd-machine-id-setup
MACHINE_ID=$(cat /etc/machine-id)

# Set Kernel Friendly name based on flavor
case "$KERNEL_FLAVOR" in
    linux) KERNEL_NAME="Arch Linux" ;;
    linux-zen) KERNEL_NAME="Arch Linux Zen" ;;
    linux-lts) KERNEL_NAME="Arch Linux LTS" ;;
    *) KERNEL_NAME="Arch Linux" ;;
esac

# Windows Dual-Boot Detection
WINDOWS_ENTRY=""
if [ -f "/boot/EFI/Microsoft/Boot/bootmgfw.efi" ]; then
    echo "Windows Boot Manager detected. Integrating dual-boot..."
    WINDOWS_ENTRY=$(cat <<EOF

/Windows
    protocol: efi
    path: boot():/EFI/Microsoft/Boot/bootmgfw.efi
EOF
)
fi

# Prepare and write limine.conf
sed -e "s/@MACHINE_ID@/$MACHINE_ID/g" \
    -e "s/@ROOT_UUID@/$ROOT_UUID/g" \
    -e "s/@KERNEL_FLAVOR@/$KERNEL_FLAVOR/g" \
    -e "s/@KERNEL_NAME@/$KERNEL_NAME/g" \
    -e "@/WINDOWS_ENTRY@/r /dev/stdin" \
    -e "@/WINDOWS_ENTRY@/d" \
    /root/limine.conf.template > /boot/limine.conf <<< "$WINDOWS_ENTRY"

rm -f /root/limine.conf.template

# Configure limine-snapper-sync settings in /etc/default/limine
echo "ESP_PATH=/boot" >> /etc/default/limine
echo "MAX_SNAPSHOT_ENTRIES=10" >> /etc/default/limine

# Sync snapshot entries and enable automatic updater services
limine-snapper-sync
systemctl enable limine-snapper-sync.service
systemctl enable snapper-timeline.timer
systemctl enable snapper-cleanup.timer

# 12. Desktop Environment Installation
echo "--> Installing Audio server (Pipewire)..."
pacman -S --noconfirm pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber

echo "--> Installing Desktop Environment ($DE_CHOICE)..."
case "$DE_CHOICE" in
    gnome)
        pacman -S --noconfirm gnome gnome-extra gdm
        systemctl enable gdm.service
        ;;
    kde)
        pacman -S --noconfirm plasma-desktop sddm kde-applications
        systemctl enable sddm.service
        ;;
    hyprland)
        pacman -S --noconfirm hyprland kitty sddm waybar
        systemctl enable sddm.service
        ;;
    xfce)
        pacman -S --noconfirm xfce4 xfce4-goodies lightdm lightdm-gtk-greeter
        systemctl enable lightdm.service
        ;;
    cli)
        echo "Minimal CLI installation chosen. No Desktop Environment will be installed."
        ;;
esac

echo "================================================================================"
echo " Post-install configuration inside chroot completed successfully!"
echo "================================================================================"
exit 0
