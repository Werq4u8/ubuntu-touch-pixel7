# 🐧 Ubuntu Touch для Google Pixel 7 (`panther` / `gs201`) — Safe Slot-B Dual-Boot Port

> **Полноценный порт Ubuntu Touch (GNU/Linux + Lomiri) на Google Pixel 7 (Tensor G2) с архитектурой безопасного Dual-Boot во второй слот (`Slot B`) без форматирования `userdata` и с полным сохранением основной прошивки Android (`Slot A`).**

---

## 🔥 Главная фишка этого порта (Safe Slot-B Architecture)

Официальные порты Ubuntu Touch (через UBports Installer и стандартный `halium-boot`) требуют **полного уничтожения данных на телефоне** (`fastboot format:ext4 userdata`), так как кладут корневую систему `ubuntu.img` внутрь раздела `/data` и ломают аппаратное шифрование Android (FBEv2 + Metadata Encryption на чипе **Titan M2**).

В этом проекте реализована **кастомная архитектура изолированного Слота B**:
1. **Слот A (`_a`) и раздел `userdata` (`/dev/block/sda31`) НЕ ТРОГАЮТСЯ ВООБЩЕ.** Ваша основная система (Android 14 / 15 / 16, Kali NetHunter, ключи Titan M2 и все личные файлы) остается в 100% безопасности.
2. **Вся Ubuntu Touch живет внутри свободного места контейнера `super` (`/dev/block/sda30`) в Слоте B:**
   * На Pixel 7 размер раздела `super` составляет **8.53 ГБ**, из которых Слот A занимает **~6.46 ГБ**. Оставшиеся **~2.07 ГБ** используются под Слот B.
   * **`system_b` (~950 МБ, SquashFS + ZSTD Level 19):** сжатая корневая файловая система Ubuntu Touch + контейнер Halium.
   * **`product_b` (~512 МБ, `ext4`):** постоянный перезаписываемый раздел (верхний слой **OverlayFS**), куда сохраняются все настройки Ubuntu Touch, пароли Wi-Fi, Bluetooth-пары и папка `/home/phablet`.
   * **`vendor_dlkm_b` (~50 МБ) и `system_dlkm_b` (~16 МБ):** модули ядра `.ko`, скомпилированные из исходников вместе с нашим ядром.
   * **`vendor_a` (Read-Only):** монтируется строго в режиме «только чтение» для подгрузки заводских firmware-блобов (`fw_bcmdhd.bin`, `aoc.bin`, `mali_csffw.bin`), что экономит **740 МБ** места в `super`!

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    Google Pixel 7 (panther / gs201)                     │
├───────────────────────────────────┬─────────────────────────────────────┤
│        SLOT A (Основной)          │        SLOT B (Ubuntu Touch)        │
│  • Android 16 + Kali NetHunter    │  • Ядро: 6.1.145-halium (boot_b)    │
│  • boot_a / init_boot_a           │  • Кастомный initramfs (init_boot_b)│
│  • system_a / product_a / vendor_a│  • system_b (Ubuntu Touch SquashFS) │
│  • userdata (sda31, FBEv2 TitanM2)│  • product_b (OverlayFS rw-данные)  │
│                                   │  • Доступ к sda31/sda8 ЗАБЛОКИРОВАН │
└───────────────────────────────────┴─────────────────────────────────────┘
```

---

## 🧠 Как решена проблема с драйверами (Google Tensor G2 / GKI 2.0)

Главная боль современных устройств на базе **GKI 2.0 (Generic Kernel Image)** — в самом образе ядра (`boot.img`) **нет почти никаких драйверов железа**. Даже драйвер внутренней памяти UFS (`ufs-exynos-gs.ko`), контроллер питания PMIC (`s2mpg12-mfd.ko`) и контроллер шин тактирования (`clk_exynos_gs.ko`) вынесены во внешние модули `.ko`, разбросанные по трем разным разделам (`vendor_kernel_boot`, `system_dlkm`, `vendor_dlkm`).

Кроме того, на новых бутлоадерах Pixel 7 (`cloudripper-17.0` от Android 16) сопроцессор **AOC (Audio & Sensor Offload Core)** и **GSA / TrustZone** требуют ядра ветки **`6.1` (`gs-pantah-6.1`)**, а не старого `5.10` от Android 13.

### Что было сделано для полного запуска железа:

### 1. Сборка полноценного ядра `6.1.145-halium` из исходников (Kleaf / Bazel)
В стандартном пайплайне Google Kleaf для `pantah` по умолчанию включен флаг `--use_prebuilt_gki`, который скачивает стоковый `boot.img` без нужных для Ubuntu Touch подсистем.
Мы принудительно отключили `use_prebuilt_gki` и `check_defconfig` и пересобрали **и само ядро GKI (`Image.lz4`), и все 220+ проприетарных модулей `gs201`** с единым `vermagic` и следующими подсистемами (`configs/halium_panther.config`):
* **Systemd, LXC & Waydroid:** `CONFIG_SYSVIPC=y`, `CONFIG_POSIX_MQUEUE=y`, `CONFIG_NAMESPACES=y`, `CONFIG_USER_NS=y`, `CONFIG_PID_NS=y`, `CONFIG_NET_NS=y`, `CONFIG_CGROUP_FREEZER=y`, `CONFIG_DEVPTS_MULTIPLE_INSTANCES=y`.
* **AppArmor LSM (обязателен для графической оболочки Lomiri):** `CONFIG_SECURITY_APPARMOR=y`, `CONFIG_LSM="lockdown,yama,loadpin,safesetid,integrity,selinux,apparmor"`.
* **Виртуальные терминалы для Mir/Wayland:** `CONFIG_VT=y`, `CONFIG_VT_CONSOLE=y`, `CONFIG_UNIX98_PTYS=y`.
* **Файловые системы:** `CONFIG_SQUASHFS=y`, `CONFIG_SQUASHFS_ZSTD=y`, `CONFIG_OVERLAY_FS=y`, `CONFIG_EROFS_FS=y`.

### 2. Двухэтапная загрузка модулей ядра (Early Boot + Systemd Hardware Init)
* **Этап 1 (`init_boot_b.img` — ранний `initramfs`):**
  Наш скрипт `/init` до монтирования корня читает топологический список `/lib/modules/modules.load` из `vendor_kernel_boot_b` и последовательно загружает драйверы шин SoC Tensor G2 (`clk_exynos_gs.ko`, `s2mpg12-mfd.ko`, `s2mpg13-regulator.ko`, `ufs-exynos-gs.ko`, `phy-exynos-usbdrd-super.ko`, `dwc3-exynos-usb.ko`). Как только появляется блочное устройство `/dev/block/sda30` (`super`), скрипт сразу поднимает аварийный сетевой интерфейс **USB RNDIS (`10.15.19.82`)** и демон `telnetd`, блокирует узлы `/dev/block/sda31` (`userdata`) и `/dev/block/sda8` (`metadata`), собирает **OverlayFS** из `system_b` + `product_b` и передает управление `systemd`.
* **Этап 2 (`panther-hw-init.service` — инициализация периферии):**
  При старте `systemd` сервис `/usr/local/bin/panther-hw-init.sh` подгружает остальные модули из `system_dlkm` и `vendor_dlkm` и инициализирует беспроводные интерфейсы с передачей заводских калибровок из `/vendor`:

| Подсистема | Драйвер (модуль `.ko`) | Firmware / Калибровка (`vendor_a`) | Стек в Ubuntu Touch |
| :--- | :--- | :--- | :--- |
| **Wi-Fi (802.11ax)** | `cfg80211.ko` + `mac80211.ko` + `bcmdhd4389.ko` | `firmware_path=/vendor/firmware/fw_bcmdhd.bin`<br>`nvram_path=/vendor/etc/wifi/bcmdhd.cal`<br>`clm_path=/vendor/firmware/bcmdhd_clm.blob` | `wpa_supplicant` + `NetworkManager` |
| **Bluetooth 5.2** | `rfkill.ko` + `bluetooth.ko` + `btbcm.ko` + `hci_uart.ko` + `nitrous.ko` | `/vendor/firmware/bcm4389*.hcd` через UART `/dev/ttySAC*` и драйвер питания `nitrous` | `bluebinder` / `BlueZ` (`bluetoothd`) |
| **NFC** | `nfc.ko` + `st21nfc.ko` + `st33spi.ko` + `st54spi.ko` | Устройство `/dev/st21nfc` + `/vendor/firmware/st21nfc_conf.bin` | `nfcd` + `nfcd-binder-plugin` |
| **GPU & Экран (90Hz)** | `exynos-drm.ko` + `gs-panel.ko` + `panel-samsung-s6e3fc3-p10.ko` + `mali_kbase.ko` + `mali_pixel.ko` | `/vendor/firmware/mali_csffw.bin` + `/vendor/lib64/egl/libGLES_mali.so` | `libhybris` + `Mir` / `Lomiri` |
| **Тачскрин** | `goog_touch_interface.ko` + `sec_touch.ko` / `syna_touch.ko` / `focal_touch.ko` | `touch_bus_negotiator.ko` (AOC TBN) | `libinput` / `udev` (`70-panther.rules`) |
| **Звук и Датчики** | `aoc_core.ko` + `aoc_channel_dev.ko` + `aoc_alsa_dev.ko` + `snd-soc-cs35l41.ko` | `/vendor/firmware/aoc.bin` | ALSA / `PulseAudio` (`PipeWire`) |

---

## 🚀 Как собрать самому (GitHub Actions в 1 клик)

Вам **не нужен** мощный ПК или 200 ГБ на диске — вся сборка полностью автоматизирована в облаке **GitHub Actions**:

1. Сделайте **Fork** этого репозитория.
2. Перейдите во вкладку **Actions** -> выберите workflow **`Build Ubuntu Touch for Pixel 7 (Slot B / Safe Dual-Boot 6.1.145)`**.
3. Нажмите кнопку **Run workflow** -> **Run workflow**.
4. Через ~35–45 минут скачайте готовый архив **`UbuntuTouch-SlotB-Pixel7-6.1.145`** из секции **Artifacts**, внутри которого лежат:
   * `boot_b.img` — скомпилированное ядро `6.1.145-halium`
   * `init_boot_b.img` — безопасный загрузчик-рамдиск для Слота B
   * `vendor_kernel_boot_b.img` — ранние модули SoC и DTB
   * `dtbo_b.img` — Device Tree Overlays для `panther`
   * `vendor_dlkm_b.img` и `system_dlkm_b.img` — образы модулей ядра (Wi-Fi, BT, NFC, GPU)
   * `system_b.img` — сжатый образ корневой системы Ubuntu Touch (SquashFS)

---

## 📲 Инструкция по установке во второй слот (Slot B)

### Предварительные требования:
* Разблокированный загрузчик (Unlocked Bootloader).
* В **Слоте A (`_a`)** должна стоять актуальная прошивка Android (база `CP1A.260405.005` / ядро `6.1.145`).
* Отключите автоматические OTA-обновления в Android, чтобы фоновый `update_engine` не перезаписал Слот B:
  ```bash
  adb shell settings put global ota_disable_automatic_update 1
  adb shell pm disable-user --user 0 com.android.dynsystem
  ```

### Автоматическая прошивка (Windows):
1. Распакуйте архив **`UbuntuTouch-SlotB-Pixel7-6.1.145.zip`** в папку с `fastboot.exe` (`platform-tools`).
2. Скопируйте туда скрипт [`scripts/flash-slot-b.bat`](scripts/flash-slot-b.bat) и [`scripts/switch-to-android.bat`](scripts/switch-to-android.bat).
3. Переведите телефон в режим **Fastboot** (Зажмите `Питание + Громкость Вниз`) и запустите **`flash-slot-b.bat`**.

### Ручная пошаговая прошивка:
```bash
# 1. Прошиваем загрузочные разделы Слота B (в режиме обычного bootloader)
fastboot flash boot_b boot_b.img
fastboot flash init_boot_b init_boot_b.img
fastboot flash vendor_kernel_boot_b vendor_kernel_boot_b.img
fastboot flash dtbo_b dtbo_b.img

# 2. Переходим в пользовательский fastbootd для работы с динамическим разделом super
fastboot reboot fastboot

# 3. Очищаем пустые заглушки Слота B внутри super и выделяем место из свободных 2.07 ГБ
fastboot delete-logical-partition system_b
fastboot delete-logical-partition product_b
fastboot delete-logical-partition vendor_dlkm_b
fastboot delete-logical-partition system_dlkm_b

fastboot create-logical-partition vendor_dlkm_b 52428800
fastboot create-logical-partition system_dlkm_b 16777216
fastboot create-logical-partition system_b 1153433600
fastboot create-logical-partition product_b 536870912

# 4. Записываем образы Ubuntu Touch в Слот B
fastboot flash vendor_dlkm_b vendor_dlkm_b.img
fastboot flash system_dlkm_b system_dlkm_b.img
fastboot flash system_b system_b.img

# 5. Переключаемся на Слот B и загружаемся!
fastboot --set-active=b
fastboot reboot
```

---

## 🔄 Как переключаться между системами (Dual-Boot)

* **Вернуться обратно в ваш Android + NetHunter (Slot A):**
  Зажмите `Питание + Громкость Вниз` (вход в Fastboot) и выполните (или запустите `switch-to-android.bat`):
  ```bash
  fastboot --set-active=a
  fastboot reboot
  ```
* **Загрузиться обратно в Ubuntu Touch (Slot B):**
  ```bash
  fastboot --set-active=b
  fastboot reboot
  ```

---

## 🛠 Отладка по USB (RNDIS / Telnet / SSH)

При загрузке Слота B телефон автоматически поднимает виртуальную сетевую карту **USB RNDIS** с IP-адресом **`10.15.19.82`**:
```bash
# Подключение к ранней отладочной консоли или шеллу Ubuntu Touch:
telnet 10.15.19.82 23
# Или по SSH:
ssh phablet@10.15.19.82
```

---

## 📂 Структура репозитория

* [`.github/workflows/build-ubuntu-touch.yml`](.github/workflows/build-ubuntu-touch.yml) — полный CI/CD пайплайн сборки ядра `6.1.145-halium`, модулей `gs201`, `init_boot_b.img` и образа `system_b.img`.
* [`configs/halium_panther.config`](configs/halium_panther.config) — фрагмент конфигурации ядра под Ubuntu Touch, AppArmor, LXC, SquashFS/OverlayFS и беспроводные интерфейсы.
* [`scripts/flash-slot-b.bat`](scripts/flash-slot-b.bat) — безопасный установщик Ubuntu Touch в Слот B.
* [`scripts/switch-to-android.bat`](scripts/switch-to-android.bat) — скрипт быстрого возврата в Слот A (Android).
