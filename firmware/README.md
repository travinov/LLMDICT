# Firmware

| Sketch | Назначение |
| --- | --- |
| [`llm_dict_recorder`](llm_dict_recorder) | Основная запись во flash, USB download и BLE companion transport |
| [`llm_dict_diagnostic`](llm_dict_diagnostic) | Проверка кнопки, PDM-микрофона и Serial до основной прошивки |
| [`llm_dict_flash_probe`](llm_dict_flash_probe) | Низкоуровневая диагностика QSPI flash |

Целевая плата: **Seeed Studio XIAO nRF52840 Sense Plus**, FQBN `Seeeduino:nrf52:xiaonRF52840SensePlus`, Seeed nRF52 core `1.1.12`.

Полная инструкция: [../docs/FIRMWARE_FLASHING.md](../docs/FIRMWARE_FLASHING.md).
