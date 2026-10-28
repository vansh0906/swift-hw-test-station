# hwtest: A Factory-Style Hardware Test Station in Swift

[![hwtest-ci](https://github.com/vansh0906/swift-hw-test-station/actions/workflows/ci.yml/badge.svg)](https://github.com/vansh0906/swift-hw-test-station/actions/workflows/ci.yml)

A **macOS command-line tool written in Swift** that tests sensor boards over a **serial port**, the way a production test station does. It works through a **hardware test specification** (JSON), talks to the device with a **CRC-checked line protocol**, judges every measurement against limits, and writes a **JSON report and a CSV log line for every unit**.

It runs against three kinds of device through the same code path:

- **Simulated boards** on a **pseudo-terminal**, with 12 kinds of injected defects plus a noisy link, so everything can be tested without hardware.
- **A real ESP32 + MPU-6050 board** running the firmware in `firmware/` over a USB-serial port.
- **A bench of 200 simulated boards** tested by **8 parallel stations**, which produces the requirement table below.

## How it works

| Part | File | What it does |
|---|---|---|
| Protocol | `Sources/HWTestKit/Frame.swift` | Frames are `<seq>:<payload>*<CRC-8>\n`. CRC-8 (polynomial 0x07) catches every corrupted byte; the sequence number lets the host reject a **late reply to an earlier request** |
| Serial port | `SerialPort.swift` | POSIX `termios` in raw 8N1 mode, non-blocking reads with `poll()` timeouts, line buffering; also creates **pseudo-terminal pairs** with `posix_openpt` |
| Test spec | `TestSpec.swift`, `specs/imu_board_a.json` | Steps with four check types: `equals`, `version` (minimum firmware), `range` (mean of N samples within limits) and `noise` (standard deviation within limits). The spec is validated before use |
| Runner | `TestRunner.swift` | Runs every step with **retries on CRC errors and timeouts**, stops early if the device stops answering or a gating step fails, and records retries, CRC errors, timeouts and stale replies |
| Simulator | `DeviceSimulator.swift` | An IMU board with realistic noise and 13 fault modes, served on a pseudo-terminal by its own thread |
| Reports | `Report.swift` | One pretty-printed JSON file per unit plus a `summary.csv` line, thread-safe for parallel stations |
| Bench | `Bench.swift` | 200 boards (70 % good, 10 % good on a noisy link, 20 % defective), 8 station threads, and the requirement table |
| Firmware | `firmware/esp32_imu_board/` | ESP32 Arduino sketch for a real MPU-6050 board; its protocol code is unit-tested on a PC (`firmware/host_test/`) |
| CLI | `Sources/hwtest/main.swift` | `run`, `sim`, `bench`, `check-spec`, `ports` |
| Self-tests | `Sources/selftest/main.swift` | Protocol, CRC vectors, spec validation, every fault, stale replies, reports and a real pseudo-terminal; a plain program, so it runs with only the Command Line Tools (no Xcode) |

### The test specification

```json
{ "name": "accel_noise", "command": "READ ACC", "check": "noise", "key": "ACC",
  "fields": [0, 1, 2], "minStd": 0.002, "maxStd": 0.15, "samples": 20, "unit": "m/s2" }
```

A **stuck** accelerometer (identical readings) fails the lower noise limit; a **noisy** one fails the upper limit. A sensor reading that never changes is a classic production escape, which is why a noise check has a minimum as well as a maximum.

### Faults the simulator can inject

| Fault | What it models | Should fail at |
|---|---|---|
| `wrong_product` | wrong board variant on the fixture | `identify` |
| `old_firmware` | firmware below 1.2.0 | `firmware_version` |
| `low_voltage` | 3.3 V rail at 3.05 V | `supply_voltage` |
| `over_temp` | board at 72 °C | `temperature` |
| `dead_accel` | accelerometer sees no gravity | `accel_gravity` |
| `stuck_accel` | accelerometer repeats one value | `accel_noise` |
| `noisy_accel` | accelerometer noise 25x normal | `accel_noise` |
| `gyro_bias` | gyro offset 0.2 rad/s | `gyro_bias` |
| `selftest_fail` | on-chip self-test fails | `selftest` |
| `slow_response` | answers after 400 ms (limit 200 ms) | `identify` |
| `silent` | no answer at all | `identify` |
| `garbage` | replies that are not valid frames (wrong baud rate) | `identify` |
| `link_noise` | **good** board, 5 % of replies corrupted on the cable | must **pass** |

## Results

<!-- results:start -->
```text
[1  Production run: 200 simulated IMU-BOARD-A boards, 8 parallel stations]
  every board is served on its own pseudo-terminal and tested through the real serial-port code
  units tested 200: good 160 (of which 20 on a noisy link), defective 40
  yield 80.0 %, false failures 0, escapes 0
  link: 60 CRC errors and 75 retries, 3 stale replies rejected
  wall time 4.6 s = 156383 units per hour

[2  Defects: was each one caught at the right step?]
  fault             units caught  first failing step (expected)
  wrong_product         4      4  identify (identify)
  old_firmware          4      4  firmware_version (firmware_version)
  low_voltage           4      4  supply_voltage (supply_voltage)
  over_temp             4      4  temperature (temperature)
  dead_accel            3      3  accel_gravity (accel_gravity)
  stuck_accel           3      3  accel_noise (accel_noise)
  noisy_accel           3      3  accel_noise (accel_noise)
  gyro_bias             3      3  gyro_bias (gyro_bias)
  selftest_fail         3      3  selftest (selftest)
  slow_response         3      3  identify (identify)
  silent                3      3  identify (identify)
  garbage               3      3  identify (identify)

[3  Unresponsive boards: time to a verdict]
  6 silent or slow boards; slowest verdict 806 ms (budget 1300 ms = 200 ms x 4 attempts + 0.5 s)

[4  Station scaling: the same first 48 units on 1 station vs. 8 stations]
  1 station 8.95 s, 8 stations 1.93 s: 4.6x faster; identical verdicts: yes

ID   Requirement                                 Result              Target        Status
R1   Defective boards caught (escapes = 0)       40/40               all           PASS
R2   Good boards passed (false failures = 0)     160/160             all           PASS
R3   Failing step named correctly                40/40               all           PASS
R4   Noisy-link boards recovered by CRC + retry  20/20, 60 CRC       all, >0 CRC   PASS
R5   Unresponsive board verdict within budget    806 ms              <= 1300 ms    PASS
R6   Speed-up with 8 stations                    4.6x                >= 4.0x       PASS
R7   JSON report + CSV row for every unit        200/200, 200 rows   all           PASS
R8   Test specification valid                    0 problems          0             PASS
8/8 requirements pass
```
<!-- results:end -->

## Run it (macOS)

Needs the Xcode command-line tools (`xcode-select --install`); check with `swift --version`.

```bash
swift build
swift run selftest                                  # self-tests, including a real pseudo-terminal test
swift run hwtest check-spec specs/imu_board_a.json
swift run -c release hwtest bench | tee results.txt # 200 boards, 8 stations, requirement table
python3 tools/readme_results.py                     # copies results.txt into this README
```

Test one simulated board by hand, like an operator at a station:

```bash
swift run hwtest sim --fault stuck_accel            # prints a port such as /dev/ttys012
swift run hwtest run --port /dev/ttys012            # in a second terminal
```

Test a real board: flash `firmware/esp32_imu_board/` with the Arduino IDE (ESP32 core), wire an MPU-6050 to SDA 21 / SCL 22, then:

```bash
swift run hwtest ports                              # find /dev/cu.usbserial-XXXX
swift run hwtest run --port /dev/cu.usbserial-XXXX
```

Firmware protocol tests on any computer:

```bash
cd firmware/host_test && g++ -std=c++17 -Wall -Wextra -o test_protocol test_protocol.cpp && ./test_protocol
```

## Limitations

- The bench uses simulated boards on pseudo-terminals, so it tests the software path, not real electrical faults. The ESP32 firmware lets the same tool run against a real board.
- Serial only; no USB HID, PCIe or network-attached fixtures.
- The noise and range limits in the spec are set for the simulated board; a real MPU-6050 needs limits derived from measured units.
