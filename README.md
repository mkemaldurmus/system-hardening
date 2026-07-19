# System Hardening — OOM Prevention, Memory, CPU & GPU Optimization

Comprehensive system stability and performance hardening for CachyOS/KDE Plasma on AMD Ryzen Mobile.

**Modules:** Memory leak containment · Proactive OOM daemon · CPU mitigations · Thermal management · KSM deduplication · Full stress test suite

## Problem

**Root Cause:** KDE Bug 522615 — `kwalletd6` has a memory leak that grows unbounded.

**Impact:** kwalletd6 leaked 4 GiB RAM + 3.3 GiB swap in ~1 hour, triggering the kernel OOM killer. The system froze completely — mouse stopped moving, all processes unresponsive.

**Detection:** Confirmed via `journalctl` — OOM killed PID 35718 (kwalletd6) at `14:09:25 2026-07-15` after consuming 16.6 GB total VM.

## Solution Architecture

### OOM Prevention (3-layer defense)

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

### CPU Optimizations

| Optimization | Mechanism | Gain | Status |
|---|---|---|---|
| `mitigations=off` | Kernel cmdline — disables Spectre/Meltdown/Retbleed | +5-15% CPU | Requires reboot |
| `sysctl` tweaks | I/O dirty ratio, TCP buffers, NUMA off, scheduler tuning | Lower latency | Applied |
| `thermald` + RAPL | AMD adaptive thermal: 80°C→20W, 85°C→15W power cap | Thermal headroom | Active |
| `amd-pstate-epp` | `performance` governor + `performance` EPP hint | Max frequency | Active |
| `powerprofilesctl` | Platform profile → EC signals aggressive fan curve | Cooling | Active |

### Memory Optimizations

| Optimization | Mechanism | Gain | Status |
|---|---|---|---|
| KSM | Kernel Same-page Merging — deduplicates Chrome/Java pages | Up to 500 MiB saved | Enabled |
| Zram | zstd-compressed swap in RAM (14.5 GiB, 3.2x ratio) | No disk swap latency | Active |
| Swappiness=10 | Prefer RAM over swap | Less thrashing | Applied |
| THP always | Transparent Huge Pages for large allocations | TLB efficiency | Active |

## Files

```
system-hardening/
├── README.md
├── install.sh                              # One-command deployment (6 steps)
├── configs/
│   ├── earlyoom.conf                       # → /etc/default/earlyoom
│   ├── kernel/limine                       # → /etc/default/limine (mitigations=off)
│   ├── sysctl/99-ryzen-perf.conf           # → /etc/sysctl.d/
│   ├── thermald/thermal-conf.xml           # → /etc/thermald/
│   ├── thermald/amd-override.conf          # → /etc/systemd/system/thermald.service.d/
│   ├── ksm/ksm.conf                        # → /etc/tmpfiles.d/
│   └── ssh/99-hardening.conf               # → /etc/ssh/sshd_config.d/ (opt-in)
├── systemd/
│   └── kwalletd6-memory-limit.conf         # → ~/.config/systemd/user/
├── scripts/
│   └── memory-suite                        # → ~/.local/bin/memory-suite
└── docs/
    ├── test-report-2026-07-15.txt          # Initial validation results
    └── remote-access.md                    # Phone → PC via SSH + Tailscale
```

## Remote Access (phone → PC)

Reach this machine securely from your phone — key-only SSH over a Tailscale
(WireGuard) mesh, with **no port exposed to the public internet**.

```bash
# Opt-in (disabled by default to avoid SSH lock-out)
ENABLE_REMOTE_SSH=1 bash install.sh
```

- **sshd hardening:** password + root login disabled, pubkey-only, `MaxAuthTries 3`
- **Tailscale:** stable `100.x.x.x` IP behind NAT/CGNAT, end-to-end encrypted
- **Clients:** Termux/Termius (Android), Termius/Blink (iOS); KDE RDP or RustDesk for GUI

> ⚠ Add your phone's public key to `~/.ssh/authorized_keys` **before** relying on it.

Full step-by-step guide (Türkçe): [`docs/remote-access.md`](docs/remote-access.md)

## Deployment

```bash
cd ~/system-hardening
bash install.sh
```

Manual steps if needed:

```bash
# earlyoom
sudo pacman -S earlyoom thermald
sudo cp configs/earlyoom.conf /etc/default/earlyoom
sudo systemctl enable --now earlyoom

# kwalletd6 limit
mkdir -p ~/.config/systemd/user/dbus-:1.2-org.kde.kwalletd6@.service.d
cp systemd/kwalletd6-memory-limit.conf \
   ~/.config/systemd/user/dbus-:1.2-org.kde.kwalletd6@.service.d/memory-limit.conf
systemctl --user daemon-reload

# CPU optimizations
sudo cp configs/sysctl/99-ryzen-perf.conf /etc/sysctl.d/ && sudo sysctl --system
sudo cp configs/thermald/* /etc/thermald/ && sudo systemctl restart thermald
sudo cp configs/ksm/ksm.conf /etc/tmpfiles.d/
echo 1 | sudo tee /sys/kernel/mm/ksm/run   # enable immediately

# Kernel mitigations (edit /etc/default/limine, add: mitigations=off)
# Then run: sudo limine-update && reboot

# memory-suite
cp scripts/memory-suite ~/.local/bin/ && chmod +x ~/.local/bin/memory-suite
```

## Verification

```bash
# Quick health check (30s)
memory-suite --quick

# CPU stress & thermal (2 min)
memory-suite --cpu

# GPU stress & OpenGL (2 min)
memory-suite --gpu

# Advanced memory analysis: bandwidth, fragmentation, page faults (1 min)
memory-suite --mem-advanced

# Full memory tests + baseline (2 min)
memory-suite --full

# Complete system burn-in: Memory + CPU + GPU + Advanced (8 min)
memory-suite --burnin

# Continuous leak monitoring (every 5 min)
memory-suite --leak-monitor

# Check kwalletd6 memory limit is active
systemctl --user show dbus-:1.2-org.kde.kwalletd6@*.service -p MemoryMax

# Check KSM savings after runtime
cat /sys/kernel/mm/ksm/pages_sharing
```

## Maintenance

| Command | Purpose |
|---|---|
| `memory-suite --quick` | Daily health check |
| `memory-suite --cpu` | After BIOS/CPU microcode updates |
| `memory-suite --gpu` | After GPU driver/Mesa updates |
| `memory-suite --full` | After kernel/systemd/KDE updates |
| `memory-suite --mem-advanced` | Deep memory analysis (bandwidth, page faults) |
| `memory-suite --burnin` | Full system validation before deployment |
| `cat /sys/kernel/mm/ksm/pages_sharing` | Check KSM memory savings |
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

### Advanced Memory — 6/6 passed
- Memory bandwidth (stream): completed
- Huge Pages: THP `always` enabled, 2048 kB page size
- Fragmentation resistance: 99.7% recovery after alloc/free cycles
- Zswap/Zram: zstd-compressed zram active (14.5 GiB, 3.2x ratio), no disk swap
- Page fault rate: 187 major faults/sec (zram decompression — RAM constrained)
- Memory latency: completed

### System Analysis Summary

| Metric | Value | Assessment |
|---|---|---|
| CPU idle temp | 92°C | Passive cooling bottleneck |
| CPU load temp | 97°C | At throttle threshold |
| RAM usage | 10/14 GiB | Chrome (2.5G) + IntelliJ (1.8G) dominate |
| Zram usage | 7.6/14.5 GiB | Severe memory pressure |
| Page fault rate | 187 major/s | zram thrashing — RAM upgrade recommended |
| Chrome processes | 25 | Tab discarding recommended |
| kwalletd6 trend | 259→550 MiB | Growing, but contained by 1G MemoryMax |

### Recommended Actions

1. **Reboot** — apply `mitigations=off` kernel parameter (+5-15% CPU)
2. **Chrome** — enable Memory Saver at `chrome://settings/performance`
3. **KSM** — check `cat /sys/kernel/mm/ksm/pages_sharing` after 30 min runtime
4. **Cooling** — laptop cooling pad recommended (97°C sustained)
5. **RAM** — consider 32 GiB upgrade for Chrome + IntelliJ + Claude workload

## References

- [KDE Bug 522615](https://bugs.kde.org/show_bug.cgi?id=522615) — kwalletd6 memory leak
- [earlyoom](https://github.com/rfjakob/earlyoom) — Early OOM Daemon
- [systemd.resource-control](https://www.freedesktop.org/software/systemd/man/systemd.resource-control.html) — MemoryMax documentation
