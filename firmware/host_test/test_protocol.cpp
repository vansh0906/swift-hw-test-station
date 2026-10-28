// Host-side test of the firmware protocol (no ESP32 needed): g++ -std=c++17 -Wall -Wextra -o test_protocol test_protocol.cpp
#include "../esp32_imu_board/protocol.h"
#include <string>
#include <cstdio>

static int failures = 0;
#define CHECK(cond) do { if (!(cond)) { std::printf("FAIL line %d: %s\n", __LINE__, #cond); ++failures; } } while (0)

struct FakeBoard : proto::Board {
  const char *product() override { return "IMU-BOARD-A"; }
  const char *firmware() override { return "1.2.0"; }
  const char *serial() override { return "SN00042"; }
  float vbus() override { return 3.301f; }
  float temperatureC() override { return 31.0f; }
  void accel(float *v) override { v[0] = 0.02f; v[1] = -0.01f; v[2] = 9.81f; }
  void gyro(float *v) override { v[0] = 0.002f; v[1] = -0.001f; v[2] = 0.003f; }
  bool selfTest(uint8_t *code) override { *code = 0; return true; }
};

int main() {
  // Same vectors as tools/crc8_vectors.py and the Swift tests.
  CHECK(proto::crc8("123456789", 9) == 0xF4);
  char out[160];
  proto::encode(1, "ID?", out, sizeof(out));
  CHECK(std::string(out) == "1:ID?*0F\n");
  proto::encode(7, "READ ACC", out, sizeof(out));
  CHECK(std::string(out) == "7:READ ACC*A6\n");
  proto::encode(12, "ST PASS,0x00", out, sizeof(out));
  CHECK(std::string(out) == "12:ST PASS,0x00*04\n");

  long seq = 0;
  char payload[64];
  CHECK(proto::decode("7:READ ACC*A6\r\n", &seq, payload, sizeof(payload)) && seq == 7 && std::string(payload) == "READ ACC");
  CHECK(!proto::decode("7:READ ACC*A7", &seq, payload, sizeof(payload)));   // wrong CRC
  CHECK(!proto::decode("7:READ ACC", &seq, payload, sizeof(payload)));      // no CRC
  CHECK(!proto::decode("x:READ ACC*00", &seq, payload, sizeof(payload)));   // bad sequence number

  FakeBoard board;
  proto::handle(board, "3:ID?*", out, sizeof(out));                           // corrupted request
  CHECK(std::string(out).rfind("0:ERR FRAME*", 0) == 0);
  char req[64];
  proto::encode(3, "ID?", req, sizeof(req));
  proto::handle(board, req, out, sizeof(out));
  CHECK(std::string(out) == "3:ID IMU-BOARD-A,1.2.0,SN00042*9B\n");          // vector from tools/crc8_vectors.py
  proto::encode(4, "READ ACC", req, sizeof(req));
  proto::handle(board, req, out, sizeof(out));
  CHECK(proto::decode(out, &seq, payload, sizeof(payload)) && seq == 4 && std::string(payload) == "ACC 0.0200,-0.0100,9.8100");
  proto::encode(5, "SELFTEST", req, sizeof(req));
  proto::handle(board, req, out, sizeof(out));
  CHECK(proto::decode(out, &seq, payload, sizeof(payload)) && std::string(payload) == "ST PASS,0x00");
  proto::encode(6, "DANCE", req, sizeof(req));
  proto::handle(board, req, out, sizeof(out));
  CHECK(proto::decode(out, &seq, payload, sizeof(payload)) && std::string(payload) == "ERR UNKNOWN");

  std::printf("%s (%d failures)\n", failures ? "FIRMWARE PROTOCOL TESTS FAILED" : "all firmware protocol tests passed", failures);
  return failures ? 1 : 0;
}
