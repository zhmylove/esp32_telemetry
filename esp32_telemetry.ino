/* vim: set ts=4 sw=4 cc=119 : */
#include <Wire.h>
#include <WiFi.h>
#include <HTTPClient.h>

#define PIN_MOTION 23
#define BH1750_ADDR 0x23
#define BH1750_VALUES ((uint16_t)((SECONDS_TRANSMISSION / SECONDS_BH1750) + 2))
#define SECONDS_BH1750 5
#define SECONDS_TRANSMISSION 60
#define SECONDS_TRANSMISSION_WDT (5 * 60) // restart unless HTTP 200 got within 5 minutes

/* This should define POST_URL, WIFI_SSID and WIFI_PASS */
#include "config.h"

uint16_t count_door = 0;
uint16_t count_motion = 0;
uint16_t count_bh1750 = 0;
uint16_t data_bh1750[BH1750_VALUES];
hw_timer_t *timer_bh1750 = NULL;
hw_timer_t *timer_bh1750_ready = NULL;
hw_timer_t *timer_transmission = NULL;
enum bh1750_state_t { SENT, READY };
bh1750_state_t bh1750_state = READY;

volatile SemaphoreHandle_t sem_bh1750;
volatile SemaphoreHandle_t sem_bh1750_ready;
volatile SemaphoreHandle_t sem_transmission;

portMUX_TYPE mux_door = portMUX_INITIALIZER_UNLOCKED;
portMUX_TYPE mux_motion = portMUX_INITIALIZER_UNLOCKED;

NetworkClientSecure client;
unsigned long last_update = 0;

void ARDUINO_ISR_ATTR door_rise() {
    portENTER_CRITICAL_ISR(&mux_door);
    count_door++;
    portEXIT_CRITICAL_ISR(&mux_door);
    isr_log_d("Door rise: %d", count_door);
}

void ARDUINO_ISR_ATTR motion_rise() {
    portENTER_CRITICAL_ISR(&mux_motion);
    count_motion++;
    portEXIT_CRITICAL_ISR(&mux_motion);
    isr_log_d("Motion rise: %d", count_motion);
}

void ARDUINO_ISR_ATTR bh1750_tick() {
    xSemaphoreGiveFromISR(sem_bh1750, NULL);
    isr_log_v("bh1750");
}

void ARDUINO_ISR_ATTR bh1750_ready_tick() {
    xSemaphoreGiveFromISR(sem_bh1750_ready, NULL);
    isr_log_v("bh1750_ready_tick");
}

void ARDUINO_ISR_ATTR transmission_tick() {
    xSemaphoreGiveFromISR(sem_transmission, NULL);
    isr_log_v("transmission_tick");

    if (millis() - last_update >= SECONDS_TRANSMISSION_WDT * 1000) {
        isr_log_e("WATCHDOG TIMEOUT! Resetting");
        ESP.restart();
    }
}

void setup() {
    log_i("Starting up");

    client.setInsecure(); // to avoid issues whenever my rootCA is updated; MITM shall not pass

    Wire.begin();

    sem_bh1750 = xSemaphoreCreateBinary();
    sem_bh1750_ready = xSemaphoreCreateBinary();
    sem_transmission = xSemaphoreCreateBinary();

    uint16_t init_delay = 60000; // HC SR-501 takes up to 60 sec to initialize, see datasheet

    log_i("Connecting to WiFi: %s", WIFI_SSID);
    WiFi.begin(WIFI_SSID, WIFI_PASS);
    while (init_delay > 0 && WiFi.status() != WL_CONNECTED) {
        init_delay -= 500;
        delay(500);
    }

    if (init_delay <= 0) {
        log_e("Unable to establish WiFi connection. Resetting");
        ESP.restart();
    }

    WiFi.setAutoReconnect(true);
    log_d("WiFi got IP: %s", WiFi.localIP().toString());

    log_v("Waiting %d ms more to init BH1750", init_delay);
    delay(init_delay);

    last_update = millis();

    log_d("Setting timers");
    timer_bh1750 = timerBegin(1000000);
    timer_bh1750_ready = timerBegin(1000000);
    timer_transmission = timerBegin(1000000);

    timerAttachInterrupt(timer_bh1750, &bh1750_tick);
    timerAttachInterrupt(timer_bh1750_ready, &bh1750_ready_tick);
    timerAttachInterrupt(timer_transmission, &transmission_tick);

    timerAlarm(timer_bh1750, SECONDS_BH1750 * 1000000, true, 0);
    timerAlarm(timer_transmission, SECONDS_TRANSMISSION * 1000000, true, 0);

    pinMode(PIN_MOTION, INPUT);
    attachInterrupt(PIN_MOTION, motion_rise, RISING);

    log_i("Checklist completed. S.O.B");
}

void loop() {
    if (xSemaphoreTake(sem_bh1750, 0) == pdTRUE) {
        if (count_bh1750 >= sizeof(data_bh1750) / sizeof(uint16_t)) {
            return;
        }

        if (bh1750_state != READY) {
            return;
        }

        log_v("Lux tick #%02d, asking the sensor", count_bh1750);

        Wire.beginTransmission(BH1750_ADDR);
        Wire.write(0x21);
        Wire.endTransmission();
        bh1750_state = SENT;
        timerRestart(timer_bh1750_ready);
        timerAlarm(timer_bh1750_ready, 185 * 1000, false, 0); // see datasheet
    }

    if (xSemaphoreTake(sem_bh1750_ready, 0) == pdTRUE) {
        if (bh1750_state != SENT) {
            return;
        }

        Wire.requestFrom(BH1750_ADDR, 2);
        uint16_t light_level = 0;
        if (Wire.available() == 2) {
            light_level = Wire.read() << 8;
            light_level |= Wire.read();

            data_bh1750[count_bh1750++] = light_level;
            log_v("Lux got: %d", light_level);
        } else {
            log_e("Error getting lux");
        }

        bh1750_state = READY; // despite any errors
    }

    if (xSemaphoreTake(sem_transmission, 0) == pdTRUE) {
        log_v("Transmission door=%d motion=%d lux_cnt=%d", count_door, count_motion, count_bh1750);

        bool internal_got = false;
        uint16_t internal_count_door = 0;
        uint16_t internal_count_motion = 0;

        // Compute median for lightness
        uint16_t median_bh1750;
        if (count_bh1750 == 0) {
            median_bh1750 = 0;
        } else if (count_bh1750 <= 2) {
            median_bh1750 = data_bh1750[0];
        } else {
            std::sort(data_bh1750, data_bh1750 + count_bh1750);
            median_bh1750 = data_bh1750[count_bh1750 / 2];
        }

        // WiFi could be reconnecting now
        uint8_t retry = 1500;
        while (retry > 0 && WiFi.status() != WL_CONNECTED) {
            retry -= 500;
            delay(500);
        }
        if (retry <= 0) {
            log_e("WiFi connection is unstable. Resetting");
            ESP.restart();
        }

        HTTPClient https;
        if (https.begin(client, POST_URL)) {
            // Prepare data
            portENTER_CRITICAL_ISR(&mux_door);
            portENTER_CRITICAL_ISR(&mux_motion);
            internal_count_door = count_door;
            internal_count_motion = count_motion;
            count_door = 0;
            count_motion = 0;
            portEXIT_CRITICAL_ISR(&mux_door);
            portEXIT_CRITICAL_ISR(&mux_motion);
            count_bh1750 = 0;
            internal_got = true;

            uint8_t req_body[40 + 1];
            size_t req_size = snprintf((char*)req_body, sizeof(req_body),
                    "{\"door\":%d,\"lux\":%d,\"move\":%d}",
                    internal_count_door,
                    median_bh1750,
                    internal_count_motion
                    );

            https.addHeader("Content-Type", "application/json");
            log_v("POST: %s", (char*)req_body);
            int code = https.POST(req_body, req_size);

            if (code == 200) {
                last_update = millis();
            } else {
#if ARDUHAL_LOG_LEVEL >= ARDUHAL_LOG_LEVEL_ERROR
                String message = code < 0 ? https.errorToString(code) : String(code);
                log_e("Error sending POST: %s", message.c_str());
#endif /* ARDUHAL_LOG_LEVEL >= ARDUHAL_LOG_LEVEL_ERROR */
            }

            https.end();
        } else {
            log_e("Error connecting the server");
        }

        // Reset the data unless already done
        if (! internal_got) {
            portENTER_CRITICAL_ISR(&mux_door);
            count_door = 0;
            portEXIT_CRITICAL_ISR(&mux_door);
            portENTER_CRITICAL_ISR(&mux_motion);
            count_motion = 0;
            portEXIT_CRITICAL_ISR(&mux_motion);
            count_bh1750 = 0;
        }
    }
}
