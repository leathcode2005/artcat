#!/usr/bin/env bash
# =============================================================================
#  SCRIPT 2 — AMD RX 7800 XT Gaming Setup
#  CachyOS Kernel · Mesa/RADV · Vulkan · dinit · Steam · Proton
#  GameMode · MangoHud · Hyprland Rice
#
#  Run this AFTER rebooting into your fresh Artix install:
#    bash ~/02-gaming-setup.sh
#
#  Run as your regular user (sudo access required — NOT as root directly).
# =============================================================================

set -euo pipefail

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

[[ $EUID -eq 0 ]] && die "Do NOT run as root. Run as your regular user with sudo access."

sudo -v || die "This script requires sudo access."

ping -c1 archlinux.org &>/dev/null \
  || die "No internet. Check: nmcli device status / nmcli device wifi connect <SSID> password <pass>"

info "Running as: $(whoami)"
info "Home:       $HOME"
echo
info "This script will install:"
info "  • CachyOS repos + linux-cachyos kernel (BORE+EEVDF)"
info "  • Mesa/AMDGPU open driver stack"
info "  • Vulkan/RADV + 32-bit libs"
info "  • dinit service configuration"
info "  • Gaming tools: GameMode, MangoHud, Steam, Proton-GE"
info "  • Hyprland rice: waybar, hyprpaper, rofi, dunst, kitty"
echo
read -rp "Press ENTER to begin or Ctrl+C to abort..."

# ═════════════════════════════════════════════════════════════════════════════
section "01 — System update"
# ═════════════════════════════════════════════════════════════════════════════

sudo pacman -Syu --noconfirm
ok "System updated."

# ═════════════════════════════════════════════════════════════════════════════
section "02 — CachyOS repositories"
# ═════════════════════════════════════════════════════════════════════════════

info "Detecting CPU x86-64 micro-architecture level..."
CPU_LEVEL=$(/lib/ld-linux-x86-64.so.2 --help 2>/dev/null \
  | grep -oP 'x86-64-v\K[0-9]' | sort -n | tail -1 || echo "2")

info "Detected: x86-64-v${CPU_LEVEL}"

# Check for Zen 4/5 (znver4 support)
if grep -q "znver4\|znver5" /proc/cpuinfo 2>/dev/null || \
   gcc -Q --help=target 2>/dev/null | grep -q "znver4\|znver5"; then
  CACHY_ARCH="znver4"
  info "AMD Zen 4/5 detected — will use znver4 optimised packages"
elif [[ "$CPU_LEVEL" -ge 3 ]]; then
  CACHY_ARCH="v${CPU_LEVEL}"
  info "Will use x86-64-${CACHY_ARCH} optimised packages"
else
  CACHY_ARCH=""
  warn "CPU is x86-64-v2 or lower — using base CachyOS repo only"
fi

info "Installing CachyOS keyring and mirrorlist..."
cd /tmp
curl -sO https://mirror.cachyos.org/cachyos-repo.tar.xz
tar xf cachyos-repo.tar.xz
cd cachyos-repo
sudo ./cachyos-repo.sh
cd ~

ok "CachyOS repositories added to /etc/pacman.conf."

sudo pacman -Sy --noconfirm
ok "Package databases synced."

# ═════════════════════════════════════════════════════════════════════════════
section "03 — CachyOS kernel (linux-cachyos)"
# ═════════════════════════════════════════════════════════════════════════════

info "Installing linux-cachyos (BORE+EEVDF scheduler)..."
sudo pacman -S --noconfirm linux-cachyos linux-cachyos-headers

info "Updating linux-firmware (RDNA3 requires latest blobs)..."
sudo pacman -S --noconfirm linux-firmware

info "Rebuilding initramfs for all kernels..."
sudo mkinitcpio -P

# Update refind_linux.conf to include cachyos entries
ROOT_PARTUUID=$(findmnt -n -o PARTUUID /)
info "Root PARTUUID: ${ROOT_PARTUUID}"

sudo tee /boot/refind_linux.conf > /dev/null <<EOF
"CachyOS BORE+EEVDF (default)" "root=PARTUUID=${ROOT_PARTUUID} rw quiet amdgpu.ppfeaturemask=0xffffffff amd_pstate=active iommu=pt initrd=/boot/amd-ucode.img initrd=/boot/initramfs-linux-cachyos.img"
"CachyOS (fallback)"           "root=PARTUUID=${ROOT_PARTUUID} rw initrd=/boot/amd-ucode.img initrd=/boot/initramfs-linux-cachyos-fallback.img"
"Artix linux (fallback)"       "root=PARTUUID=${ROOT_PARTUUID} rw initrd=/boot/amd-ucode.img initrd=/boot/initramfs-linux-fallback.img"
EOF

ok "refind_linux.conf updated with CachyOS kernel entries."

info "Verifying RDNA3 firmware blobs..."
NAVI32_COUNT=$(ls /usr/lib/firmware/amdgpu/navi32*.bin 2>/dev/null | wc -l)
if [[ "$NAVI32_COUNT" -gt 0 ]]; then
  ok "Found ${NAVI32_COUNT} navi32 firmware files."
else
  warn "navi32 firmware files not found — update linux-firmware manually if GPU issues occur."
fi

# ═════════════════════════════════════════════════════════════════════════════
section "04 — Gaming sysctl tweaks"
# ═════════════════════════════════════════════════════════════════════════════

sudo tee /etc/sysctl.d/99-gaming.conf > /dev/null <<'EOF'
# Reduce swap aggressiveness
vm.swappiness = 10

# Large inotify limit for Steam and game engines
fs.inotify.max_user_watches = 524288

# Scheduler latency tuning
kernel.sched_min_granularity_ns  = 500000
kernel.sched_wakeup_granularity_ns = 1000000

# Required by Proton and many modern games (default 65530 is too low)
vm.max_map_count = 2147483642
EOF

sudo sysctl --system
ok "sysctl gaming tweaks applied."

# ═════════════════════════════════════════════════════════════════════════════
section "05 — Mesa / AMDGPU driver stack"
# ═════════════════════════════════════════════════════════════════════════════

info "Enabling multilib repository..."
sudo sed -i '/^#\[multilib\]/,/^#Include/{s/^#//}' /etc/pacman.conf
sudo pacman -Sy --noconfirm

info "Installing Mesa and AMDGPU stack..."
sudo pacman -S --noconfirm \
  mesa lib32-mesa \
  xf86-video-amdgpu \
  libdrm lib32-libdrm \
  libva-mesa-driver lib32-libva-mesa-driver \
  mesa-vdpau lib32-mesa-vdpau

ok "Mesa/AMDGPU driver stack installed."

# ═════════════════════════════════════════════════════════════════════════════
section "06 — Vulkan / RADV"
# ═════════════════════════════════════════════════════════════════════════════

sudo pacman -S --noconfirm \
  vulkan-radeon lib32-vulkan-radeon \
  vulkan-icd-loader lib32-vulkan-icd-loader \
  vulkan-tools

ok "Vulkan/RADV installed."

info "Verifying Vulkan (may need GPU to be active)..."
vulkaninfo --summary 2>/dev/null | grep -i "AMD\|RADV\|7800" \
  && ok "Vulkan: AMD GPU detected." \
  || warn "vulkaninfo returned no AMD device — verify after reboot into cachyos kernel."

# ═════════════════════════════════════════════════════════════════════════════
section "07 — dinit services"
# ═════════════════════════════════════════════════════════════════════════════

info "Installing dbus and polkit..."
sudo pacman -S --noconfirm dbus polkit

info "Enabling dbus and polkit via dinit..."
sudo dinitctl enable dbus
sudo dinitctl enable polkit
sudo dinitctl start dbus  || true
sudo dinitctl start polkit || true

info "Setting up user dinit service directory..."
mkdir -p "$HOME/.config/dinit.d"

ok "dinit base services configured."

# ═════════════════════════════════════════════════════════════════════════════
section "08 — Environment variables"
# ═════════════════════════════════════════════════════════════════════════════

PROFILE_FILE="$HOME/.bash_profile"
[[ -f "$HOME/.zprofile" ]] && PROFILE_FILE="$HOME/.zprofile"

info "Writing AMD environment variables to ${PROFILE_FILE}..."

cat >> "$PROFILE_FILE" <<'EOF'

# ── AMD RX 7800 XT gaming environment ─────────────────────────────────────
export AMD_VULKAN_ICD=RADV
export RADV_PERFTEST=aco,nggc
export LIBVA_DRIVER_NAME=radeonsi
export GBM_BACKEND=amdgpu
export XDG_CURRENT_DESKTOP=Hyprland
export XDG_SESSION_TYPE=wayland
export XDG_SESSION_DESKTOP=Hyprland
export QT_QPA_PLATFORM=wayland
export MOZ_ENABLE_WAYLAND=1
export SDL_VIDEODRIVER=wayland
export vblank_mode=0

# Auto-launch Hyprland on TTY1
if [[ -z "$WAYLAND_DISPLAY" ]] && [[ "$(tty)" == "/dev/tty1" ]]; then
  exec Hyprland
fi
EOF

ok "Environment variables written to ${PROFILE_FILE}."

# ═════════════════════════════════════════════════════════════════════════════
section "09 — GPU performance power profile (dinit oneshot)"
# ═════════════════════════════════════════════════════════════════════════════

sudo tee /usr/local/bin/amdgpu-perf.sh > /dev/null <<'EOF'
#!/bin/sh
# Set GPU to high performance + VR power profile at boot
echo "high" > /sys/class/drm/card0/device/power_dpm_force_performance_level
echo "5"    > /sys/class/drm/card0/device/pp_power_profile_mode
EOF
sudo chmod +x /usr/local/bin/amdgpu-perf.sh

sudo tee /etc/dinit.d/amdgpu-perf > /dev/null <<'EOF'
type       = scripted
command    = /usr/local/bin/amdgpu-perf.sh
depends-on = udev
EOF

sudo dinitctl enable amdgpu-perf
ok "amdgpu-perf dinit service installed and enabled."

# ═════════════════════════════════════════════════════════════════════════════
section "10 — GameMode + MangoHud"
# ═════════════════════════════════════════════════════════════════════════════

sudo pacman -S --noconfirm gamemode lib32-gamemode mangohud lib32-mangohud

info "Adding $USER to gamemode group..."
sudo usermod -aG gamemode "$USER"

info "Creating user dinit service for gamemoded..."
cat > "$HOME/.config/dinit.d/gamemoded" <<'EOF'
type    = process
command = /usr/bin/gamemoded -r
restart = true
EOF

ok "GameMode + MangoHud installed."

# ═════════════════════════════════════════════════════════════════════════════
section "11 — AUR helper (paru)"
# ═════════════════════════════════════════════════════════════════════════════

if ! command -v paru &>/dev/null; then
  info "Installing paru (AUR helper)..."
  cd /tmp
  git clone https://aur.archlinux.org/paru-bin.git
  cd paru-bin
  makepkg -si --noconfirm
  cd ~
  ok "paru installed."
else
  ok "paru already installed — skipping."
fi

# ═════════════════════════════════════════════════════════════════════════════
section "12 — Steam + Proton-GE"
# ═════════════════════════════════════════════════════════════════════════════

info "Installing Steam..."
sudo pacman -S --noconfirm steam

info "Installing DXVK and VKD3D-Proton..."
sudo pacman -S --noconfirm \
  lib32-vkd3d vkd3d \
  wine-staging winetricks

info "Installing protonup-qt (for Proton-GE management) from AUR..."
paru -S --noconfirm protonup-qt

ok "Steam and Proton toolchain installed."
warn "Open protonup-qt after first boot to install Proton-GE, then restart Steam."

# ═════════════════════════════════════════════════════════════════════════════
section "13 — Hyprland rice"
# ═════════════════════════════════════════════════════════════════════════════

info "Installing Hyprland and rice stack..."
sudo pacman -S --noconfirm \
  hyprland \
  xorg-xwayland \
  waybar \
  hyprpaper \
  rofi-wayland \
  dunst \
  kitty \
  nwg-look \
  polkit-gnome \
  xdg-desktop-portal-hyprland \
  xdg-desktop-portal-gtk \
  ttf-jetbrains-mono-nerd \
  noto-fonts noto-fonts-emoji \
  grim slurp \
  wl-clipboard \
  brightnessctl \
  playerctl \
  pavucontrol

# ── Audio stack ───────────────────────────────────────────────────────────
section "13a — Audio (PipeWire)"

info "Installing full PipeWire audio stack..."
sudo pacman -S --noconfirm \
  pipewire \
  pipewire-audio \
  pipewire-alsa \
  pipewire-pulse \
  pipewire-jack \
  lib32-pipewire \
  lib32-pipewire-jack \
  wireplumber \
  alsa-utils \
  alsa-firmware \
  alsa-plugins \
  lib32-alsa-plugins

# Unmute ALSA master channel — fresh installs are muted by default
info "Unmuting ALSA master output..."
amixer sset Master unmute 2>/dev/null || true
amixer sset Master 100% 2>/dev/null   || true
amixer sset Speaker unmute 2>/dev/null || true
amixer sset Headphone unmute 2>/dev/null || true
# Persist ALSA state across reboots
sudo alsactl store 2>/dev/null || true
ok "ALSA unmuted and state saved."

# ── User dinit audio services ─────────────────────────────────────────────
info "Writing user dinit services for PipeWire audio..."
mkdir -p "$HOME/.config/dinit.d"

# pipewire — core daemon
cat > "$HOME/.config/dinit.d/pipewire" <<'EOF'
type    = process
command = /usr/bin/pipewire
restart = true
EOF

# wireplumber — session/policy manager, must start after pipewire
cat > "$HOME/.config/dinit.d/wireplumber" <<'EOF'
type       = process
command    = /usr/bin/wireplumber
depends-on = pipewire
restart    = true
EOF

# pipewire-pulse — PulseAudio compatibility socket (Steam, browsers, games)
cat > "$HOME/.config/dinit.d/pipewire-pulse" <<'EOF'
type       = process
command    = /usr/bin/pipewire-pulse
depends-on = wireplumber
restart    = true
EOF

# audio boot target — groups all three so hyprland exec-once only needs one line
cat > "$HOME/.config/dinit.d/audio" <<'EOF'
type       = target
depends-on = pipewire
depends-on = wireplumber
depends-on = pipewire-pulse
EOF

ok "PipeWire user dinit services written."

# ── Wire audio into user dinit boot target ────────────────────────────────
info "Enabling audio services in user dinit boot target..."
mkdir -p "$HOME/.config/dinit.d/boot.d"
ln -sf "$HOME/.config/dinit.d/pipewire"       "$HOME/.config/dinit.d/boot.d/pipewire"
ln -sf "$HOME/.config/dinit.d/wireplumber"    "$HOME/.config/dinit.d/boot.d/wireplumber"
ln -sf "$HOME/.config/dinit.d/pipewire-pulse" "$HOME/.config/dinit.d/boot.d/pipewire-pulse"
ok "Audio services linked into user boot target."

# Ensure user is in audio group
info "Adding $USER to audio group..."
sudo usermod -aG audio "$USER"
ok "User added to audio group."

# ── Hyprland config ───────────────────────────────────────────────────────
info "Writing Hyprland config..."
mkdir -p "$HOME/.config/hypr"
mkdir -p "$HOME/Pictures/screenshots"
mkdir -p "$HOME/.config/hypr/wallpapers"

cat > "$HOME/.config/hypr/hyprland.conf" <<'EOF'
# ── Monitor ────────────────────────────────────────────────────────────────
monitor=,preferred,auto,1
# Example for 1440p 144Hz: monitor=DP-1,2560x1440@144,0x0,1

# ── Autostart ──────────────────────────────────────────────────────────────
exec-once = waybar
exec-once = hyprpaper
exec-once = dunst
exec-once = /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1
exec-once = dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP
# Start user dinit — manages pipewire, wireplumber, pipewire-pulse, gamemoded
exec-once = dinit --user

# ── Variables ──────────────────────────────────────────────────────────────
$terminal = kitty
$menu     = rofi -show drun
$mainMod  = SUPER

# ── Appearance ─────────────────────────────────────────────────────────────
general {
    gaps_in             = 5
    gaps_out            = 10
    border_size         = 2
    col.active_border   = rgba(e0352bff) rgba(f47320ff) 45deg
    col.inactive_border = rgba(1e2230ff)
    layout              = dwindle
}

decoration {
    rounding = 8
    blur {
        enabled  = true
        size     = 6
        passes   = 3
        vibrancy = 0.2
    }
    shadow {
        enabled      = true
        range        = 12
        render_power = 3
        color        = rgba(0a0b0f99)
    }
}

animations {
    enabled = true
    bezier  = easeOut, 0.16, 1, 0.3, 1
    animation = windows,    1, 4, easeOut, slide
    animation = fade,       1, 4, easeOut
    animation = workspaces, 1, 5, easeOut, slidevert
}

# ── Input ──────────────────────────────────────────────────────────────────
input {
    repeat_rate  = 35
    repeat_delay = 200
    follow_mouse = 1
    sensitivity  = 0
}

dwindle {
    pseudotile     = true
    preserve_split = true
}

# ── Keybinds ───────────────────────────────────────────────────────────────
bind = $mainMod, Return, exec, $terminal
bind = $mainMod, D,      exec, $menu
bind = $mainMod, Q,      killactive
bind = $mainMod, F,      fullscreen
bind = $mainMod, V,      togglefloating
bind = $mainMod SHIFT, E, exit

# Screenshots
bind = ,      Print, exec, grim ~/Pictures/screenshots/$(date +%s).png
bind = SHIFT, Print, exec, grim -g "$(slurp)" ~/Pictures/screenshots/$(date +%s).png

# Volume / brightness
bind = ,XF86AudioRaiseVolume,  exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+
bind = ,XF86AudioLowerVolume,  exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
bind = ,XF86AudioMute,         exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle
bind = ,XF86MonBrightnessUp,   exec, brightnessctl set 10%+
bind = ,XF86MonBrightnessDown, exec, brightnessctl set 10%-

# Workspace switching
bind = $mainMod, 1, workspace, 1
bind = $mainMod, 2, workspace, 2
bind = $mainMod, 3, workspace, 3
bind = $mainMod, 4, workspace, 4
bind = $mainMod, 5, workspace, 5

bind = $mainMod SHIFT, 1, movetoworkspace, 1
bind = $mainMod SHIFT, 2, movetoworkspace, 2
bind = $mainMod SHIFT, 3, movetoworkspace, 3
bind = $mainMod SHIFT, 4, movetoworkspace, 4
bind = $mainMod SHIFT, 5, movetoworkspace, 5

# Window focus (vim-style)
bind = $mainMod, H, movefocus, l
bind = $mainMod, L, movefocus, r
bind = $mainMod, K, movefocus, u
bind = $mainMod, J, movefocus, d

# Window resize
bind = $mainMod CTRL, H, resizeactive, -40 0
bind = $mainMod CTRL, L, resizeactive,  40 0
bind = $mainMod CTRL, K, resizeactive,  0 -40
bind = $mainMod CTRL, J, resizeactive,  0  40

# Mouse window drag
bindm = $mainMod, mouse:272, movewindow
bindm = $mainMod, mouse:273, resizewindow

# ── Window rules ───────────────────────────────────────────────────────────
windowrulev2 = float, class:^(pavucontrol)$
windowrulev2 = float, class:^(protonup-qt)$
windowrulev2 = fullscreen, class:^(steam_app_.*)$
EOF

# ── Waybar config ─────────────────────────────────────────────────────────
info "Writing Waybar config..."
mkdir -p "$HOME/.config/waybar"

cat > "$HOME/.config/waybar/config" <<'EOF'
{
    "layer": "top",
    "position": "top",
    "height": 34,
    "modules-left":   ["hyprland/workspaces"],
    "modules-center": ["clock"],
    "modules-right":  ["custom/gpu-temp", "cpu", "memory", "network", "pulseaudio", "tray"],

    "hyprland/workspaces": {
        "disable-scroll": true,
        "all-outputs": true,
        "format": "{icon}",
        "format-icons": {
            "1": "󰲡", "2": "󰲣", "3": "󰲥",
            "4": "󰲧", "5": "󰲩",
            "active": "󰮯", "default": "󰊠"
        }
    },

    "clock": {
        "format": " {:%H:%M}",
        "tooltip-format": "{:%A, %d %B %Y}"
    },

    "custom/gpu-temp": {
        "exec": "cat /sys/class/drm/card0/device/hwmon/hwmon*/temp1_input 2>/dev/null | awk '{printf \"󰢮 %d°C\", $1/1000}'",
        "interval": 3,
        "format": "{}"
    },

    "cpu":    { "format": " {usage}%", "interval": 2 },
    "memory": { "format": " {used:.1f}G" },

    "network": {
        "format-ethernet":    "󰈀 {bandwidthDownBits}",
        "format-wifi":        "󰤨 {essid}",
        "format-disconnected": "󰖪 offline"
    },

    "pulseaudio": {
        "format": "{icon} {volume}%",
        "format-muted": "󰝟",
        "format-icons": { "default": ["󰕿", "󰖀", "󰕾"] },
        "on-click": "pavucontrol"
    },

    "tray": { "spacing": 10 }
}
EOF

cat > "$HOME/.config/waybar/style.css" <<'EOF'
* {
    font-family: "JetBrainsMono Nerd Font";
    font-size: 13px;
    border: none;
    border-radius: 0;
}

window#waybar {
    background: rgba(10, 11, 15, 0.88);
    color: #c8cedf;
    border-bottom: 1px solid rgba(224, 53, 43, 0.4);
}

#workspaces button {
    padding: 0 8px;
    color: #4a5068;
    background: transparent;
    transition: all 0.2s ease;
}
#workspaces button.active {
    color: #e0352b;
    text-shadow: 0 0 8px rgba(224,53,43,0.6);
}
#workspaces button:hover {
    color: #f47320;
    background: rgba(244,115,32,0.1);
}

#clock         { color: #e8edf8; font-weight: bold; letter-spacing: 0.05em; }
#custom-gpu-temp { color: #f47320; }
#cpu             { color: #30c8e0; }
#memory          { color: #3ddc84; }
#network         { color: #c8cedf; }
#pulseaudio      { color: #c8cedf; }

#custom-gpu-temp, #cpu, #memory, #network, #pulseaudio, #tray {
    padding: 0 10px;
    margin: 3px 2px;
    background: rgba(19, 22, 31, 0.6);
    border-radius: 4px;
}
EOF

# ── hyprpaper config ──────────────────────────────────────────────────────
cat > "$HOME/.config/hypr/hyprpaper.conf" <<EOF
preload  = $HOME/.config/hypr/wallpapers/wall.jpg
wallpaper = ,$HOME/.config/hypr/wallpapers/wall.jpg
splash   = false
EOF

# ── dunst config ──────────────────────────────────────────────────────────
mkdir -p "$HOME/.config/dunst"
cat > "$HOME/.config/dunst/dunstrc" <<'EOF'
[global]
    font                 = JetBrainsMono Nerd Font 11
    frame_color          = "#e0352b"
    separator_color      = frame
    background           = "#0a0b0f"
    foreground           = "#c8cedf"
    highlight            = "#f47320"
    corner_radius        = 6
    offset               = "10x10"
    origin               = "top-right"
    timeout              = 5
EOF

ok "Hyprland rice configs written."

# ═════════════════════════════════════════════════════════════════════════════
section "14 — CoreCtrl (GPU overclocking GUI)"
# ═════════════════════════════════════════════════════════════════════════════

info "Installing corectrl from AUR..."
paru -S --noconfirm corectrl

info "Installing polkit rule for CoreCtrl (no-password GPU control)..."
sudo cp /usr/share/polkit-1/rules.d/90-corectrl.rules \
        /etc/polkit-1/rules.d/90-corectrl.rules 2>/dev/null || \
sudo tee /etc/polkit-1/rules.d/90-corectrl.rules > /dev/null <<'EOF'
polkit.addRule(function(action, subject) {
    if ((action.id == "org.corectrl.helper.init" ||
         action.id == "org.corectrl.helperkiller.init") &&
        subject.local == true &&
        subject.active == true &&
        subject.isInGroup("wheel")) {
        return polkit.Result.YES;
    }
});
EOF

ok "CoreCtrl installed with polkit rule."

# ═════════════════════════════════════════════════════════════════════════════
section "15 — radeontop"
# ═════════════════════════════════════════════════════════════════════════════

sudo pacman -S --noconfirm radeontop
ok "radeontop installed (run: radeontop)"

# ═════════════════════════════════════════════════════════════════════════════
section "All done!"
# ═════════════════════════════════════════════════════════════════════════════

echo
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║  Gaming setup complete!                                      ║${RESET}"
echo -e "${GREEN}${BOLD}║                                                              ║${RESET}"
echo -e "${GREEN}${BOLD}║  Next steps:                                                 ║${RESET}"
echo -e "${GREEN}${BOLD}║  1. Reboot to boot into linux-cachyos kernel                 ║${RESET}"
echo -e "${GREEN}${BOLD}║  2. Log in on TTY1 — Hyprland will launch automatically      ║${RESET}"
echo -e "${GREEN}${BOLD}║  3. Audio: run 'wpctl status' to confirm PipeWire is running ║${RESET}"
echo -e "${GREEN}${BOLD}║     If silent: open pavucontrol and unmute the output        ║${RESET}"
echo -e "${GREEN}${BOLD}║  4. Open protonup-qt → install latest Proton-GE              ║${RESET}"
echo -e "${GREEN}${BOLD}║  5. Open Steam → enable Proton-GE as compatibility layer     ║${RESET}"
echo -e "${GREEN}${BOLD}║  6. Add a wallpaper to ~/.config/hypr/wallpapers/wall.jpg    ║${RESET}"
echo -e "${GREEN}${BOLD}║  7. Run: radeontop   to verify GPU is active                 ║${RESET}"
echo -e "${GREEN}${BOLD}║  8. Run: vulkaninfo --summary   to verify RADV               ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo
echo -e "  ${ORANGE}Steam launch options for best AMD performance:${RESET}"
echo -e "  ${CYAN}RADV_PERFTEST=nggc,aco DXVK_ASYNC=1 gamemoderun mangohud %command%${RESET}"
echo

read -rp "Reboot now? [y/N]: " do_reboot
[[ "$do_reboot" =~ ^[Yy]$ ]] && sudo reboot
