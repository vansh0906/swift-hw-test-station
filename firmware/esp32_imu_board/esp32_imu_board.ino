// IMU-BOARD-A test firmware for an ESP32 with an MPU-6050 (I2C on SDA=21, SCL=22).
// Speaks the same framed line protocol as the simulator, so `hwtest run --port /dev/cu.usbserial-XXXX`
// tests a real board exactly like a simulated one. Serial: 115200 baud, 8N1.
//
// VBUS: wire a 100k/100k divider from 3V3 to GPIO34 so the board can measure its own 3.3 V rail.
#include <Arduino.h>
#include <Wire.h>
#include "protocol.h"

static const uint8_t MPU = 0x68;
static const int VBUS_PIN = 34;

static bool mpuWrite(uint8_t reg, uint8_t value) {
  Wire.beginTransmission(MPU);
  Wire.write(reg);
  Wire.write(value);
  return Wire.endTransmission() == 0;
}

static bool mpuRead(uint8_t reg, uint8_t *buf, uint8_t n) {
  Wire.beginTransmission(MPU);
  Wire.write(reg);
  if (Wire.endTransmission(false) != 0) return false;
  if (Wire.requestFrom((int)MPU, (int)n) != n) return false;
  for (uint8_t i = 0; i < n; ++i) buf[i] = Wire.read();
  return true;
}

static int16_t be16(const uint8_t *p) { return (int16_t)((p[0] << 8) | p[1]); }

struct Esp32Board : proto::Board {
  char serialText[20];
  Esp32Board() {
    uint64_t mac = ESP.getEfuseMac();
    snprintf(serialText, sizeof(serialText), "SN%06lX", (unsigned long)(mac & 0xFFFFFF));
  }
  const char *product() override { return "IMU-BOARD-A"; }
  const char *firmware() override { return "1.2.0"; }
  const char *serial() override { return serialText; }
  float vbus() override { return 2.0f * analogReadMilliVolts(VBUS_PIN) / 1000.0f; }
  float temperatureC() override {
    uint8_t b[2];
    if (!mpuRead(0x41, b, 2)) return -273.0f;
    return be16(b) / 340.0f + 36.53f;
  }
  void accel(float *v) override {             // +/-2 g range: 16384 LSB per g
    uint8_t b[6];
    if (!mpuRead(0x3B, b, 6)) { v[0] = v[1] = v[2] = 0; return; }
    for (int i = 0; i < 3; ++i) v[i] = be16(b + 2 * i) / 16384.0f * 9.80665f;
  }
  void gyro(float *v) override {              // +/-250 deg/s range: 131 LSB per deg/s
    uint8_t b[6];
    if (!mpuRead(0x43, b, 6)) { v[0] = v[1] = v[2] = 0; return; }
    for (int i = 0; i < 3; ++i) v[i] = be16(b + 2 * i) / 131.0f * 0.0174533f;
  }
  bool selfTest(uint8_t *code) override {     // chip answers with the right ID and sees about 1 g
    uint8_t who = 0;
    if (!mpuRead(0x75, &who, 1)) { *code = 0x01; return false; }
    if (who != 0x68) { *code = 0x02; return false; }
    float a[3];
    accel(a);
    float g = sqrtf(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]);
    if (g < 8.0f || g > 11.5f) { *code = 0x04; return false; }
    *code = 0x00;
    return true;
  }
};

static Esp32Board *board = nullptr;
static char line[96];
static size_t lineLen = 0;

void setup() {
  Serial.begin(115200);
  Wire.begin(21, 22);
  mpuWrite(0x6B, 0x00);   // wake up (clear sleep bit)
  mpuWrite(0x1C, 0x00);   // accel +/-2 g
  mpuWrite(0x1B, 0x00);   // gyro +/-250 deg/s
  analogReadResolution(12);
  board = new Esp32Board();
}

void loop() {
  while (Serial.available() > 0) {
    char c = (char)Serial.read();
    if (c == '\n') {
      line[lineLen] = 0;
      char out[160];
      size_t n = proto::handle(*board, line, out, sizeof(out));
      if (n > 0) Serial.write((const uint8_t *)out, n);
      lineLen = 0;
    } else if (c != '\r' && lineLen < sizeof(line) - 1) {
      line[lineLen++] = c;
    } else if (lineLen >= sizeof(line) - 1) {
      lineLen = 0;            // overlong line: drop it, the host will retry
    }
  }
}
