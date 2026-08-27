# Установка toolchain и прошивка LLM Dict Recorder

Инструкция рассчитана на macOS. Основной и проверенный путь — сборка из исходников через Arduino CLI.

## Что скачать и подготовить

- [Arduino CLI](https://docs.arduino.cc/arduino-cli/installation) — сборка и загрузка firmware из Terminal.
- Seeed nRF52 Boards `1.1.12` — устанавливается командой setup ниже.
- USB-C кабель с передачей данных.
- Seeed Studio XIAO nRF52840 **Sense Plus** с кнопкой `D10 ↔ GND`.

Для графического интерфейса можно использовать Arduino IDE и добавить официальный Seeed Board Manager URL, но команды проекта воспроизводимее и однозначнее.

## 1. Установить Arduino CLI

Через Homebrew:

```bash
brew update
brew install arduino-cli
arduino-cli version
```

Или используйте официальный установщик со страницы [Arduino CLI Installation](https://docs.arduino.cc/arduino-cli/installation).

## 2. Установить Seeed board package

Из корня репозитория:

```bash
./scripts/firmware.sh setup
```

Скрипт добавляет официальный индекс
`https://files.seeedstudio.com/arduino/package_seeeduino_boards_index.json`
и устанавливает зафиксированную версию `Seeeduino:nrf52@1.1.12`.

Проверка:

```bash
arduino-cli core list
arduino-cli board details -b Seeeduino:nrf52:xiaonRF52840SensePlus
```

Ожидаемый FQBN: `Seeeduino:nrf52:xiaonRF52840SensePlus`.

## 3. Собрать прошивку

```bash
./scripts/firmware.sh build
```

Готовые `.hex`, `.elf` и `.map` появятся в `.build/llm_dict_recorder/`. Каталог локальный и в Git не добавляется.

Для проверки платы и кнопки до основной прошивки:

```bash
./scripts/firmware.sh build llm_dict_diagnostic
```

## 4. Найти serial port

Подключите плату и выполните:

```bash
arduino-cli board list
```

На macOS порт обычно выглядит как `/dev/cu.usbmodem101`, но номер может отличаться и измениться после reset/DFU.

## 5. Загрузить прошивку

Подставьте свой порт:

```bash
./scripts/firmware.sh upload /dev/cu.usbmodem101
```

Скрипт заново собирает firmware, загружает её и проверяет, что плата вернулась как `Sense Plus`.

Если автоматический переход в bootloader не сработал:

1. Быстро дважды нажмите маленькую кнопку `RST` на плате или дважды кратко замкните соседние `RST` и `GND`.
2. Снова выполните `arduino-cli board list` — DFU-порт может иметь другой номер.
3. Повторите upload с новым портом.

Такую recovery-последовательность рекомендует и [официальная инструкция Seeed](https://wiki.seeedstudio.com/XIAO_BLE/).

## 6. Проверить запуск

```bash
arduino-cli monitor -p /dev/cu.usbmodem101 -c baudrate=115200
```

В начале лога должны появиться сообщения о плате, PDM audio, flash и BLE advertising. Критические ошибки начинаются с `FATAL:` или `ERROR:`.

Проверка сценария:

1. Нажмите кнопку — LED мигает во время очистки flash, затем горит во время записи.
2. Скажите короткую фразу.
3. Нажмите кнопку второй раз и дождитесь `WAV:READY`.
4. Откройте LLM Dict на iPhone и синхронизируйте `LLM Dict Recorder`.

## Резервная выгрузка WAV по USB

Утилита использует только стандартную библиотеку Python 3:

```bash
python3 scripts/retrieve_wav.py /dev/cu.usbmodem101
```

Файл сохраняется в локальный каталог `recordings/`, проверяются RIFF/WAVE header, формат и длина.

## Прошивка готового `.hex` из GitHub Release

Если к релизу приложен файл `llm_dict_recorder-<version>.hex`, его можно загрузить без компиляции после установки Seeed core:

```bash
arduino-cli upload \
  --fqbn Seeeduino:nrf52:xiaonRF52840SensePlus \
  --port /dev/cu.usbmodem101 \
  --input-file llm_dict_recorder-0.1.1.hex
```

Сборка из исходников остаётся рекомендуемым способом: она гарантирует соответствие `.hex` текущему commit.

## Arduino IDE вместо CLI

1. Установите Arduino IDE.
2. В **Settings/Preferences → Additional Boards Manager URLs** добавьте `https://files.seeedstudio.com/arduino/package_seeeduino_boards_index.json`.
3. В Boards Manager установите **Seeed nRF52 Boards 1.1.12**.
4. Откройте `firmware/llm_dict_recorder/llm_dict_recorder.ino`.
5. Выберите **Seeed XIAO nRF52840 Sense Plus** и правильный port.
6. Нажмите Upload.
