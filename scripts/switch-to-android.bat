@echo off
chcp 65001 >nul
echo ============================================================================
echo   Возврат в основную систему Android (Slot A) — Google Pixel 7 (panther)
echo ============================================================================
fastboot --set-active=a
fastboot reboot
echo [ГОТОВО] Активный слот переключен обратно на Slot A (Android).
pause
