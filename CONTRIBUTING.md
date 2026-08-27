# Contribution guide

Спасибо за интерес к LLM Dict. Перед изменениями создайте Issue с коротким описанием пользовательского сценария и затронутого уровня: firmware, BLE protocol, iOS или документация.

## Правила

- Не добавляйте API-ключи, provisioning profiles, реальные записи и локальные build artifacts.
- Изменения BLE protocol должны синхронно обновлять firmware, iOS parser, tests и `docs/BLE_PROTOCOL.md`.
- Изменения Xcode target structure вносите в `apps/ios/project.yml`, затем пересоздавайте `.xcodeproj` через XcodeGen.
- Firmware должна собираться для точного FQBN `Seeeduino:nrf52:xiaonRF52840SensePlus` на core `1.1.12`.
- Новое аппаратное поведение сначала проверяйте диагностическим sketch, затем основной прошивкой и реальным BLE transfer.

## Минимальная проверка pull request

```bash
./scripts/firmware.sh setup
./scripts/firmware.sh build

cd apps/ios
xcodegen generate --spec project.yml
xcodebuild -project LLMDictiOS.xcodeproj -scheme LLMDictiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' test
```

В PR разделяйте evidence: source/unit tests, simulator build, physical iPhone, physical recorder и cloud API — это разные уровни проверки.
