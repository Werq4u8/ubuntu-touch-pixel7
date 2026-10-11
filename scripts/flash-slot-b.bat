@echo off
chcp 65001 >nul
echo ============================================================================
echo   Ubuntu Touch (Slot B) Safe Dual-Boot Installer for Google Pixel 7 (panther)
echo   ВНИМАНИЕ: Слот A (Android) и раздел userdata (sda31) НЕ затрагиваются!
echo ============================================================================
echo.

where fastboot >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo [!] fastboot.exe не найден в PATH. Положите этот скрипт рядом с fastboot.exe и образами.
    pause
    exit /b 1
)

echo [1/6] Проверка подключения устройства в режиме Bootloader...
fastboot getvar product 2>&1 | findstr /i "panther" >nul
if %ERRORLEVEL% NEQ 0 (
    echo [!] Устройство Pixel 7 ^(panther^) не найдено в режиме fastboot!
    pause
    exit /b 1
)

echo [2/6] Отключение проверки AVB ТОЛЬКО для Слота B ^(vbmeta_b^)...
if exist vbmeta_b.img (
    fastboot --disable-verity --disable-verification flash vbmeta_b vbmeta_b.img
)

echo [3/6] Прошивка загрузочных разделов Слота B ^(boot_b, init_boot_b, vendor_kernel_boot_b, dtbo_b^)...
fastboot flash boot_b boot_b.img
fastboot flash init_boot_b init_boot_b.img
fastboot flash vendor_kernel_boot_b vendor_kernel_boot_b.img
fastboot flash dtbo_b dtbo_b.img
if exist vendor_boot_b.img (
    fastboot flash vendor_boot_b vendor_boot_b.img
)

echo [4/6] Переход в пользовательский fastbootd для разметки свободного места в super под Слот B...
fastboot reboot fastboot
timeout /t 5 >nul

echo [5/6] Создание и прошивка логических разделов Слота B внутри super...
fastboot delete-logical-partition system_b 2>nul
fastboot delete-logical-partition system_ext_b 2>nul
fastboot delete-logical-partition product_b 2>nul
fastboot delete-logical-partition vendor_b 2>nul
fastboot delete-logical-partition vendor_dlkm_b 2>nul
fastboot delete-logical-partition system_dlkm_b 2>nul

fastboot create-logical-partition vendor_dlkm_b 52428800
fastboot create-logical-partition system_dlkm_b 16777216
fastboot create-logical-partition system_b 1153433600
fastboot create-logical-partition product_b 536870912

fastboot flash vendor_dlkm_b vendor_dlkm_b.img
fastboot flash system_dlkm_b system_dlkm_b.img
fastboot flash system_b system_b.img
if exist product_b.img (
    fastboot flash product_b product_b.img
)

echo [6/6] Активация Слота B и перезагрузка в Ubuntu Touch!
fastboot --set-active=b
fastboot reboot

echo.
echo [ГОТОВО] Телефон перезагружается в Слот B ^(Ubuntu Touch^).
echo          Отладочная консоль и SSH доступны по USB RNDIS: 10.15.19.82
echo          Чтобы вернуться в Android ^(Слот A^): fastboot --set-active=a ^&^& fastboot reboot
pause
