# tvcec

Mac uyurken veya ekranı uyuyunca Samsung TV'yi HDMI-CEC ile standby'a alır, uyanınca açar. MacBookPro18,3 (M1 Pro), macOS 27 ve Samsung LE22D450G1W üzerinde test edildi.

## Yöntem

- **CEC:** DPCD CEC tüneli (`0x3000` bloğu), belgelenmemiş `IODPDevice*` fonksiyonlarıyla. MacTV'nin yöntemi budur.
- **M1 Pro için ek adım:** macOS bu portta CEC'i etkinleştirmez. Komut çalışırken SMC `gP12` pini (device tree: `function-hdmi_cec_en`) yüksek yapılır, bitince düşürülür. Bu olmadan TV ACK vermez.
- **Olaylar:** Uyku için `IORegisterForSystemPower`, uyanma için `NSWorkspace` (Power Nap uyanışlarını atlar), yeniden bağlanma için `CGDisplay` geri çağrısı.
- **Ekran uykusu:** Ekranlar uyuyunca TV 30 saniye sonra kapanır; ekran bu sürede uyanırsa komut gönderilmez. Mac'in kendisi uyursa TV hemen kapanır.
- **Oturum kapatma ve kapanış:** TV standby'a alınır, ajan yeniden başlayınca açılır.
- **Açılış kontrolü:** `wake` sonrası TV'nin güç durumu sorulur. TV standby demeye devam ederse komut yeniden denenir; yanıt gelmemesi hata sayılmaz.
- **Yetki:** Pin root ister. Ajan kullanıcı olarak çalışır; sudoers kuralı yalnızca `tvcec wake` ve `tvcec standby` komutlarına izin verir.

**Risk:** `gP12` yazmak belgelenmemiştir ve Apple desteklemez. macOS güncellemesi bunu bozabilir. SIP kapatılmaz, sistem dosyaları değiştirilmez. Crisp'in ayarlarına dokunulmaz; yazmalar yalnızca CEC registerlarına ve `gP12`'ye gider.

## Kurulum

Gerekenler: Xcode Command Line Tools ve TV'de Anynet+ açık.

```sh
./build.sh          # derleme
./install.sh        # /usr/local/bin/tvcec, /etc/sudoers.d/tvcec, LaunchAgent
./uninstall.sh      # kaldırma (--purge-logs günlükleri de siler)
```

## Komutlar

```sh
sudo tvcec wake       # TV'yi aç
sudo tvcec standby    # TV'yi standby'a al
sudo tvcec status     # port, adres ve TV yanıtı
tvcec monitor 30      # CEC trafiğini dinle
tvcec selftest        # donanımsız mantık testleri
```

## Test

```sh
launchctl print gui/$UID/com.ahmetaltun.tvcec | grep -E 'state|pid'
tail -f ~/Library/Logs/tvcec/tvcec.log
```

Apple menüsü > Uyut ile Mac'i uyutun, sonra uyandırın. Günlükte `power off: delivered` ve `power on: delivered` görünmeli.

## Günlükler

- `~/Library/Logs/tvcec/tvcec.log`: olaylar ve CEC çerçeveleri (1 MB'ı geçince `tvcec.log.1` olur)
- `~/Library/Logs/tvcec/launchd.log`: launchd çıktısı

## Sorun giderme

| Belirti | Kontrol |
|---|---|
| Kapak kapanınca TV kapanmıyor | Şarjda ve harici ekran bağlıyken kapak Mac'i uyutmayabilir. Günlükte `system will sleep` veya `screens slept` var mı? |
| `no ACK` veya `did not acknowledge` | TV'de Anynet+ açık mı? `sudo tvcec status` çalıştırın, kabloyu çıkarıp takın. |
| `gP12 write failed` | `sudo` ile çalıştırın. Ajanda oluyorsa sudoers dosyasını kontrol edin: `sudo visudo -cf /etc/sudoers.d/tvcec`. |
| `no CEC-capable port` | HDMI kablosu takılı mı? macOS güncellemesi sonrası `IODPDevice` değişmiş olabilir. |
| `N CEC-capable ports` | Birden çok uygun port var; `tvcec` tahmin yürütmez. |
| Uyanışta TV açılmıyor | Günlükteki deneme satırlarına bakın. Ajan 4 kez dener, sonra ekran olayını bekler. |
| Görüntü kesiliyor | `./uninstall.sh` çalıştırın ve Mac'i yeniden başlatın. |
| BetterDisplay de TV'yi kontrol ediyor | BetterDisplay'in CEC güç kontrolünü kapatın veya uygulamadan çıkın. |
