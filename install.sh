#!/bin/bash
# ==============================================================================
# archy3v Arch Linux Automatic/Interactive Installer Script
# ==============================================================================

set -e

# Clear screen and show header
clear
echo "================================================================================"
echo "                   Arch Linux Installer Script - archy3v"
echo "================================================================================"
echo " Questo script automatizza l'installazione di Arch Linux con:"
echo " - Bootloader Limine"
echo " - File system Btrfs con Snapper (limite di 10 snapshot)"
echo " - Zram configurabile dallo spazio scelto dall'utente"
echo " - Supporto hardware completo ed integrazione dual-boot con Windows"
echo "================================================================================"
echo ""

# 1. Verification of boot mode (UEFI is recommended, but we support both)
if [ -d "/sys/firmware/efi" ]; then
    echo "[INFO] Sistema avviato in modalità UEFI."
    BOOT_MODE="UEFI"
else
    echo "[WARNING] Sistema avviato in modalità Legacy BIOS. Alcune funzionalità come il dual-boot potrebbero variare."
    BOOT_MODE="BIOS"
fi

# Check internet connection
if ! ping -c 1 archlinux.org &>/dev/null; then
    echo "[ERROR] Connessione internet non attiva. Connettiti prima di eseguire lo script."
    exit 1
fi

# Check and download helper scripts if running standalone
if [ ! -f "scripts/chroot_install.sh" ] || [ ! -f "scripts/configs/limine.conf.template" ] || [ ! -f "scripts/configs/zram-generator.conf.template" ]; then
    echo "[INFO] File di supporto non rilevati in locale. Download da GitHub in corso..."
    read -p "Inserisci il tuo username GitHub [default: mruin]: " GH_USER
    GH_USER=${GH_USER:-mruin}
    
    mkdir -p scripts/configs
    
    echo "Scaricamento di chroot_install.sh..."
    curl -sL "https://raw.githubusercontent.com/${GH_USER}/archy3v/main/scripts/chroot_install.sh" -o scripts/chroot_install.sh
    
    echo "Scaricamento di limine.conf.template..."
    curl -sL "https://raw.githubusercontent.com/${GH_USER}/archy3v/main/scripts/configs/limine.conf.template" -o scripts/configs/limine.conf.template
    
    echo "Scaricamento di zram-generator.conf.template..."
    curl -sL "https://raw.githubusercontent.com/${GH_USER}/archy3v/main/scripts/configs/zram-generator.conf.template" -o scripts/configs/zram-generator.conf.template
    
    if [ ! -f "scripts/chroot_install.sh" ]; then
        echo "[ERROR] Impossibile scaricare i file di supporto. Controlla lo username e la connessione."
        exit 1
    fi
    chmod +x scripts/chroot_install.sh
    echo "[SUCCESS] File di supporto scaricati con successo."
fi

# 2. Interactive configuration gathering
echo ""
echo "=== CONFIGURAZIONE DI BASE ==="
read -p "Inserisci il nome host (Hostname) per questa macchina: " HOSTNAME
read -p "Inserisci il nome utente (Username): " USERNAME

# Normalize username (lowercase, alphanumeric)
USERNAME=$(echo "$USERNAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')
if [ -z "$USERNAME" ]; then
    echo "[ERROR] Nome utente non valido."
    exit 1
fi

# Zram size
read -p "Inserisci la dimensione desiderata per la Zram in GB (es. 4, 8, 16): " ZRAM_SIZE_GB
if ! [[ "$ZRAM_SIZE_GB" =~ ^[0-9]+$ ]] || [ "$ZRAM_SIZE_GB" -le 0 ]; then
    echo "Dimensione non valida, verrà utilizzato il default di 8 GB."
    ZRAM_SIZE_GB=8
fi

# Kernel selection
echo ""
echo "=== SELEZIONE KERNEL ==="
echo "Scegli il kernel da installare:"
echo "1) Standard Linux Kernel (Consigliato)"
echo "2) Linux Zen Kernel (Ottimizzato per desktop/gaming)"
echo "3) Linux LTS Kernel (Long-Term Support, massima stabilità)"
read -p "Scegli un'opzione (1-3) [default: 1]: " KERNEL_OPZ
case "$KERNEL_OPZ" in
    2) KERNEL_FLAVOR="linux-zen" ;;
    3) KERNEL_FLAVOR="linux-lts" ;;
    *) KERNEL_FLAVOR="linux" ;;
esac

# Desktop Environment selection
echo ""
echo "=== SELEZIONE DESKTOP ENVIRONMENT ==="
echo "Scegli l'ambiente grafico da installare:"
echo "1) GNOME"
echo "2) KDE Plasma"
echo "3) Hyprland (Wayland compositor)"
echo "4) XFCE (Leggero)"
echo "5) Solo CLI (Installazione minima a riga di comando)"
read -p "Scegli un'opzione (1-5) [default: 1]: " DE_OPZ
case "$DE_OPZ" in
    2) DE_CHOICE="kde" ;;
    3) DE_CHOICE="hyprland" ;;
    4) DE_CHOICE="xfce" ;;
    5) DE_CHOICE="cli" ;;
    *) DE_CHOICE="gnome" ;;
esac

# 3. Disk selection & Partitioning Mode
echo ""
echo "=== SELEZIONE DISCO ==="
echo "Dischi disponibili:"
lsblk -dno NAME,SIZE,MODEL | grep -v "loop"
echo ""
read -p "Inserisci il nome del disco su cui installare (es. sda, nvme0n1): " DISK_NAME
DISK_DEV="/dev/$DISK_NAME"

if [ ! -b "$DISK_DEV" ]; then
    echo "[ERROR] Il disco $DISK_DEV non esiste."
    exit 1
fi

echo ""
echo "=== MODALITÀ DI PARTIZIONAMENTO ==="
echo "Scegli come partizionare il disco:"
echo "1) Cancella l'intero disco e partiziona automaticamente (CREA TABELLA GPT, 4GB ESP, resto ROOT)"
echo "2) Partizionamento manuale (Avvia cfdisk, utile per dual-boot con Windows da preservare)"
read -p "Scegli un'opzione (1-2): " PART_MODE

FORMAT_ESP_DECISION="s"

if [ "$PART_MODE" = "1" ]; then
    echo "[WARNING] Questo cancellerà TUTTI i dati su $DISK_DEV. Sei sicuro? (s/N)"
    read -p "> " CONFIRM_WIPE
    if [ "$CONFIRM_WIPE" != "s" ] && [ "$CONFIRM_WIPE" != "S" ]; then
        echo "Installazione annullata."
        exit 1
    fi

    echo "Partizionamento automatico in corso..."
    # Clear partition table
    sgdisk --zap-all "$DISK_DEV"

    # Create partitions
    # 1: EFI System Partition (4GB)
    # 2: Root Btrfs (Remaining space)
    sgdisk --new=1:0:+4G --typecode=1:EF00 --change-name=1:"EFI System Partition" "$DISK_DEV"
    sgdisk --new=2:0:0 --typecode=2:8300 --change-name=2:"Arch Linux Root" "$DISK_DEV"

    # Refresh partition list
    partprobe "$DISK_DEV"
    sleep 2

    # Resolve partition paths
    if [[ "$DISK_DEV" == *nvme* || "$DISK_DEV" == *mmcblk* || "$DISK_DEV" == *loop* ]]; then
        ESP_PART="${DISK_DEV}p1"
        BTRFS_PART="${DISK_DEV}p2"
    else
        ESP_PART="${DISK_DEV}1"
        BTRFS_PART="${DISK_DEV}2"
    fi
else
    # Manual partitioning using cfdisk
    echo "Avvio di cfdisk su $DISK_DEV..."
    cfdisk "$DISK_DEV"

    echo ""
    echo "Configura le partizioni create/esistenti:"
    read -p "Inserisci il percorso della partizione EFI (es. /dev/sda1 o /dev/nvme0n1p1): " ESP_PART
    read -p "Inserisci il percorso della partizione Root Btrfs (es. /dev/sda2 o /dev/nvme0n1p2): " BTRFS_PART

    if [ ! -b "$ESP_PART" ] || [ ! -b "$BTRFS_PART" ]; then
        echo "[ERROR] Una o entrambe le partizioni non esistono."
        exit 1
    fi

    echo ""
    echo "Vuoi formattare la partizione EFI $ESP_PART? (s/N)"
    echo "ATTENZIONE: Scegli 'n' se hai un sistema Windows in dual-boot ed usi lo stesso ESP!"
    read -p "> " FORMAT_ESP_DECISION
fi

# 4. Format partitions
echo ""
echo "=== FORMATTAZIONE DELLE PARTIZIONI ==="
if [ "$FORMAT_ESP_DECISION" = "s" ] || [ "$FORMAT_ESP_DECISION" = "S" ]; then
    echo "Formattazione della partizione EFI $ESP_PART in FAT32..."
    mkfs.fat -F 32 "$ESP_PART"
else
    echo "Salto la formattazione della partizione EFI $ESP_PART (preservazione dati esistenti)."
fi

echo "Formattazione della partizione Root $BTRFS_PART in Btrfs..."
mkfs.btrfs -f "$BTRFS_PART"

# 5. Create Btrfs Subvolume layout
echo ""
echo "=== CONFIGURAZIONE SUBVOLUME BTRFS ==="
mount "$BTRFS_PART" /mnt

btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@pkg
btrfs subvolume create /mnt/@snapshots

umount /mnt

# Mount subvolumes with optimized parameters
mount -o subvol=@,noatime,compress=zstd:3,ssd "$BTRFS_PART" /mnt
mkdir -p /mnt/{home,var/log,var/cache/pacman/pkg,boot}

mount -o subvol=@home,noatime,compress=zstd:3,ssd "$BTRFS_PART" /mnt/home
mount -o subvol=@log,noatime,compress=zstd:3,ssd "$BTRFS_PART" /mnt/var/log
mount -o subvol=@pkg,noatime,compress=zstd:3,ssd "$BTRFS_PART" /mnt/var/cache/pacman/pkg

# Mount EFI System Partition to /boot (needed by Limine for kernels access)
mount "$ESP_PART" /mnt/boot

# 6. Bootstrap base system (pacstrap)
echo ""
echo "=== PACSTRAP IN CORSO ==="
echo "Installazione dei pacchetti base e del kernel $KERNEL_FLAVOR..."
pacstrap -K /mnt base base-devel linux-firmware git btrfs-progs neovim nano networkmanager sudo "$KERNEL_FLAVOR" "${KERNEL_FLAVOR}-headers"

# 7. Generate fstab
echo ""
echo "--> Generazione di /etc/fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# 8. Copy configuration templates and scripts to the new system
echo ""
echo "--> Copia degli script di configurazione in chroot..."
mkdir -p /mnt/root/scripts/configs
cp scripts/chroot_install.sh /mnt/root/
cp scripts/configs/limine.conf.template /mnt/root/limine.conf.template
cp scripts/configs/zram-generator.conf.template /mnt/root/zram-generator.conf.template

chmod +x /mnt/root/chroot_install.sh

# 9. Execute configuration script inside chroot
echo ""
echo "=== AVVIO CHROOT CONFIGURATION ==="
arch-chroot /mnt /root/chroot_install.sh "$USERNAME" "$HOSTNAME" "$ZRAM_SIZE_GB" "$KERNEL_FLAVOR" "$DE_CHOICE"

# 10. Clean up scripts
rm -f /mnt/root/chroot_install.sh

echo ""
echo "================================================================================"
echo " INSTALLAZIONE COMPLETATA CON SUCCESSO!"
echo "================================================================================"
echo " Puoi riavviare ora il sistema dando il comando: reboot"
echo " Al riavvio troverai il bootloader Limine pronto."
echo "================================================================================"
