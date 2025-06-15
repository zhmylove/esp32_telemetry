#include <Wire.h>

#define DEBUG

#define PIN_MOTION 23
#define BH1750_ADDR 0x23
#define BH1750_VALUES ((uint16_t)((SECONDS_TRANSMISSION / SECONDS_BH1750) + 2))
#define SECONDS_BH1750 10
#define SECONDS_TRANSMISSION 30

uint16_t count_door = 0;
uint16_t count_motion = 0;
uint16_t count_bh1750 = 0;
float data_bh1750[BH1750_VALUES];
hw_timer_t *timer_bh1750 = NULL;
hw_timer_t *timer_bh1750_ready = NULL;
hw_timer_t *timer_transmission = NULL;
enum bh1750_state_t { SENT, READY };
bh1750_state_t bh1750_state = READY;

#ifdef DEBUG
volatile SemaphoreHandle_t sem_door;
volatile SemaphoreHandle_t sem_motion;
#endif /* DEBUG */

volatile SemaphoreHandle_t sem_bh1750;
volatile SemaphoreHandle_t sem_bh1750_ready;
volatile SemaphoreHandle_t sem_transmission;

portMUX_TYPE mux_door = portMUX_INITIALIZER_UNLOCKED;
portMUX_TYPE mux_motion = portMUX_INITIALIZER_UNLOCKED;

void ARDUINO_ISR_ATTR door_rise() {
    portENTER_CRITICAL_ISR(&mux_door);
    count_door++;
    portEXIT_CRITICAL_ISR(&mux_door);

#ifdef DEBUG
    xSemaphoreGiveFromISR(sem_door, NULL);
#endif /* DEBUG */
}

void ARDUINO_ISR_ATTR motion_rise() {
    portENTER_CRITICAL_ISR(&mux_motion);
    count_motion++;
    portEXIT_CRITICAL_ISR(&mux_motion);

#ifdef DEBUG
    xSemaphoreGiveFromISR(sem_motion, NULL);
#endif /* DEBUG */
}

void ARDUINO_ISR_ATTR bh1750_tick() {
    xSemaphoreGiveFromISR(sem_bh1750, NULL);
}

void ARDUINO_ISR_ATTR bh1750_ready_tick() {
    xSemaphoreGiveFromISR(sem_bh1750_ready, NULL);
}

void ARDUINO_ISR_ATTR transmission_tick() {
    xSemaphoreGiveFromISR(sem_transmission, NULL);
}

void setup() {
#ifdef DEBUG
    Serial.begin(115200);
    Serial.println("Starting up");
#endif /* DEBUG */

    pinMode(PIN_MOTION, INPUT);
    attachInterrupt(PIN_MOTION, motion_rise, RISING);

    Wire.begin();

#ifdef DEBUG
    sem_door = xSemaphoreCreateBinary();
    sem_motion = xSemaphoreCreateBinary();
#endif /* DEBUG */

    sem_bh1750 = xSemaphoreCreateBinary();
    sem_bh1750_ready = xSemaphoreCreateBinary();
    sem_transmission = xSemaphoreCreateBinary();

    timer_bh1750 = timerBegin(1000000);
    timer_transmission = timerBegin(1000000);

    timerAttachInterrupt(timer_bh1750, &bh1750_tick);
    timerAttachInterrupt(timer_bh1750_ready, &bh1750_ready_tick);
    timerAttachInterrupt(timer_transmission, &transmission_tick);

    delay(3000);

#ifdef DEBUG
    Serial.println("Ready");
#endif /* DEBUG */

    timerAlarm(timer_bh1750, SECONDS_BH1750 * 1000000, true, 0);
    timerAlarm(timer_transmission, SECONDS_TRANSMISSION * 1000000, true, 0);
}

void loop() {
#ifdef DEBUG
    if (xSemaphoreTake(sem_motion, 0) == pdTRUE) {
        Serial.println("Motion rise");
    }
#endif /* DEBUG */

    if (xSemaphoreTake(sem_bh1750, 0) == pdTRUE) {
        if (count_bh1750 >= sizeof(data_bh1750) / sizeof(float)) {
            return;
        }

        if (bh1750_state != READY) {
            return;
        }

#ifdef DEBUG
        Serial.printf("Lux tick (%02d), asking...", count_bh1750);
#endif /* DEBUG */

        Wire.beginTransmission(BH1750_ADDR);
        Wire.write(0x21);
        Wire.endTransmission();
        bh1750_state = SENT;
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

            float lux = light_level;
            data_bh1750[count_bh1750++] = lux;

#ifdef DEBUG
            Serial.printf("...lux got: %d\r\n", lux);
#endif /* DEBUG */
        } else {
#ifdef DEBUG
            Serial.println("Error getting lux");
#endif /* DEBUG */
        }

        bh1750_state = READY; // ignoring any errors
    }

    if (xSemaphoreTake(sem_transmission, 0) == pdTRUE) {
#ifdef DEBUG
        Serial.printf("Transmission door=%02d motion=%02d lux=%04d\r\n", count_door, count_motion, count_bh1750);
#endif /* DEBUG */

        // Compute median lightness

        // Reset the data
        count_door = 0;
        count_motion = 0;
        count_bh1750 = 0;
    }
}
