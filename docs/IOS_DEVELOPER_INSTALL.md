# Установка LLM Dict на iPhone в Developer Mode

Это самый прямой способ установить приложение без App Store и TestFlight. Нужен Mac; Xcode сам создаёт development certificate и provisioning profile.

## Что скачать

1. [Xcode из Mac App Store](https://developer.apple.com/xcode/resources/) — используйте актуальный Xcode 26 или новее.
2. Исходники LLM Dict: **Code → Download ZIP** на GitHub или:

   ```bash
   git clone https://github.com/travinov/LLMDICT.git
   cd LLMDICT
   ```

3. Apple Account. Платная подписка Apple Developer Program для установки на собственный iPhone не обязательна: достаточно войти в Xcode, и будет создана Personal Team. Apple указывает, что её provisioning profile действует 7 дней, после чего приложение нужно собрать и установить повторно: [Developer account overview](https://developer.apple.com/help/account/basics/about-your-developer-account).

XcodeGen нужен только для изменения структуры проекта. Готовый `LLMDictiOS.xcodeproj` уже включён в репозиторий.

## 1. Подготовить Xcode

1. Запустите Xcode и дождитесь установки дополнительных компонентов.
2. Откройте **Xcode → Settings → Accounts**.
3. Нажмите `+`, выберите **Apple Account** и войдите.
4. Откройте проект:

   ```bash
   open apps/ios/LLMDictiOS.xcodeproj
   ```

## 2. Настроить подпись

1. В Project Navigator выберите синий проект **LLMDictiOS**.
2. Выберите target **LLMDictiOS** → **Signing & Capabilities**.
3. Оставьте включённым **Automatically manage signing**.
4. В поле **Team** выберите свою Personal Team или команду Apple Developer.
5. Задайте уникальный **Bundle Identifier**, например `com.yourname.llmdict`. Значение `com.example.LLMDictiOS` предназначено только как шаблон и не будет уникальным для всех пользователей.

## 3. Подключить iPhone

1. Подключите разблокированный iPhone к Mac кабелем с передачей данных.
2. На iPhone нажмите **Доверять этому компьютеру** и введите код-пароль, если появится запрос.
3. В Xcode откройте **Window → Devices and Simulators** и дождитесь окончания pairing/preparation.
4. В верхней панели Xcode вместо симулятора выберите подключённый iPhone.

## 4. Включить Developer Mode

Developer Mode появляется в настройках после начала pairing с Xcode. Если пункта ещё нет, выберите iPhone как Run Destination и один раз нажмите Run.

1. На iPhone откройте **Настройки → Конфиденциальность и безопасность → Режим разработчика**.
2. Включите режим и подтвердите перезагрузку.
3. После перезагрузки разблокируйте iPhone, нажмите **Включить** в системном диалоге и введите код-пароль.

Официальная последовательность Apple: [Enabling Developer Mode on a device](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device).

## 5. Собрать и установить

1. Вернитесь в Xcode и нажмите **Run** (`⌘R`).
2. Xcode соберёт, подпишет, установит и запустит приложение на выбранном iPhone.
3. При первом запуске разрешите доступ к микрофону и Bluetooth.
4. В **Настройки** приложения добавьте ключи только тех провайдеров, которыми планируете пользоваться. Ключи сохраняются в iOS Keychain.

## Проверка после установки

- Запишите 3–5 секунд с микрофона iPhone и остановите запись.
- Убедитесь, что элемент появился в **Истории** и воспроизводится.
- Включите прошитый recorder, откройте экран устройства и проверьте обнаружение `LLM Dict Recorder`.
- Для проверки cloud flow используйте короткую тестовую запись без чувствительных данных.

## Частые проблемы

### Developer Mode не появился

Завершите pairing в **Window → Devices and Simulators**, выберите iPhone как Run Destination и снова нажмите Run. По документации Apple пункт появляется только после начала или предыдущего выполнения pairing.

### `Signing for LLMDictiOS requires a development team`

Выберите target → **Signing & Capabilities** → **Team**. Если команды нет, сначала добавьте Apple Account в Xcode Settings.

### `Bundle identifier is not available`

Замените identifier на уникальный, например `com.githubusername.llmdict`.

### `Untrusted Developer` или приложение не запускается

Убедитесь, что Developer Mode включён, iPhone разблокирован, а текущая сборка установлена из Xcode под вашей командой. Удалите старую сборку с iPhone и снова нажмите Run.

### Приложение перестало открываться через 7 дней

Это ограничение бесплатной Personal Team. Подключите iPhone к Mac и снова выполните Run. Платная Apple Developer Program снимает короткое 7-дневное окно для обычной разработки и нужна для дистрибуции через App Store/TestFlight.

### Ошибка OpenAI 403 о регионе

Это не ошибка WAV или multipart. Доступ должен быть разрешён с сети самого iPhone либо запросы должны идти через совместимый Base URL, доступный в вашей сети. Не публикуйте API-ключ при диагностике.

## Опционально: пересоздать Xcode project

```bash
brew install xcodegen
cd apps/ios
xcodegen generate --spec project.yml
open LLMDictiOS.xcodeproj
```

После генерации снова выберите свою Team и уникальный Bundle Identifier. Не коммитьте личные provisioning profiles и данные `xcuserdata`.
