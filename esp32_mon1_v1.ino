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
hw_timer_t *timer_transmission = NULL;

volatile SemaphoreHandle_t sem_motion;
volatile SemaphoreHandle_t sem_bh1750;
volatile SemaphoreHandle_t sem_transmission;

void ARDUINO_ISR_ATTR motion_rise() {
    xSemaphoreGiveFromISR(sem_motion, NULL);
}

void ARDUINO_ISR_ATTR bh1750_tick() {
    xSemaphoreGiveFromISR(sem_bh1750, NULL);
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

    sem_motion = xSemaphoreCreateBinary();
    sem_bh1750 = xSemaphoreCreateBinary();
    sem_transmission = xSemaphoreCreateBinary();

    timer_bh1750 = timerBegin(1000000);
    timer_transmission = timerBegin(1000000);

    timerAttachInterrupt(timer_bh1750, &bh1750_tick);
    timerAttachInterrupt(timer_transmission, &transmission_tick);

    delay(3000);

#ifdef DEBUG
    Serial.println("Ready");
#endif /* DEBUG */

    timerAlarm(timer_bh1750, SECONDS_BH1750 * 1000000, true, 0);
    timerAlarm(timer_transmission, SECONDS_TRANSMISSION * 1000000, true, 0);
}

void loop() {
    if (xSemaphoreTake(sem_motion, 0) == pdTRUE) {
#ifdef DEBUG
        Serial.println("Motion rise");
#endif /* DEBUG */

        count_motion++;
    }

    if (xSemaphoreTake(sem_bh1750, 0) == pdTRUE) {
        if (count_bh1750 >= sizeof(data_bh1750) / sizeof(float)) {
            return;
        }

#ifdef DEBUG
        Serial.printf("Lux tick (%02d): ", count_bh1750);
#endif /* DEBUG */

        uint16_t light_level = 0;
        Wire.beginTransmission(BH1750_ADDR);
        Wire.write(0x21);
        Wire.endTransmission();
        delay(200);
        Wire.requestFrom(BH1750_ADDR, 2);
        if (Wire.available() == 2) {
            light_level = Wire.read() << 8;
            light_level |= Wire.read();
        }
        float lux = light_level / 1.2;
        data_bh1750[count_bh1750++] = lux;

#ifdef DEBUG
        Serial.println(lux);
#endif /* DEBUG */
    }

    if (xSemaphoreTake(sem_transmission, 0) == pdTRUE) {
#ifdef DEBUG
        Serial.printf("Transmission door=%02d motion=%02d lux=%04d\r\n", count_door, count_motion, count_bh1750);
#endif /* DEBUG */

        // Reset the data
        count_door = 0;
        count_motion = 0;
        count_bh1750 = 0;
    }
}
