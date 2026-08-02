# WildPaqet-Tunnel | [📄 English](README.md)

اسکریپت مدیریتی برای **paqet**: تونل مبتنی بر Raw Socket و KCP برای عبور از فایروال و DPI. از سناریوی **سرور خارج (Kharej)** و **کلاینت ایران** پشتیبانی می‌کند.

این مخزن فورک نگهداری‌شده از [Paqet-Tunnel-Manager](https://github.com/behzadea12/Paqet-Tunnel-Manager) است و با نام **WildPaqet Tunnel Manager v7.1** به‌روز شده است.

**آدرس پروژه:** https://github.com/infowild/WildPaqet-Tunnel

---

## فهرست مطالب

* [شروع سریع](#شروع-سریع)
* [نصب به‌عنوان دستور سیستم](#نصب-بهعنوان-دستور-سیستم)
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

روی **هر دو سرور** با **root**:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/infowild/WildPaqet-Tunnel/main/wildpaqet.sh)
```

> نسخه قدیمی‌تر منیجر (در صورت نیاز):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/infowild/WildPaqet-Tunnel/main/paqet-manager3-8.sh)
```

---

## نصب به‌عنوان دستور سیستم

داخل منیجر:

1. گزینه **0** → Install Paqet Binary / Manager  
2. گزینه **4** → Install script  

اسکریپت در مسیر `/usr/local/bin/wildpaqet` نصب می‌شود.

بعد از آن هر وقت با این دستور اجرا کنید:

```bash
wildpaqet
```

---

## مراحل نصب

### مرحله ۱: سرور خارج (Kharej)

```bash
wildpaqet
# یا اولین اجرا:
bash <(curl -fsSL https://raw.githubusercontent.com/infowild/WildPaqet-Tunnel/main/wildpaqet.sh)
```

1. **گزینه 2** (Kharej)  
2. نام سرویس  
3. پورت Listen  
4. Enter برای ساخت Secret Key  
5. تأیید با **`Y`**  
6. حالت KCP (پیشنهادی: `fast`)  
7. **conn** → پیش‌فرض سرور: `4`  
8. **MTU** → پیش‌فرض: `1350`  
9. Encryption (پیش‌فرض: `aes-128-gcm`)  
10. بافرها → Enter  

### مرحله ۲: سرور ایران (Client)

1. **گزینه 3** (Iran)  
2. نام سرویس  
3. IP سرور خارج  
4. پورت تونل  
5. Secret Key  
6. حالت KCP  
7. **conn** → پیش‌فرض کلاینت: `1`  
8. **MTU** → `1350`  
9. Encryption  
10. بافرها → Enter  
11. Port Forwarding یا SOCKS5  
12. پورت‌های Forward و پروتکل  

**نکته:** نسخه هسته روی هر دو سرور باید یکسان باشد.

### نصب هسته از URL سفارشی

`wildpaqet` → گزینه **0** → گزینه **3** → لینک آرشیو را وارد کنید.

ریلیز رسمی هسته: [hanselime/paqet releases](https://github.com/hanselime/paqet/releases)

---

## تنظیمات پیشرفته (حالت‌های KCP)

0. **normal** – معمولی  
1. **fast** – متعادل (پیشنهادی)  
2. **fast2** – سریع‌تر  
3. **fast3** – حداکثر سرعت  
4. **manual** – دستی  

---

## بهینه‌سازی شبکه (اختیاری)

`wildpaqet` → گزینه **7**: BBR / DNS Finder / Mirror Selector

---

## ابزارهای استفاده‌شده

* [BBR – teddysun/across](https://github.com/teddysun/across/)  
* [IranDNSFinder](https://github.com/alinezamifar/IranDNSFinder)  
* [DetectUbuntuMirror](https://github.com/alinezamifar/DetectUbuntuMirror)  

---

## عیب‌یابی: مشکلات نصب Paqet

### ۱) دانلود / پیدا نشدن باینری

فایل را در `/root/paqet/` بگذارید و از نصب فایل محلی استفاده کنید.

### ۲) خطای GLIBC

ارتقای OS یا بیلد از سورس (دستورها در README انگلیسی).

### ۳) پورت در حال استفاده

```bash
ss -tuln | grep 8443
lsof -i :8443
```

### ۴) تکراری شدن `conn:` (رفع‌شده در v7.1)

به این نسخه ارتقا دهید یا در YAML فقط یک `conn:` زیر `transport:` نگه دارید.

---

## پیش‌نیازها

* لینوکس + root  
* `libpcap-dev` ، `iptables`  
* باینری `paqet`  

---

## تغییرات v7.1

* دستور اجرا: **`wildpaqet`** (`/usr/local/bin/wildpaqet`)  
* فایل اصلی: **`wildpaqet.sh`**  
* بنر رنگی جدید WildPaqet + لینک گیت‌هاب  
* آدرس‌ها روی `infowild/WildPaqet-Tunnel`  
* فیکس باگ duplicate `conn` و نصب امن‌تر هسته  
* یکدست‌سازی MTU/conn  
* حذف پروکسی تلگرام شخص‌ثالث  

---

## قدردانی

* **[paqet](https://github.com/hanselime/paqet)** – hanselime  
* **[Paqet-Tunnel-Manager](https://github.com/behzadea12/Paqet-Tunnel-Manager)** – behzadea12  

---

## لایسنس

MIT (مطابق upstream؛ در صورت تمایل فایل `LICENSE` اضافه کنید).
