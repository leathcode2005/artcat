#!/usr/bin/env bash
# =============================================================================
#  SCRIPT 1 — Artix Linux Minimal Installer
#  AMD RX 7800 XT / dinit / rEFInd
#
#  Run this from the Artix live ISO (booted in UEFI mode):
#    curl -O https://your-host/01-artix-install.sh
#    bash 01-artix-install.sh
#
#  What it does:
#    - Partitions your target disk (EFI + swap + root)
#    - Formats and mounts filesystems
#    - Installs base Artix system with dinit
#    - Configures locale, timezone, hostname, users
#    - Installs rEFInd (NO grub)
#    - Writes refind_linux.conf with AMD kernel params
#    - Enables NetworkManager via dinit
#    - Copies script 2 into the new system ready to run after reboot
#
#  EDIT THE VARIABLES BELOW BEFORE RUNNING.
# =============================================================================

set -euo pipefail

# ── USER CONFIGURATION ────────────────────────────────────────────────────────
# DISK is selected interactively at runtime — see Disk Selection section below
EFI_SIZE="512M"              # EFI partition size
SWAP_SIZE="8G"               # Swap partition size
                             # Root gets the remainder of the disk

TARGET_HOSTNAME="artix-gaming"
TIMEZONE="America/Chicago"   # e.g. Europe/London, Asia/Tokyo
LOCALE="en_US.UTF-8"
KEYMAP="us"

# USERNAME is prompted interactively — see User Setup section below
# Passwords are prompted interactively — not stored in this script
# ─────────────────────────────────────────────────────────────────────────────

# ── COLOUR HELPERS ────────────────────────────────────────────────────────────
RED='\033[0;31m'; ORANGE='\033[0;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}${BOLD}[INFO]${RESET}  $*"; }
ok()      { echo -e "${GREEN}${BOLD}[ OK ]${RESET}  $*"; }
warn()    { echo -e "${ORANGE}${BOLD}[WARN]${RESET}  $*"; }
section() { echo -e "\n${RED}${BOLD}══ $* ══${RESET}\n"; }
die()     { echo -e "${RED}${BOLD}[FAIL]${RESET}  $*" >&2; exit 1; }

# ── PRE-FLIGHT ────────────────────────────────────────────────────────────────
section "Pre-flight checks"

[[ $EUID -ne 0 ]] && die "Run as root from the Artix live ISO."

ls /sys/firmware/efi/efivars &>/dev/null \
  || die "Not booted in UEFI mode. Disable CSM/legacy in BIOS and retry."

ping -c1 artixlinux.org &>/dev/null \
  || die "No internet connection. Connect via ethernet or run connmanctl first."

# ── Dependency check
info "Checking required tools..."
MISSING=()
for cmd in parted mkfs.fat mkswap mkfs.ext4 blkid partprobe lsblk basestrap artix-chroot fstabgen; do
  command -v "$cmd" &>/dev/null || MISSING+=("$cmd")
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
  die "Missing required tools: ${MISSING[*]}. Install them before running this script."
fi
ok "All required tools found."

# ── USER SETUP ────────────────────────────────────────────────────────────
section "User Setup"

read -rp "Enter the username for the new user: " USERNAME
[[ -n "$USERNAME" ]] || die "Username cannot be empty."
USERNAME="${USERNAME,,}"  # convert to lowercase
[[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Invalid username '${USERNAME}'. Use lowercase letters, digits, hyphens, or underscores."
[[ ${#USERNAME} -le 32 ]] || die "Username '${USERNAME}' is too long (max 32 chars)."
ok "Username set: $USERNAME"

# ── DISK SELECTION ────────────────────────────────────────────────────────────
section "Disk Selection"

echo "Available block devices:"
lsblk -dpno NAME,SIZE,MODEL | grep -v "loop" || true
echo
read -rp "Enter the target disk (e.g. /dev/nvme0n1, /dev/sda): " DISK
[[ -b "$DISK" ]] || die "Disk $DISK not found."

info "Disk:     $DISK"
info "Hostname: $TARGET_HOSTNAME"
info "User:     $USERNAME"
info "TZ:       $TIMEZONE"
echo
warn "THIS WILL ERASE ALL DATA ON $DISK"
read -rp "Type YES to continue: " confirm
[[ "$confirm" == "YES" ]] || die "Aborted."

# ── PARTITIONING ──────────────────────────────────────────────────────────────
section "Partitioning $DISK"

# Derive partition device names (handles both /dev/sdX and /dev/nvmeXnY)
if [[ "$DISK" == *nvme* || "$DISK" == *mmcblk* ]]; then
  PART_EFI="${DISK}p1"
  PART_SWAP="${DISK}p2"
  PART_ROOT="${DISK}p3"
else
  PART_EFI="${DISK}1"
  PART_SWAP="${DISK}2"
  PART_ROOT="${DISK}3"
fi

info "Creating GPT partition table..."
parted -s "$DISK" mklabel gpt

# Compute exact partition boundaries from EFI_SIZE and SWAP_SIZE (all in MiB for consistency)
EFI_MIB="${EFI_SIZE//[Mm]*/}"                      # numeric MiB value of EFI partition
SWAP_MIB="$((${SWAP_SIZE//[Gg]*/} * 1024))"        # SWAP_SIZE converted to MiB
SWAP_START="${EFI_MIB}MiB"                         # swap begins right after EFI
SWAP_END="$((EFI_MIB + SWAP_MIB))MiB"             # swap ends at EFI + SWAP size

info "Creating EFI partition ($EFI_SIZE)..."
parted -s "$DISK" mkpart ESP fat32 1MiB "${EFI_MIB}MiB"
parted -s "$DISK" set 1 esp on

info "Creating swap partition ($SWAP_SIZE)..."
parted -s "$DISK" mkpart swap linux-swap "$SWAP_START" "$SWAP_END"

info "Creating root partition (remaining space)..."
parted -s "$DISK" mkpart root ext4 "$SWAP_END" 100%

ok "Partition table written."
parted -s "$DISK" print

# Allow the kernel to re-read the new partition table before formatting
sleep 1
partprobe "$DISK" 2>/dev/null || true
sleep 1

# ── FORMAT ────────────────────────────────────────────────────────────────────
section "Formatting partitions"

info "Formatting EFI partition as FAT32..."
mkfs.fat -F32 "$PART_EFI"

info "Initialising swap..."
mkswap "$PART_SWAP"
swapon "$PART_SWAP"

info "Formatting root as ext4..."
mkfs.ext4 -F "$PART_ROOT"

ok "Formatting complete."

# ── MOUNT ─────────────────────────────────────────────────────────────────────
section "Mounting filesystems"

mount "$PART_ROOT" /mnt
mkdir -p /mnt/boot/efi
mount "$PART_EFI" /mnt/boot/efi

ok "Mounted: $PART_ROOT → /mnt"
ok "Mounted: $PART_EFI  → /mnt/boot/efi"

# ── BASESTRAP ─────────────────────────────────────────────────────────────────
section "Installing base system (basestrap)"

info "This may take a few minutes..."

basestrap /mnt \
  base base-devel \
  dinit dinit-rc \
  linux linux-headers \
  linux-firmware-amdgpu linux-firmware-whence \
  amd-ucode \
  networkmanager networkmanager-dinit \
  neovim git curl wget bash-completion \
  efibootmgr refind \
  doas \
  sudo

ok "Base system installed."

# ── FSTAB ─────────────────────────────────────────────────────────────────────
section "Generating fstab"

fstabgen -U /mnt >> /mnt/etc/fstab
info "Generated /etc/fstab:"
cat /mnt/etc/fstab

# ── CHROOT CONFIGURATION ──────────────────────────────────────────────────────
section "Configuring system (chroot)"

# Pass variables into the chroot environment
artix-chroot /mnt /bin/bash <<CHROOT
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()  { echo -e "\${CYAN}\${BOLD}[INFO]\${RESET}  \$*"; }
ok()    { echo -e "\${GREEN}\${BOLD}[ OK ]\${RESET}  \$*"; }

# ── Timezone
info "Setting timezone: ${TIMEZONE}"
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc
ok "Timezone set."

# ── Locale
info "Configuring locale: ${LOCALE}"
sed -i "s/#${LOCALE//./\\.}/${LOCALE}/" /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf
ok "Locale set."

# ── Hostname
info "Setting hostname: ${TARGET_HOSTNAME}"
echo "${TARGET_HOSTNAME}" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${TARGET_HOSTNAME}.localdomain ${TARGET_HOSTNAME}
EOF
ok "Hostname set."

# ── mkinitcpio with early amdgpu KMS
info "Configuring mkinitcpio (early amdgpu KMS)..."
sed -i 's/^MODULES=.*/MODULES=(amdgpu)/' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block filesystems keyboard fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P
ok "initramfs built with amdgpu."

# ── Root password (done outside heredoc — passwd needs an interactive TTY)

# ── Create user
info "Creating user: ${USERNAME}"
useradd -mG wheel,audio,video,input,storage,games -s /bin/bash "${USERNAME}"

# ── Sudo
sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
ok "Sudo configured for wheel group."

# ── Doas
info "Configuring doas for wheel group..."
cat > /etc/doas.conf <<DOAS
permit persist :wheel
DOAS
chown root:root /etc/doas.conf
chmod 0400 /etc/doas.conf
[[ -s /etc/doas.conf ]] || { echo "FAIL: /etc/doas.conf is empty"; exit 1; }
ok "Doas configured for wheel group."

# ── NetworkManager via dinit
info "Enabling NetworkManager service..."
ln -sf /etc/dinit.d/NetworkManager /etc/dinit.d/boot.d/
ok "NetworkManager enabled."

# ── rEFInd install
info "Installing rEFInd to EFI partition..."
refind-install
ok "rEFInd installed and registered with UEFI firmware."

# ── refind_linux.conf — get root PARTUUID
ROOT_PARTUUID=\$(blkid -s PARTUUID -o value ${PART_ROOT})
info "Root PARTUUID: \${ROOT_PARTUUID}"

cat > /boot/refind_linux.conf <<EOF
"Artix Linux (default)"  "root=PARTUUID=\${ROOT_PARTUUID} rw quiet amdgpu.ppfeaturemask=0xffffffff amd_pstate=active iommu=pt initrd=/boot/amd-ucode.img initrd=/boot/initramfs-linux.img"
"Artix Linux (fallback)" "root=PARTUUID=\${ROOT_PARTUUID} rw initrd=/boot/amd-ucode.img initrd=/boot/initramfs-linux-fallback.img"
EOF
ok "refind_linux.conf written."

CHROOT

# ── Set passwords interactively (passwd requires a real TTY, cannot run inside heredoc)
echo
info "Set ROOT password:"
artix-chroot /mnt passwd

echo
info "Set password for ${USERNAME}:"
artix-chroot /mnt passwd "${USERNAME}"

# ── COPY SCRIPT 2 INTO NEW SYSTEM ────────────────────────────────────────────
section "Staging script 2 for post-reboot"

# Copy script 2 if it exists alongside this script, otherwise note it
SCRIPT2_SRC="$(dirname "$(realpath "$0")")/02-gaming-setup.sh"
if [[ -f "$SCRIPT2_SRC" ]]; then
  cp "$SCRIPT2_SRC" /mnt/home/"$USERNAME"/02-gaming-setup.sh
  chmod +x /mnt/home/"$USERNAME"/02-gaming-setup.sh
  artix-chroot /mnt chown "$USERNAME:$USERNAME" /home/"$USERNAME"/02-gaming-setup.sh 2>/dev/null || true
  ok "02-gaming-setup.sh copied to /home/$USERNAME/"
else
  warn "02-gaming-setup.sh not found next to this script."
  warn "Copy it manually to the new system before running."
fi

# ── UNMOUNT & REBOOT ──────────────────────────────────────────────────────────
section "Done — unmounting and rebooting"

swapoff "$PART_SWAP"
umount -R /mnt

echo
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║  Artix installation complete!                    ║${RESET}"
echo -e "${GREEN}${BOLD}║                                                  ║${RESET}"
echo -e "${GREEN}${BOLD}║  1. Remove the USB drive                         ║${RESET}"
echo -e "${GREEN}${BOLD}║  2. System will reboot into rEFInd               ║${RESET}"
printf  "${GREEN}${BOLD}║  3. Log in as: %-32s║${RESET}\n" "$USERNAME"
echo -e "${GREEN}${BOLD}║  4. Run: bash ~/02-gaming-setup.sh               ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════╝${RESET}"
echo

read -rp "Press ENTER to reboot now (or Ctrl+C to stay in live env)..."
reboot
