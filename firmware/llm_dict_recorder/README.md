# LLM Dict Recorder firmware

Target: Seeed Studio XIAO nRF52840 Sense Plus.

- onboard PDM microphone: mono, 16 kHz, signed 16-bit PCM;
- PDM gain: `70`;
- momentary button: `D10` to `GND`, active low with `INPUT_PULLUP`;
- onboard P25Q16H QSPI flash: one finalized WAV, up to 60 seconds;
- USB Serial commands: `I` for status, `G` for binary WAV download;
- BLE companion transport: Nordic UART Service, advertised as
  `LLM Dict Recorder`.
The first press erases the previous recording and starts a new one after the
erase completes. The LED blinks while erasing and stays on while recording.
The second press stops recording, drains the audio ring, and finalizes the WAV
header. Do not disconnect power until `WAV:READY` appears.

Build and upload:

```sh
./scripts/firmware.sh build
./scripts/firmware.sh upload /dev/cu.usbmodem101
```

The upload wrapper verifies that the board returns as `Sense Plus`. If DFU
cannot enter automatically, rapidly press the tiny `RST` button twice (or
briefly short `RST` to its adjacent `GND` twice), then retry the upload.

Retrieve the latest finalized recording:

```sh
./scripts/retrieve_wav.py /dev/cu.usbmodem101
```

The BLE transport exposes the same finalized WAV to the iOS companion and
supports restarting a transfer at a byte offset. Its binary framing is
documented in [`docs/BLE_PROTOCOL.md`](../../docs/BLE_PROTOCOL.md).

The previous diagnostic firmware remains available:

```sh
./scripts/firmware.sh build llm_dict_diagnostic
./scripts/firmware.sh upload /dev/cu.usbmodem101 llm_dict_diagnostic
```

This prototype stores a single short recording. Longer autonomous recording
needs a larger flash or microSD. A reset or power loss before the stop press
leaves an intentionally unfinalized WAV that is not offered for download.
