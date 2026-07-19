# Telefondan Uzaktan Erişim (SSH + Tailscale)

Telefondan kendi Linux makinene (CachyOS/KDE) güvenli şekilde bağlanıp
komut çalıştırmak veya masaüstünü görmek için kurulum rehberi.

**Mimari:** İnternete port açmadan, uçtan uca şifreli erişim.

```
Telefon (Termux/Termius)  ──SSH──>  Tailscale (WireGuard mesh)  ──>  CachyOS PC (sshd)
        anahtar ile               internete açık port YOK            key-only, root kapalı
```

---

## 1. PC Tarafı — SSH Sunucusu

```bash
# OpenSSH kur ve başlat
sudo pacman -S openssh
sudo systemctl enable --now sshd

# Yerel IP'ni öğren (ev ağı içinden test için)
ip -4 addr show | grep inet
```

### Sağlamlaştırma

Ana config'i bozmadan ayrı bir drop-in dosyası kullanılır
(`configs/ssh/99-hardening.conf` → `/etc/ssh/sshd_config.d/99-hardening.conf`):

```ini
PermitRootLogin no
PasswordAuthentication no        # sadece anahtarla giriş
PubkeyAuthentication yes
KbdInteractiveAuthentication no
AuthenticationMethods publickey
MaxAuthTries 3
#AllowUsers KULLANICI_ADIN       # kendi kullanıcınla değiştir + yorumu kaldır
X11Forwarding no
```

```bash
sudo cp configs/ssh/99-hardening.conf /etc/ssh/sshd_config.d/
sudo systemctl restart sshd
```

> **UYARI:** `PasswordAuthentication no` aktif olduktan sonra parolayla SSH
> girişi kapanır. Aşağıdaki adımda telefonun public key'ini eklemeden
> **önce** uzaktan bağlanmayı deneme — yoksa yalnızca fiziksel konsoldan
> girebilirsin. (Fiziksel konsol parola girişi çalışmaya devam eder.)

---

## 2. Telefon Tarafı — Anahtar Oluştur

### Android (Termux — en temiz yol)

```bash
pkg update && pkg install openssh
ssh-keygen -t ed25519            # Enter'a bas; passphrase önerilir
cat ~/.ssh/id_ed25519.pub        # bu satırı kopyala
```

### iPhone / kolay GUI

**Termius** (Android + iOS) veya **Blink Shell** (iOS). Uygulama içinde
anahtar üretip public key'i kopyalayabilirsin.

### Public key'i PC'ye ekle

PC'de (fiziksel konsol veya ev ağı içinden):

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo "ssh-ed25519 AAAA...telefondan_kopyaladigin_key... telefon" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

Ev ağı içindeyken test:

```bash
ssh KULLANICI@192.168.x.x        # PC'nin yerel IP'si
```

---

## 3. Ev Ağı Dışından Erişim — Tailscale

Laptop olduğu için IP değişir ve NAT/CGNAT arkasındasın. Port açmak yerine
**Tailscale** (WireGuard tabanlı, ücretsiz, CGNAT arkasında bile çalışır):

```bash
# PC'de
sudo pacman -S tailscale
sudo systemctl enable --now tailscaled
sudo tailscale up
```

Telefona **Tailscale** uygulamasını kur, **aynı hesapla** giriş yap. Her iki
cihaz `100.x.x.x` sabit IP alır. Artık her yerden:

```bash
ssh KULLANICI@100.x.x.x
```

**Alternatifler:** WireGuard (manuel), Cloudflare Tunnel, ya da DDNS + port
yönlendirme (en az güvenli — önerilmez).

---

## 4. İsteğe Bağlı — Grafik Masaüstü (KDE)

Sadece terminal değil ekranı da görmek istersen:

- **KDE Plasma 6 yerleşik RDP:** *Sistem Ayarları → Uzak Masaüstü* → etkinleştir,
  kullanıcı/parola belirle. Telefonda **Microsoft Remote Desktop** uygulamasıyla
  Tailscale IP'sine bağlan.
- **RustDesk:** kur-bağlan, en kolay yöntem.

---

## Güvenlik Özeti

| Önlem | Fayda |
|---|---|
| Sadece anahtarla giriş (parola kapalı) | Brute-force imkânsız |
| Root girişi kapalı + `AllowUsers` | Tek kullanıcıya kısıt |
| Tailscale (WireGuard) | İnternete açık port yok, uçtan uca şifreli |
| Telefon anahtarına passphrase | Telefon çalınırsa koruma |
| `MaxAuthTries 3` | Deneme sınırı |

---

## Kurulum (install.sh ile)

SSH modülü lock-out riskine karşı varsayılan olarak **kapalıdır**. Açıkça
etkinleştirmek için:

```bash
ENABLE_REMOTE_SSH=1 bash install.sh
```

Bu; openssh + tailscale kurar, sağlamlaştırılmış config'i uygular, sshd'yi
başlatır ve `authorized_keys` boşsa seni uyarır.

---

## Doğrulama

```bash
# sshd çalışıyor mu
systemctl status sshd

# Aktif config (parola kapalı mı)
sudo sshd -T | grep -Ei 'passwordauth|permitrootlogin|pubkeyauth'

# Tailscale bağlı mı ve IP
tailscale status
tailscale ip -4
```
