# LLM Dict Recorder BLE protocol v1

The recorder advertises as `LLM Dict Recorder` and uses Nordic UART Service
(NUS):

- manufacturer data: ASCII `LLMD1` (required product identity);
- service: `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`;
- RX (companion writes): `6E400002-B5A3-F393-E0A9-E50E24DCCA9E`;
- TX (companion subscribes): `6E400003-B5A3-F393-E0A9-E50E24DCCA9E`.

All integer fields are unsigned little-endian values. Commands may arrive in
separate BLE writes; the firmware buffers and parses complete commands.

## Companion commands

| Frame | Size | Meaning |
| --- | ---: | --- |
| `LDI1` | 4 | Request device/recording information. |
| `LDG1` + `offset: UInt32` | 8 | Download the latest WAV, starting at the byte offset. |
| `LDC1` | 4 | Cancel the current transfer. |

An offset equal to the reported WAV size is valid and produces only the
transfer header and end frame. An offset larger than the WAV size is rejected
with a fresh info frame.

## Recorder frames

### Info (`LDI1`, 12 bytes)

| Offset | Type | Meaning |
| ---: | --- | --- |
| 0 | 4 bytes | ASCII `LDI1`. |
| 4 | UInt8 | Protocol version (`1`). |
| 5 | UInt8 | State: `0` idle, `1` recording, `2` busy, `3` fault. |
| 6 | UInt8 | Flags: bit 0 = finalized WAV ready; bit 1 = transferring. |
| 7 | UInt8 | Configured PDM gain. |
| 8 | UInt32 | Finalized WAV size in bytes, or zero. |

### Transfer header (`LDT1`, 12 bytes)

| Offset | Type | Meaning |
| ---: | --- | --- |
| 0 | 4 bytes | ASCII `LDT1`. |
| 4 | UInt32 | Total WAV size. |
| 8 | UInt32 | Starting offset accepted by the recorder. |

The header is followed by exactly `totalSize - offset` raw WAV bytes. The
bytes are ordered NUS notifications and contain no per-chunk envelope.

### Transfer end (`LDE1`, 12 bytes)

| Offset | Type | Meaning |
| ---: | --- | --- |
| 0 | 4 bytes | ASCII `LDE1`. |
| 4 | UInt32 | Total WAV size. |
| 8 | UInt32 | CRC32 of the complete WAV, including bytes before a resume offset. |

CRC32 uses the reflected polynomial `0xEDB88320`, initial value `0xFFFFFFFF`,
and final XOR `0xFFFFFFFF`.

## Companion validation

The companion must reject files larger than the recorder capacity (2 MiB),
truncated streams, a size mismatch, an invalid WAV header, or a CRC mismatch.
Partial files may be retained for a later `LDG1` request at their current byte
count. A new recording invalidates any previous partial file. Firmware v1
accepts such resume offsets; the current iOS MVP intentionally starts every
sync at offset zero and removes an incomplete temporary file after failure.
