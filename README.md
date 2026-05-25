# archy3v - Arch Linux Automated & Interactive Installer

`archy3v` è uno script modulare ed interattivo progettato per automatizzare l'installazione di Arch Linux su sistemi UEFI e BIOS, configurando un sistema moderno basato su **Btrfs**, **Snapper**, il bootloader **Limine** ed una gestione personalizzata di **Zram**.

## Caratteristiche principali

*   **Btrfs & Snapper**: Layout a subvolume pulito (`@`, `@home`, `@log`, `@pkg`, `@snapshots`) per ripristini facili. Limita gli snapshot a un massimo di **10** (5 orari, 5 giornalieri) per non saturare lo spazio su disco.
*   **Bootloader Limine**: Alternativa moderna e veloce a GRUB, con integrazione automatica con Snapper per avviare direttamente gli snapshot di sistema in caso di problemi (grazie al pacchetto `limine-snapper-sync` e all'hook `btrfs-overlayfs`).
*   **Dual-Boot automatico**: Se viene rilevato Windows Boot Manager nella partizione EFI, viene inserita automaticamente una voce di avvio nel menu di Limine.
*   **Zram personalizzabile**: Puoi definire lo spazio dedicato a Zram in GB durante l'installazione invece del 50% fisso impostato da archinstall.
*   **Installazione interattiva**: Consente di scegliere in tempo reale il Kernel (`linux`, `linux-zen`, `linux-lts`) e l'ambiente desktop preferito (GNOME, KDE Plasma, Hyprland, XFCE o CLI).
*   **Driver & Microcode**: Rilevamento automatico di CPU e GPU per installare rispettivamente il microcode ed i driver grafici dedicati (Nvidia, AMD, Intel).

---

## Come Usare lo Script

### 1. Avvia la Live ISO di Arch Linux
Assicurati che la macchina sia connessa ad internet. Puoi verificare con:
```bash
ping -c 3 archlinux.org
```

### 2. Scarica ed avvia lo script
Esegui i seguenti comandi per avviare l'installazione. Lo script `install.sh` scaricherà automaticamente tutti i file di supporto necessari da GitHub richiedendoti lo username durante l'esecuzione (oppure userà i file locali se hai clonato l'intera repository):

```bash
# Scarica lo script di installazione principale
curl -L https://raw.githubusercontent.com/tuo-username/archy3v/main/install.sh -o install.sh

# Rendi lo script eseguibile ed avvialo
chmod +x install.sh
./install.sh
```

> [!IMPORTANT]
> Ricorda di sostituire `tuo-username` nel link sopra con il tuo reale nome utente GitHub dopo aver caricato lo script sul tuo account.

---

## Opzioni di Partizionamento

Durante l'avvio, lo script ti chiederà di scegliere tra due modalità:

1.  **Guided Automatic Wipe**: Cancella interamente il disco selezionato creando una partizione EFI da 4 GiB (consigliata per ospitare i kernel degli snapshot) e una partizione Btrfs con il resto dello spazio.
2.  **Manual/Preserve**: Avvia l'utility interattiva `cfdisk` per partizionare manualmente e ti permette di definire quali partizioni esistenti usare per la EFI e per Arch, offrendo la possibilità di non formattare la partizione EFI per **preservare installazioni esistenti (es. Windows in Dual-Boot)**.

---

## Struttura del Progetto

```
archy3v/
├── README.md
├── install.sh                  # Script principale eseguito nella Live ISO
└── scripts/
    ├── chroot_install.sh       # Script post-installazione eseguito in chroot
    └── configs/
        ├── limine.conf.template           # Template per limine.conf
        └── zram-generator.conf.template   # Template per systemd-zram-generator.conf
```
