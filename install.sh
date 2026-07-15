#!/usr/bin/env bash
# =============================================================================
#  System Memory Hardening - Deployment Script
#  Repository: ~/system-hardening
#  Target:     CachyOS / Arch Linux (KDE Plasma)
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
step()  { echo -e "\n${BLUE}==>${NC} $1"; }
ok()    { echo -e "  ${GREEN}OK${NC}   $1"; }
err()   { echo -e "  ${RED}ERR${NC}  $1"; exit 1; }

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Step 1: Install earlyoom ───────────────────────────────────────────────
step "Step 1/5: Installing earlyoom..."
if command -v earlyoom &>/dev/null; then
    ok "earlyoom already installed"
else
    sudo pacman -S --noconfirm earlyoom || err "Failed to install earlyoom"
    ok "earlyoom installed"
fi

# ── Step 2: Deploy earlyoom config ─────────────────────────────────────────
step "Step 2/5: Deploying earlyoom configuration..."
sudo cp "$REPO_DIR/configs/earlyoom.conf" /etc/default/earlyoom
sudo systemctl enable --now earlyoom
ok "earlyoom config deployed and service enabled"

# ── Step 3: Deploy kwalletd6 MemoryMax drop-in ─────────────────────────────
step "Step 3/5: Deploying kwalletd6 memory limit (KDE Bug 522615)..."
mkdir -p "${HOME}/.config/systemd/user/dbus-:1.2-org.kde.kwalletd6@.service.d"
cp "$REPO_DIR/systemd/kwalletd6-memory-limit.conf" \
   "${HOME}/.config/systemd/user/dbus-:1.2-org.kde.kwalletd6@.service.d/memory-limit.conf"
systemctl --user daemon-reload
ok "kwalletd6 MemoryMax=1G drop-in deployed"

# ── Step 4: Install test suite ─────────────────────────────────────────────
step "Step 4/5: Installing memory-suite..."
cp "$REPO_DIR/scripts/memory-suite" "${HOME}/.local/bin/memory-suite"
chmod +x "${HOME}/.local/bin/memory-suite"

if ! echo "$PATH" | grep -q "${HOME}/.local/bin"; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "${HOME}/.bashrc"
    ok "Added ~/.local/bin to PATH in .bashrc"
fi
ok "memory-suite installed to ~/.local/bin/"

# ── Step 6: CPU Performance Optimizations ──────────────────────────────────
step "Step 6/7: Applying CPU performance optimizations..."

# 6a: Sysctl tweaks (I/O, network, scheduler)
sudo cp "$REPO_DIR/configs/sysctl/99-ryzen-perf.conf" /etc/sysctl.d/
sudo sysctl --system >/dev/null 2>&1
ok "Sysctl performance tweaks applied"

# 6b: thermald with AMD override
sudo pacman -S --noconfirm thermald 2>/dev/null || true
sudo mkdir -p /etc/systemd/system/thermald.service.d
sudo cp "$REPO_DIR/configs/thermald/amd-override.conf" /etc/systemd/system/thermald.service.d/
sudo cp "$REPO_DIR/configs/thermald/thermal-conf.xml" /etc/thermald/
sudo systemctl daemon-reload
sudo systemctl enable --now thermald
ok "thermald configured for AMD with RAPL thermal management"

# 6c: KSM memory deduplication
sudo cp "$REPO_DIR/configs/ksm/ksm.conf" /etc/tmpfiles.d/
echo 1 | sudo tee /sys/kernel/mm/ksm/run >/dev/null 2>&1 || true
ok "KSM memory deduplication enabled (Chrome/Java benefit)"

# 6d: Kernel mitigations=off (requires reboot)
if ! grep -q "mitigations=off" /etc/default/limine 2>/dev/null; then
    echo ""
    echo "  ⚠ To disable CPU mitigations (5-15% performance gain), add to kernel cmdline:"
    echo "    mitigations=off"
    echo "  Edit /etc/default/limine and run: sudo limine-update"
fi
ok "CPU optimizations complete (mitigations=off requires manual reboot)"

# ── Step 5: Install test dependencies (stress-ng, glmark2) ─────────────
step "Step 5/7: Installing test dependencies..."
for pkg in stress-ng glmark2; do
    if command -v "$pkg" &>/dev/null; then
        ok "$pkg already installed"
    else
        sudo pacman -S --noconfirm "$pkg" || echo "  (optional - skip if unavailable)"
        ok "$pkg installed"
    fi
done

# ── Verify ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}═══ Hardening Complete ═══${NC}"
echo ""
echo "Installed protections & optimizations:"
echo "  1. earlyoom     — kills heaviest process at 85% RAM (prefers kwalletd6)"
echo "  2. kwalletd6    — capped at 1 GiB via systemd MemoryMax"
echo "  3. Watchdog     — KDE auto-restarts kwalletd6 after kill"
echo "  4. Sysctl       — I/O, network, scheduler performance tweaks"
echo "  5. thermald     — AMD RAPL-based adaptive thermal management"
echo "  6. KSM          — Kernel Same-page Merging memory deduplication"
echo "  7. memory-suite — full stability suite (~/.local/bin/memory-suite)"
echo ""
echo "Test modes:"
echo "  memory-suite --quick      Basic health (30s)"
echo "  memory-suite --cpu        CPU stress & thermal (2min)"
echo "  memory-suite --gpu        GPU/OpenGL stress (2min)"
echo "  memory-suite --full       Memory only (2min)"
echo "  memory-suite --mem-advanced  Deep memory analysis"
echo "  memory-suite --burnin     Full system: Memory+CPU+GPU (8min)"
echo "  memory-suite --leak-monitor  Continuous leak watch"
echo ""
