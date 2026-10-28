// Line protocol shared with the Swift test station (Sources/HWTestKit/Frame.swift).
// A frame is "<seq>:<payload>*<CRC-8 hex>\n"; CRC-8 polynomial 0x07, initial value 0x00.
// Plain C++ with no Arduino calls, so it is unit-tested on a PC in firmware/host_test/.
#pragma once
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

namespace proto {

inline uint8_t crc8(const char *data, size_t len) {
  uint8_t crc = 0;
  for (size_t i = 0; i < len; ++i) {
    crc ^= (uint8_t)data[i];
    for (int b = 0; b < 8; ++b) crc = (crc & 0x80) ? (uint8_t)((crc << 1) ^ 0x07) : (uint8_t)(crc << 1);
  }
  return crc;
}

// Parses "<seq>:<payload>*<CRC>" (trailing \r or \n allowed). Copies the payload out.
// Returns true only if the frame is well formed and the CRC matches.
inline bool decode(const char *line, long *seq, char *payload, size_t payloadSize) {
  size_t len = strlen(line);
  while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r')) --len;
  const char *star = nullptr;
  for (size_t i = len; i > 0; --i) {
    if (line[i - 1] == '*') { star = line + i - 1; break; }
  }
  if (!star || (size_t)(line + len - star) != 3) return false;
  char hex[3] = {star[1], star[2], 0};
  char *end = nullptr;
  long got = strtol(hex, &end, 16);
  if (end != hex + 2) return false;
  size_t bodyLen = (size_t)(star - line);
  if (crc8(line, bodyLen) != (uint8_t)got) return false;
  const char *colon = (const char *)memchr(line, ':', bodyLen);
  if (!colon || colon == line) return false;
  char num[16];
  size_t numLen = (size_t)(colon - line);
  if (numLen >= sizeof(num)) return false;
  memcpy(num, line, numLen);
  num[numLen] = 0;
  *seq = strtol(num, &end, 10);
  if (*end != 0) return false;
  size_t pl = bodyLen - numLen - 1;
  if (pl + 1 > payloadSize) return false;
  memcpy(payload, colon + 1, pl);
  payload[pl] = 0;
  return true;
}

// Builds "<seq>:<payload>*<CRC>\n" into out. Returns the length written (0 if it does not fit).
inline size_t encode(long seq, const char *payload, char *out, size_t outSize) {
  int n = snprintf(out, outSize, "%ld:%s", seq, payload);
  if (n < 0 || (size_t)n + 4 >= outSize) return 0;
  uint8_t c = crc8(out, (size_t)n);
  int m = snprintf(out + n, outSize - (size_t)n, "*%02X\n", c);
  return (size_t)(n + m);
}

// What the board must provide; the ESP32 sketch reads a real MPU-6050, the host test uses fixed values.
struct Board {
  virtual ~Board() {}
  virtual const char *product() = 0;
  virtual const char *firmware() = 0;
  virtual const char *serial() = 0;
  virtual float vbus() = 0;
  virtual float temperatureC() = 0;
  virtual void accel(float *xyz) = 0;  // m/s^2
  virtual void gyro(float *xyz) = 0;   // rad/s
  virtual bool selfTest(uint8_t *code) = 0;
};

// Handles one request line and writes the reply frame into out. Returns reply length (0 = no reply).
inline size_t handle(Board &board, const char *line, char *out, size_t outSize) {
  long seq = 0;
  char cmd[64];
  char reply[128];
  if (!decode(line, &seq, cmd, sizeof(cmd))) return encode(0, "ERR FRAME", out, outSize);
  float v[3];
  if (strcmp(cmd, "ID?") == 0) {
    snprintf(reply, sizeof(reply), "ID %s,%s,%s", board.product(), board.firmware(), board.serial());
  } else if (strcmp(cmd, "READ VBUS") == 0) {
    snprintf(reply, sizeof(reply), "VBUS %.3f", (double)board.vbus());
  } else if (strcmp(cmd, "READ TEMP") == 0) {
    snprintf(reply, sizeof(reply), "TEMP %.2f", (double)board.temperatureC());
  } else if (strcmp(cmd, "READ ACC") == 0) {
    board.accel(v);
    snprintf(reply, sizeof(reply), "ACC %.4f,%.4f,%.4f", (double)v[0], (double)v[1], (double)v[2]);
  } else if (strcmp(cmd, "READ GYR") == 0) {
    board.gyro(v);
    snprintf(reply, sizeof(reply), "GYR %.5f,%.5f,%.5f", (double)v[0], (double)v[1], (double)v[2]);
  } else if (strcmp(cmd, "SELFTEST") == 0) {
    uint8_t code = 0;
    bool ok = board.selfTest(&code);
    snprintf(reply, sizeof(reply), "ST %s,0x%02X", ok ? "PASS" : "FAIL", code);
  } else {
    snprintf(reply, sizeof(reply), "ERR UNKNOWN");
  }
  return encode(seq, reply, out, outSize);
}

}  // namespace proto
