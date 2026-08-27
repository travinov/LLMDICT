# Verification snapshot — 27 августа 2026

Этот файл фиксирует проверку именно содержимого, подготовленного для GitHub, а не только исходных рабочих папок.

## Source/package integrity

- iOS project заново сгенерирован из `apps/ios/project.yml` через XcodeGen 2.45.4.
- Сгенерированный `.xcodeproj` содержит актуальные app, unit-test и UI-test targets, Privacy Manifest и Launch Screen.
- Личные `DEVELOPMENT_TEAM`, provisioning profiles, DerivedData, записи и локальные `.env` не входят в snapshot.
- Локальные Markdown-ссылки проверены: отсутствующих целей нет.
- Secret-pattern scan не обнаружил bearer/GitHub/OpenAI/AWS ключей. Пустой legacy `OPENAI_API_KEY=` оставлен как конфигурационный placeholder Android-прототипа.

## iOS

Среда: Xcode 26.6, iOS 26.5 Simulator, iPhone 17 Pro.

| Проверка | Результат |
| --- | --- |
| XcodeGen generation | passed |
| Unit tests | **43 passed, 0 failed, 0 skipped** |
| `xcodebuild analyze` | passed |

Во время повторного clean run был найден и исправлен дефект выбора enhanced-audio sidecar для импортированного файла: sidecar теперь остаётся рядом с существующим source URL, а stale sandbox path по-прежнему rebased в Application Support. После исправления весь набор снова прошёл.

Не выполнены в рамках этого packaging run: реальная подпись под чужой Personal Team, установка на физический iPhone, запросы к production API и release archive.

## Firmware

Цель: `Seeeduino:nrf52:xiaonRF52840SensePlus`, Seeed nRF52 core 1.1.12, Arduino CLI 1.3.1.

| Sketch | Flash | RAM | Результат |
| --- | ---: | ---: | --- |
| `llm_dict_recorder` | 144 676 B / 811 008 B (17%) | 23 372 B / 237 568 B (9%) | passed |
| `llm_dict_diagnostic` | 49 856 B / 811 008 B (6%) | 7 760 B / 237 568 B (3%) | passed |

В этом packaging run плата не перепрошивалась: результат выше подтверждает toolchain/source build, но не является новым физическим board test. Прошивка основана на ранее проверенной hardware-ветке; функциональные изменения при упаковке ограничены именованием sketch/boot banner и setup wrapper.

## Уровни доказательства

| Уровень | Статус |
| --- | --- |
| Source inventory / secret hygiene | подтверждено |
| Firmware compile | подтверждено |
| iOS unit tests / analyzer | подтверждено |
| GitHub Actions firmware build | подтверждено на чистом Ubuntu runner: [run 33086720389](https://github.com/travinov/LLMDICT/actions/runs/33086720389) |
| Физический recorder после этого snapshot | не повторялся |
| Физический iPhone после этого snapshot | не повторялся |
| Production cloud APIs | не повторялись |
