# WildPaqet-Tunnel | [📄 English](README.md)

اسکریپت مدیریتی برای **paqet**: تونل مبتنی بر Raw Socket و KCP برای عبور از فایروال و DPI. از سناریوی **سرور خارج (Kharej)** و **کلاینت ایران (Entry Point)** پشتیبانی می‌کند.

این مخزن فورک نگهداری‌شده از [Paqet-Tunnel-Manager](https://github.com/behzadea12/Paqet-Tunnel-Manager) است و با نام **WildPaqet Tunnel Manager v7.1** به‌روز شده است.

**آدرس پروژه:** https://github.com/infowild/WildPaqet-Tunnel

---

## فهرست مطالب

* [شروع سریع](#شروع-سریع)
* [مراحل نصب](#مراحل-نصب)
* [تنظیمات پیشرفته (KCP)](#تنظیمات-پیشرفته-حالتهای-kcp)
* [بهینه‌سازی شبکه](#بهینهسازی-شبکه-اختیاری)
* [ابزارها](#ابزارهای-استفادهشده)
* [عیب‌یابی](#عیبیابی-مشکلات-نصب-paqet)
* [پیش‌نیازها](#پیشنیازها)
* [تغییرات v7.1](#تغییرات-v71)
* [قدردانی](#قدردانی)
* [لایسنس](#لایسنس)

---

## شروع سریع

اسکریپت را روی **هر دو سرور** با دسترسی **root** اجرا کنید:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/infowild/WildPaqet-Tunnel/main/paqet-manager.sh)
```

> نسخه قدیمی‌تر منیجر (در صورت نیاز):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/infowild/WildPaqet-Tunnel/main/paqet-manager3-8.sh)
```

سپس **گزینه 0** و بعد **گزینه 1** را برای نصب پیش‌نیازها / هسته انتخاب کنید.

---

## مراحل نصب

### مرحله ۱: سرور خارج (Kharej)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/infowild/WildPaqet-Tunnel/main/paqet-manager.sh)
```

1. **گزینه 2** (Kharej)
2. نام سرویس (مثال: `fanland1`)
3. پورت Listen (مثال: `443` یا `8443`)
4. Enter برای ساخت خودکار Secret Key (ذخیره‌اش کنید)
5. تأیید با **`Y`**
6. حالت KCP (پیشنهادی: `fast`)
7. **conn** → پیش‌فرض سرور: `4`
8. **MTU** → پیش‌فرض: `1350`
9. Encryption (پیش‌فرض: `aes-128-gcm`)
10. بافرها → Enter برای رد کردن

### مرحله ۲: سرور ایران (Client)

1. **گزینه 3** (Iran)
2. نام سرویس
3. IP سرور خارج
4. پورت تونل بین دو سرور
5. Secret Key ساخته‌شده روی خارج
6. حالت KCP (پیشنهادی: `fast`)
7. **conn** → پیش‌فرض کلاینت: `1`
8. **MTU** → پیش‌فرض: `1350`
9. Encryption
10. بافرها → Enter
11. نوع ترافیک: **Port Forwarding** یا **SOCKS5**
12. برای Forward: پورت‌ها مثل `333` یا `333,394,395` و پروتکل هر پورت

**نکته مهم:** نسخه هسته `paqet` روی هر دو سرور باید یکسان باشد.

### نصب هسته از URL سفارشی

1. منیجر → گزینه **0**
2. گزینه **3** (Download from custom URL)
3. لینک آرشیو متناسب با معماری را وارد کنید
4. سرویس‌ها را ریستارت کنید

ریلیز رسمی هسته: [hanselime/paqet releases](https://github.com/hanselime/paqet/releases)

---

## تنظیمات پیشرفته (حالت‌های KCP)

0. **normal** – سرعت/تأخیر معمولی، مصرف کم  
1. **fast** – متعادل (پیشنهادی)  
2. **fast2** – سریع‌تر، مصرف متوسط  
3. **fast3** – حداکثر سرعت، CPU بالا  
4. **manual** – تنظیم دستی  

---

## بهینه‌سازی شبکه (اختیاری)

گزینه **7**:

1. **BBR** – برای سرور خارج  
2. **DNS Finder** – برای سرور ایران  
3. **Mirror Selector** – مخزن APT سریع‌تر (Ubuntu/Debian)

---

## ابزارهای استفاده‌شده

* [BBR – teddysun/across](https://github.com/teddysun/across/)
* [IranDNSFinder](https://github.com/alinezamifar/IranDNSFinder)
* [DetectUbuntuMirror](https://github.com/alinezamifar/DetectUbuntuMirror)

---

## عیب‌یابی: مشکلات نصب Paqet

### ۱) دانلود / پیدا نشدن باینری

فایل را از [releases](https://github.com/hanselime/paqet/releases) بگیرید، در `/root/paqet/` بگذارید و از گزینه نصب فایل محلی استفاده کنید.

### ۲) خطای GLIBC

سیستم را ارتقا دهید (Ubuntu 22.04+ / Debian 12+) یا از سورس بسازید:

```bash
apt install -y golang git
git clone https://github.com/hanselime/paqet.git && cd paqet
go build -o paqet ./cmd/paqet
sudo cp paqet /usr/local/bin/paqet
sudo chmod +x /usr/local/bin/paqet
```

### ۳) پورت در حال استفاده

```bash
ss -tuln | grep 8443
lsof -i :8443
```

### ۴) تکراری شدن `conn:` (رفع‌شده در v7.1)

در v7.0 ویرایش گروهی کانکشن گاهی یک `conn` اضافه می‌ساخت. به این نسخه ارتقا دهید یا در YAML فقط یک `conn:` زیر `transport:` نگه دارید.

---

## پیش‌نیازها

* لینوکس + دسترسی root  
* `libpcap-dev` ، `iptables`  
* باینری `paqet`

---

## تغییرات v7.1

* آدرس نصب و آپدیت منیجر روی `infowild/WildPaqet-Tunnel`
* رفع باگ duplicate شدن `conn` در ویرایش گروهی
* نصب امن‌تر هسته (استخراج موقت + بکاپ باینری قبلی)
* یکدست‌سازی پیش‌فرض‌ها: MTU=`1350`، conn کلاینت=`1`، conn سرور=`4`
* اصلاح نمایش توضیحات KCP Mode
* بکاپ sysctl با timestamp درست
* حذف پروکسی تلگرام شخص‌ثالث؛ فقط API رسمی (+ SOCKS5 اختیاری)
* دانلود BBR با `curl` و TLS معتبر
* حذف `GOMAXPROCS=0` از unit فایل systemd

---

## قدردانی

* **[paqet](https://github.com/hanselime/paqet)** – هسته تونل توسط hanselime  
* **[Paqet-Tunnel-Manager](https://github.com/behzadea12/Paqet-Tunnel-Manager)** – منیجر اولیه توسط behzadea12  

---

## لایسنس

MIT (مطابق پروژه‌های upstream؛ در صورت تمایل فایل `LICENSE` را به ریپو اضافه کنید).
