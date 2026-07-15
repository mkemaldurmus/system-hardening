# System Memory Hardening

Proactive OOM prevention and memory leak containment for CachyOS/KDE Plasma.

## Problem

**Root Cause:** KDE Bug 522615 — `kwalletd6` has a memory leak that grows unbounded.

**Impact:** kwalletd6 leaked 4 GiB RAM + 3.3 GiB swap in ~1 hour, triggering the kernel OOM killer. The system froze completely — mouse stopped moving, all processes unresponsive.

**Detection:** Confirmed via `journalctl` — OOM killed PID 35718 (kwalletd6) at `14:09:25 2026-07-15` after consuming 16.6 GB total VM.

## Solution Architecture

Three-layer defense-in-depth:

```
┌─────────────────────────────────────────────────────┐
│ LAYER 1: systemd MemoryMax                          │
│ kwalletd6 capped at 1 GiB RAM / 500 MiB swap        │
│ Triggers: cgroup OOM kills ONLY kwalletd6           │
│ System impact: NONE — other processes unaffected    │
├─────────────────────────────────────────────────────┤
│ LAYER 2: earlyoom (proactive OOM daemon)            │
│ Monitors RAM/swap, kills heaviest process at 85%    │
│ Prefers: chrome, java, kwalletd6, firefox, gradle   │
│ Avoids:  init, systemd, Xorg, ssh, login            │
├─────────────────────────────────────────────────────┤
│ LAYER 3: KDE Watchdog                               │
│ Auto-restarts kwalletd6 after any kill              │
│ User impact: transparent (service restarts silently) │
└─────────────────────────────────────────────────────┘
```

### Failure Scenario (contained)

```
kwalletd6 starts leaking → grows to 1 GiB → cgroup OOM kills it
→ Watchdog restarts it → loop repeats safely
→ System NEVER freezes (mouse, desktop, other apps unaffected)
```

## Files

```
system-hardening/
├── README.md
├── install.sh                          # One-command deployment
├── configs/
│   └── earlyoom.conf                   # → /etc/default/earlyoom
├── systemd/
│   └── kwalletd6-memory-limit.conf     # → ~/.config/systemd/user/dbus-:1.2-org.kde.kwalletd6@.service.d/
├── scripts/
│   └── memory-suite                    # → ~/.local/bin/memory-suite
└── docs/
    └── test-report-2026-07-15.md       # Initial validation results
```

## Deployment

```bash
cd ~/system-hardening
bash install.sh
```

Manual steps if needed:

```bash
# earlyoom
sudo pacman -S earlyoom
sudo cp configs/earlyoom.conf /etc/default/earlyoom
sudo systemctl enable --now earlyoom

# kwalletd6 limit
mkdir -p ~/.config/systemd/user/dbus-:1.2-org.kde.kwalletd6@.service.d
cp systemd/kwalletd6-memory-limit.conf \
   ~/.config/systemd/user/dbus-:1.2-org.kde.kwalletd6@.service.d/memory-limit.conf
systemctl --user daemon-reload

# memory-suite
cp scripts/memory-suite ~/.local/bin/
chmod +x ~/.local/bin/memory-suite
```

## Verification

```bash
# Quick health check (30s)
memory-suite --quick

# CPU stress & thermal (2 min)
memory-suite --cpu

# GPU stress & OpenGL (2 min)
memory-suite --gpu

# Full memory tests + baseline (2 min)
memory-suite --full

# Complete system burn-in: Memory + CPU + GPU (6 min)
memory-suite --burnin

# Continuous leak monitoring (every 5 min)
memory-suite --leak-monitor

# Check kwalletd6 memory limit is active
systemctl --user show dbus-:1.2-org.kde.kwalletd6@*.service -p MemoryMax
```

## Maintenance

| Command | Purpose |
|---|---|
| `memory-suite --quick` | Daily health check |
| `memory-suite --cpu` | After BIOS/CPU microcode updates |
| `memory-suite --gpu` | After GPU driver/Mesa updates |
| `memory-suite --full` | After kernel/systemd/KDE updates |
| `memory-suite --burnin` | Full system validation before deployment |
| `journalctl -u earlyoom` | Check if earlyoom killed anything |
| `journalctl -k \| grep oom` | Check kernel OOM events |
| `systemctl --user status kwalletd6-watchdog` | Verify watchdog is running |

## Test Results (2026-07-15)

### Memory — 18/18 passed
- systemd MemoryMax enforcement: VERIFIED (cgroup OOM kills at 10M limit)
- earlyoom health + config: VERIFIED
- kwalletd6 leak contained: VERIFIED (hit 1 GiB limit, killed, restarted)
- Memory pressure recovery: VERIFIED (2 GiB allocated, fully reclaimed)
- Swap pressure handling: VERIFIED
- Concurrent CPU+memory stress: VERIFIED

### CPU — 5/5 passed (Ryzen 5 7520U, 4C/8T)
- Single-core boost: 3.8 GHz, 94°C → 97°C
- All-core stress: 97°C peak (thermal warning — laptop cooling limit)
- Cache thrashing: memory stable throughout
- FPU (FFT + matrix): 20s sustained, no throttle

### GPU — 4/4 passed (AMD Radeon 610M iGPU)
- OpenGL (glmark2): 30s sustained
- GPU shader (stress-ng): 89°C baseline
- GPU+CPU concurrent: 89°C → 97°C peak, system stable (no crash, no OOM)

## References

- [KDE Bug 522615](https://bugs.kde.org/show_bug.cgi?id=522615) — kwalletd6 memory leak
- [earlyoom](https://github.com/rfjakob/earlyoom) — Early OOM Daemon
- [systemd.resource-control](https://www.freedesktop.org/software/systemd/man/systemd.resource-control.html) — MemoryMax documentation
