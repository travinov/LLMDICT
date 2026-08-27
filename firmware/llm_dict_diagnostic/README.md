# XIAO nRF52840 Sense Plus diagnostic firmware

Hardware covered by this sketch:

- onboard PDM microphone, mono at 16 kHz;
- momentary button wired directly between `D10` and `GND`;
- onboard red LED used as the pressed-state indicator;
- USB CDC Serial at 115200 baud.

The button uses the MCU's internal pull-up. Do not add an external voltage to
`D10`; pressing the button must only connect it to ground.

## Build

```sh
./scripts/firmware.sh build llm_dict_diagnostic
```

The wrapper uses a temporary path because Seeed nRF52 core 1.1.12 does not
quote sketch paths containing spaces correctly. Build artifacts are copied to
`.build/llm_dict_diagnostic`.

## Upload

```sh
./scripts/firmware.sh upload /dev/cu.usbmodem101 llm_dict_diagnostic
```

The runtime serial port can change after reset. Confirm it with:

```sh
arduino-cli board list
```

Expected serial messages:

```text
BOOT:LLM_DICT_DIAGNOSTIC_V1
BOARD:XIAO_NRF52840_SENSE_PLUS
BUTTON:D10_TO_GND,ACTIVE_LOW,INPUT_PULLUP
BUTTON:INITIAL=RELEASED,RAW=HIGH
AUDIO:PDM,MONO,16000_HZ,16_BIT
READY
AUDIO:rms=...,peak=...,dbfs=...,samples=...
BUTTON:STATE=RELEASED,RAW=HIGH
BUTTON:PRESSED
BUTTON:RELEASED
```
