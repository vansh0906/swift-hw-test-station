#!/usr/bin/env python3
"""Independent CRC-8 (poly 0x07, init 0x00) reference used to generate the test vectors in the Swift tests
and the firmware host test. Run: python3 tools/crc8_vectors.py"""


def crc8(data: bytes) -> int:
    crc = 0
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = ((crc << 1) ^ 0x07) & 0xFF if crc & 0x80 else (crc << 1) & 0xFF
    return crc


def frame(seq: int, payload: str) -> str:
    body = f"{seq}:{payload}"
    return f"{body}*{crc8(body.encode()):02X}"


if __name__ == "__main__":
    assert crc8(b"123456789") == 0xF4, "CRC-8/SMBUS check value"
    for seq, payload in [(1, "ID?"), (7, "READ ACC"), (12, "ST PASS,0x00"), (3, "ID IMU-BOARD-A,1.2.0,SN00042")]:
        print(frame(seq, payload))
