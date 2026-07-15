# System Hardening Learnings

## Donanim
- **CPU**: AMD Ryzen 5 7520U (4C/8T, Mendocino, 2.8-4.4 GHz)
- **GPU**: Radeon 610M (radeonsi, ACO)
- **RAM**: 14 GiB
- **Disk**: NVMe Btrfs (zstd:1, noatime, discard=async)
- **OS**: CachyOS Linux, Kernel 7.1.3-2-cachyos (EEVDF scheduler, 1000Hz)
- **Bootloader**: Limine

---

## Problem 1: kwalletd6 Memory Leak → System Freeze

### Belirti
Sistem tamamen dondu, mouse hareket etmedi. `journalctl` OOM killer'in kwalletd6'yi oldurdugunu gosterdi.

### Kok Sebep
[KDE Bug 522615](https://bugs.kde.org/show_bug.cgi?id=522615) — kwalletd6 memory leak. ~1 saatte 4 GiB RAM + 3.3 GiB swap tuketti.

### Cozum (3 katmanli savunma)

**Katman 1 — systemd MemoryMax:**
```ini
# ~/.config/systemd/user/dbus-:1.2-org.kde.kwalletd6@.service.d/memory-limit.conf
[Service]
MemoryMax=1G
MemorySwapMax=500M
```
- Dosya yolu: `~/.config/systemd/user/` (kullanici home dizininde)
- systemd cgroup OOM: kwalletd6 1 GiB'i gecince otomatik oldurulur
- **Reboot sonrasi durum:** KALICI ✅

**Katman 2 — earlyoom:**
```bash
# /etc/default/earlyoom
EARLYOOM_ARGS="-m 15 -s 15 -r 3600 --avoid (^|/)(init|systemd|Xorg|ssh|login)$ --prefer (^|/)(chrome|java|kwalletd6|firefox|gradle)$ -n"
```
- %15 RAM altinda erken OOM tetiklenir
- kwalletd6, java, chrome oncelikli hedef
- **Reboot sonrasi durum:** KALICI ✅

**Katman 3 — KDE Watchdog:**
- `~/.config/systemd/user/kwalletd6-watchdog.service`
- kwalletd6 oldugunde 5 sn icinde yeniden baslatir

### Dogrulama
```bash
systemctl --user show 'dbus-:1.2-org.kde.kwalletd6@0.service' -p MemoryMax
# MemoryMax=1073741824 (1 GiB) ✅
systemctl is-active earlyoom
# active ✅
```

---

## Problem 2: SBT -Xmx6G → Swap Thrashing

### Belirti
ZIO projesi acildiktan sonra RAM 1.7 GiB'e dustu, page fault 400/s, sistem yavasladi.

### Kok Sebep
`~/Downloads/zio-series-2.x/.jvmopts` icinde `-Xmx6G`. Iki SBT instance × 6 GiB = 12 GiB sanal bellek (14 GiB fiziksel RAM'de).

### Cozum
```diff
- -Xmx6G
+ -Xmx2G
```
- Dosya: `~/Downloads/zio-series-2.x/.jvmopts`
- **Reboot sonrasi durum:** KALICI ✅ (proje dosyasi)

### Onemli Not
SBT restart edilene kadar eski -Xmx6G ile calismaya devam eder. `.jvmopts` sadece yeni JVM baslatildiginda okunur.

---

## Problem 3: sysctl vm.swappiness Reboot Sonrasi Kayboluyor

### Belirti
Reboot sonrasi `vm.swappiness=10` olmasi gerekirken `80` goruldu.

### Kok Sebep (3 neden)

**Neden 1 — sysctl conflict:**
3 dosya swappiness icin yarisiyordu:
```
/usr/lib/sysctl.d/70-cachyos-settings.conf → swappiness=100 (CachyOS default)
/etc/sysctl.d/99-cachyos-memory.conf      → swappiness=50  (CachyOS override)
/etc/sysctl.d/99-ryzen-perf.conf          → swappiness=10  (bizim config)
```
`70` < `99` alfabetik sirada ama `70` /usr/lib'de. systemd-sysctl hangi sirada uyguladigi belirsiz.

**Neden 2 — EEVDF uyumsuz kernel parametreleri:**
Bizim config'de `kernel.sched_migration_cost_ns` ve `kernel.sched_autogroup_enabled` vardi. EEVDF kernel'de bunlar YOK. systemd-sysctl log'a uyari basti:
```
Couldn't write '500000' to 'kernel/sched_migration_cost_ns', ignoring: No such file or directory
```

**Neden 3 — CachyOS kernel compiled-in default = 80:**
Ana hat kernel default 60 degil, CachyOS kernel'in icinde `CONFIG_DEFAULT_VM_SWAPPINESS=80` olarak derlenmis. Boot aninda kernel 80 ile basliyor. systemd-sysctl override etmeye calisiyor ama `/usr/lib/sysctl.d/70-cachyos-settings.conf` (swappiness=100) boot sirasinda bizim `/etc/sysctl.d/99-ryzen-perf.conf`'u bilinmeyen bir sebepten override ediyor. (Manuel `sysctl --system` dogru calisiyor ama boot'ta farkli bir sira olabilir.)

### Cozum (2 asamali)
1. `99-ryzen-perf.conf`'dan EEVDF'de olmayan `kernel.sched_migration_cost_ns` ve `kernel.sched_autogroup_enabled` kaldirildi
2. `99-cachyos-memory.conf` → `99-cachyos-memory.conf.bak` yapildi
3. **Kritik fix**: `/etc/sysctl.d/70-cachyos-settings.conf` olusturuldu — `/usr/lib/sysctl.d/70-cachyos-settings.conf`'u OVRIDE eden bos dosya. systemd ayni isimli dosyada /etc versiyonunu /usr/lib versiyonuna tercih eder. Bu sayede swappiness=100 tamamen bloke edilir, sadece 99-ryzen-perf.conf'taki swappiness=10 gecerli olur.
4. Config dosyalari:
   - `/etc/sysctl.d/99-ryzen-perf.conf`
   - `/etc/sysctl.d/70-cachyos-settings.conf` (override)
5. Repo kopyalari: `configs/sysctl/99-ryzen-perf.conf`, `configs/sysctl/70-cachyos-override.conf`

### Dogrulama
```bash
cat /proc/sys/vm/swappiness
# 10 ✅
# Override aktif mi?
grep -r "swappiness" /etc/sysctl.d/ /usr/lib/sysctl.d/ | grep -v ".bak"
# Sadece 99-ryzen-perf.conf swappiness=10 cikmali ✅
```

---

## Problem 4: Boot Menude Enter Bekliyor (Auto-Boot Yok)

### Belirti
Her reboot'ta CachyOS / LTS / Snapshots secimi icin Enter'a basmak gerekiyor.

### Kok Sebep
`/boot/limine.conf` icinde:
- `default_entry: 2` — 2. entry Snapshots alt-menusune isaret ediyordu
- `BOOT_ORDER="*, *lts, *fallback, Snapshots"` — coklu kernel secenegi
- `timeout: 5` — 5 saniye var ama default_entry yanlis oldugu icin bekliyor

Limine entry siralamasi:
```
0: linux-cachyos (ana kernel)
1: linux-cachyos-lts
2+: Snapshots (51 snapshot)
```

### Cozum
```bash
sudo sed -i 's/^default_entry:.*/default_entry: 1/' /boot/limine.conf
sudo sed -i 's/^timeout:.*/timeout: 3/' /boot/limine.conf
```
- `default_entry: 1` → linux-cachyos-lts yerine ana kernel
- `timeout: 3` → 3 saniye sonra otomatik boot

**Dikkat:** `limine-snapper-sync` bu dosyayi yeniden olusturabilir ve default_entry'i sifirlayabilir. Eger tekrar Enter beklemeye baslarsa `/boot/limine.conf`'u tekrar kontrol et.

### Dogrulama
```bash
sudo grep -E "default_entry|timeout" /boot/limine.conf
# default_entry: 1 ✅
# timeout: 3 ✅
```

---

## Problem 5: Warp Google Dogrulamasi Reboot Sonrasi Tekrar Istiyor

### Belirti
Warp her reboot'ta tekrar Google hesabi dogrulamasi istiyor.

### Kok Sebep
Warp auth token'lari KDE keyring (kwalletd6) uzerinden saklaniyor. Reboot'ta:
1. kwalletd6 yeniden basliyor
2. KDE keyring kilitli kaliyor (kullanici sifresiyle acilmasi lazim)
3. Warp token'a erisemeyince tekrar login istiyor

### Cozum
Simdilik kalici bir cozum yok. Gecici:
- KDE'de otomatik keyring unlock: `pam_gnome_keyring.so` PAM konfigurasyonuna eklenebilir
- Veya Warp Drive cloud sync ile oturum verileri bulutta saklanir

### Dogrulama
```bash
ls ~/.config/warp-terminal/user_preferences.json
# Mevcut ✅ (175KB - ayarlar kaydediliyor)
ls ~/.local/share/warp-terminal/
# Bos — Warp Drive verisi (notebook, env var) cloud sync gerektiriyor
```

---

## Problem 6: SBT Yuksek CPU Kullanimi → 95.8°C

### Belirti
SBT compile sirasinda CPU 95.8°C'ye ulasti, Tctl throttle esiginde.

### Kok Sebep
- SBT 2 instance: 1 import (%92 CPU) + 1 shell (%211 CPU)
- Toplam ~%300 CPU kullanimi
- AMD Ryzen 7520U laptop CPU, cooling kisitli

### Cozum
1. **thermald**: 80°C'de RAPL 20W, 85°C'de 15W ile limitler (`/etc/thermald/thermal-conf.xml`)
2. **mitigations=off**: CPU mitigasyonlari kaldirildi → daha az cycle → daha az isi (+%5-15 performans)
3. **ananicy-cpp**: Java/IntelliJ sureclerine otomatik nice
4. SBT'ye `-Xmx2G` limiti → daha az GC → daha az CPU

### Dogrulama
```bash
sensors | grep Tctl
# Tctl: +XX°C (yuk altinda 85-90°C beklenir)
systemctl is-active thermald
# active ✅
```

---

## Tum Konfigurasyon Dosyalari

| Dosya | Konum | Reboot Kalici? |
|---|---|---|
| sysctl | `/etc/sysctl.d/99-ryzen-perf.conf` | ✅ |
| KSM | `/etc/tmpfiles.d/ksm.conf` | ✅ |
| thermald | `/etc/thermald/thermal-conf.xml` | ✅ |
| thermald override | `/etc/systemd/system/thermald.service.d/amd-override.conf` | ✅ |
| earlyoom | `/etc/default/earlyoom` | ✅ |
| kwalletd6 limit | `~/.config/systemd/user/.../memory-limit.conf` | ✅ |
| limine kernel cmdline | `/etc/default/limine` | ✅ |
| limine boot config | `/boot/limine.conf` | ⚠️ limine-snapper-sync override edebilir |
| SBT heap | `proje/.jvmopts` | ✅ (proje dosyasi) |

---

## Kurulum (Sifir Sistemde)

```bash
cd ~/system-hardening
sudo cp configs/sysctl/99-ryzen-perf.conf /etc/sysctl.d/
sudo cp configs/ksm/ksm.conf /etc/tmpfiles.d/
sudo cp configs/thermald/thermal-conf.xml /etc/thermald/
sudo cp -r configs/kernel/ /etc/default/
sudo cp configs/earlyoom.conf /etc/default/earlyoom
mkdir -p ~/.config/systemd/user/dbus-:1.2-org.kde.kwalletd6@.service.d/
cp systemd/kwalletd6-memory-limit.conf ~/.config/systemd/user/dbus-:1.2-org.kde.kwalletd6@.service.d/memory-limit.conf
sudo sysctl --system
sudo systemctl restart thermald earlyoom
systemctl --user daemon-reload
```

## Test Suite

```bash
memory-suite --quick     # Temel kontroller (1 dk)
memory-suite --cpu       # CPU stres testi
memory-suite --gpu       # GPU testi
memory-suite --full      # Tum testler
memory-suite --leak-monitor  # Surekli bellek izleme
```

Raporlar: `~/.cache/memory-suite/`

---

## Bilinen Sorunlar

1. **limine-snapper-sync**: `/boot/limine.conf` default_entry'i degistirebilir. Cozum: reboot sonrasi kontrol et, gerekirse tekrar fix uygula.
2. **Warp Google auth**: KDE keyring unlock sorunu. PAM konfigurasyonu ile cozulebilir.
3. **kernel.sched_* parametreleri**: EEVDF kernel'de eski CFS parametreleri YOK. Config eklerken `/proc/sys/kernel/` altinda dosyanin var oldugunu kontrol et.
4. **sysctl conflict riski**: `/etc/sysctl.d/` altinda ayni prefix'li dosyalar olmamali. Bizim config `99-ryzen-perf.conf`, CachyOS'un `99-cachyos-memory.conf` ile cakisiyordu.
