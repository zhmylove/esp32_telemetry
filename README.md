# Description

A little ESP32 based telemetry service.

# Usage

1. Create `config.h`:
   ```
   #ifndef _CONFIG_GUARD
   #define _CONFIG_GUARD
   #define POST_URL "https://microsoft.com"
   #define WIFI_SSID "ZHMY"
   #define WIFI_PASS "LOVELOVE"
   #endif /* _CONFIG_GUARD */
    ```
2. Compile and flash the `esp32_telemetry.ino` into a ESP32, and connect the sensors.
3. Run `server.pl`

# Connection scheme

![Connection scheme](scheme.svg)
