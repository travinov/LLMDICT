# План реализации LLMDictiOS

## 1. Цель, границы и статусы

Цель продукта: надёжный transcription-first диктофон для сценария `запись -> Recognize -> Format/Apply template -> история/экспорт`. Production shell содержит только вкладки «Запись», «История», «Настройки». FAQ находится в настройках. Live Translate не имеет пользовательского entry point в production shell.

Статусы:

- `[x]` кодовая часть реализована и подтверждена статическим просмотром;
- `[~]` код реализован частично или реализован полностью, но обязательные тесты/upgrade verification ещё не завершены;
- `[ ]` не реализовано;
- `[!]` блокирует соответствующий release gate.

Сводка текущего этапа:

- `[x]` три production-таба, FAQ в настройках, Live Translate скрыт из shell и настроек;
- `[~]` `CredentialStoring` и `KeychainCredentialStore` реализованы, поля ключей замаскированы, ошибки сохранения показываются без вывода секретов; базовые unit-тесты миграции/write/delete проходят, системные Keychain edge cases ещё не покрыты;
- `[~]` legacy-миграция OpenAI/Sber/GigaChat ключей из `UserDefaults` в Keychain реализована и проверена isolated unit-тестами; upgrade suite поверх реально установленной предыдущей версии не завершён;
- `[~]` `PrivacyInfo.xcprivacy` добавлен, проходит `plutil` и присутствует в simulator `.app`; включение manifest в release archive и App Store privacy review ещё не проверены;
- `[~]` `rawTranscript`, `processedTranscript`, `lastTranscriptionError`, `lastProcessingError` и безопасный persistence retry/restore предыдущего текста реализованы; controller/HTTP fixture tests добавлены, upgrade/restart/store-failure suite не завершён;
- `[~]` Recognize и Format разделены: raw-only STT использует `gpt-4o-transcribe`, `gpt-4o-mini-transcribe` или SaluteSpeech; обработка вынесена в OpenAI Responses API/GigaChat, исходный и оформленный текст экспортируются явно;
- `[x]` legacy OpenAI provider values нормализуются в `gpt-4o-transcribe`, недостижимый post-record WebSocket-прототип удалён из production `TranscriptionService`;
- `[x]` текущий simulator checkpoint: `19/19` unit и `2/2` UI tests прошли на iPhone 17 Pro Max / iOS 26.5; свежий `xcodebuild analyze` прошёл;
- `[x]` `.gitignore` создан, 1754 build/DerivedData path и backup-проект удалены только из Git index; локальные каталоги сохранены;
- `[!]` **Gate A не пройден**: остаются upgrade verification существующего SwiftData store, release archive/privacy validation и smoke на реальном iPhone.

Production-сборка пока выполняет только file STT после остановки записи. True live через `AVAudioEngine` + WebRTC запланирован отдельным engine и не подменяется загрузкой готового WAV через WebSocket.

## 2. Целевая архитектура

Перед расширением модельной матрицы необходимо отделить orchestration от конкретных API и устройств.

### 2.1. Обязательные контракты `[~]`

- `RecordingRepository`: создаёт и обновляет записи, согласует SwiftData metadata с файлами, сохраняет raw/processed/error состояния, выполняет retry и integrity recovery.
- `AudioCaptureSource`: выдаёт поток нормализованных аудиофреймов и независимо финализирует локальный WAV; реализации для микрофона iPhone и companion device.
- `[~]` `TranscriptionEngine`: текущий `TranscriptionServicing` принимает файл и возвращает raw text без post-processing; streaming events и отдельные adapters ещё не реализованы.
- `[~]` `TextProcessingEngine`: текущий `TextProcessingServicing` принимает immutable raw transcript, template и model profile и возвращает processed transcript через Responses API/GigaChat; capability metadata и local engine ещё не реализованы.
- `[~]` `CredentialStore`: `CredentialStoring` реализует app-facing чтение/запись/удаление секретов; переименование возможно только при следующем breaking refactor, без параллельного фасада.
- `DeviceTransport`: низкоуровневое соединение, frames/control messages, backpressure и transport errors для BLE/Wi-Fi/MFi.
- `DeviceConnectionService`: discovery, pairing, capability negotiation, reconnect, battery/firmware state и выбор fallback source.

### 2.2. Границы данных

1. Recognize создаёт только `rawTranscript` и метаданные распознавания.
2. Format/Apply template читает raw transcript и создаёт `processedTranscript`, не перезаписывая raw.
3. Ошибка Recognize хранится отдельно от последнего успешного raw/processed результата.
4. Ошибка Format не переводит успешный raw transcript в состояние «нет транскрипта».
5. Partial transcript является временным revisioned state; только final transcript сохраняется как завершённый raw result.
6. Model ID, capability profile, prompt/template version и processing parameters сохраняются как metadata результата, а не выводятся из hardcoded switch постфактум.

**Acceptance criteria**

- AppController зависит от протоколов, а не создаёт конкретные сетевые/устройственные клиенты внутри feature methods.
- File, live, offline и fake engines проходят один contract test suite.
- Raw transcript остаётся доступным после любого сбоя форматирования.
- Замена транспорта или модели не требует изменения SwiftUI-экранов за пределами model/config mapping.

## 3. P0 - закрытие объединённого security/data пакета

### P0.1. Production shell и навигация `[~]`

1. `[x]` Оставить вкладки «Запись», «История», «Настройки».
2. `[x]` Убрать Live Translate и его API-секции из production UI без удаления feature-кода.
3. `[x]` Перенести FAQ в `Настройки -> Помощь -> FAQ и инструкции`.
4. `[x]` Добавить UI-test на ровно три таба, отсутствие Live Translate labels и открытие FAQ.
5. `[ ]` Сверить App Store/TestFlight screenshots и описание с transcription-first scope.

**Acceptance criteria**

- На clean install и upgrade доступны только три production-таба.
- Ни один deep link, accessibility element или сохранённый tab selection не открывает Live Translate.
- FAQ открывается из настроек на compact iPhone и основном целевом iPhone.

### P0.2. CredentialStore, Keychain и legacy migration `[~] [!]`

1. `[x]` Реализовать `CredentialStoring` и `KeychainCredentialStore` на Security framework.
2. `[x]` Хранить новые секреты с device-only accessibility и не записывать ключи в `UserDefaults`.
3. `[x]` Реализовать миграцию `openai_api_key`, `sber_auth_key`, `gigachat_auth_key`: прочитать legacy, записать Keychain, удалить legacy только после успеха.
4. `[x]` Маскировать ключи через `SecureField`, показывать безопасную ошибку Keychain и подсказку о локальном хранении.
5. `[~]` Добавить fake `CredentialStore` и unit-тесты: migration, empty, add/update/delete и write failure покрыты; duplicate retry, invalid data и системный denied ещё не покрыты.
6. `[ ]` Добавить upgrade-тесты: legacy-only, Keychain-only, оба источника, частичная миграция, повторный launch после ошибки.
7. `[ ]` Проверить, что ключи отсутствуют в defaults dump, логах, crash attachments, archive strings и UI snapshots.

**Acceptance criteria**

- Успешная миграция сохраняет все три ключа и очищает только соответствующие legacy keys.
- Ошибка Keychain не удаляет legacy source и не подменяет введённый ключ пустой строкой.
- Повторный launch идемпотентно завершает или повторяет незавершённую миграцию.
- Standard OpenAI API key не используется клиентом для production WebRTC session; для true live применяется backend broker и ephemeral client secret.

### P0.3. Privacy manifest `[~] [!]`

1. `[x]` Добавить `PrivacyInfo.xcprivacy` с причиной использования `UserDefaults`.
2. `[~]` Manifest подтверждён в simulator `.app`; содержимое release `.xcarchive` ещё требуется проверить.
3. `[ ]` Сверить `PrivacyInfo.xcprivacy`, `Info.plist`, сетевые потоки и App Store privacy answers.
4. `[ ]` Обновить user-facing privacy text: локальные файлы, выбранный cloud provider, Keychain, retention/delete semantics.

**Acceptance criteria**

- `PrivacyInfo.xcprivacy` присутствует в собранном application bundle и проходит privacy validation.
- Декларации не утверждают отсутствие передачи данных, если пользователь выбрал облачное распознавание/обработку.
- Секреты, аудио, raw/processed transcript и prompts не попадают в telemetry без отдельного решения и согласия.

### P0.4. Raw/processed/error и safe persistence retry `[~] [!]`

1. `[x]` Добавить отдельные `rawTranscript`, `processedTranscript`, `lastTranscriptionError`.
2. `[x]` Сохранять предыдущие raw/processed данные при ошибке новой обработки.
3. `[x]` Реализовать safe persistence retry/best-effort сохранение error state после восстановления предыдущего текста.
4. `[~]` Helper unit-тесты transcript/error precedence добавлены; repository-level success/failure/save/retry/restart ещё требуются.
5. `[ ]` Выполнить upgrade verification существующего SwiftData store с записями до появления новых optional fields.
6. `[ ]` Запретить параллельные операции над одной записью и ввести operation ID для защиты от stale completion.

**Acceptance criteria**

- Ошибка повторного распознавания не уничтожает последний успешный raw/processed текст.
- Ошибка форматирования сохраняет raw и записывает отдельную причину ошибки.
- После перезапуска статусы, тексты и error state соответствуют последней подтверждённой транзакции.
- Stale response старой операции не может перезаписать более новый final result.

### P0.5. Repo hygiene `[x]`

`.gitignore` создан. После review списка 1754 build/DerivedData path и два файла backup-проекта удалены только из Git index. Локальные build-кэши и backup-каталог остались на диске:

```bash
git ls-files '.deriveddata-*' '.verification/**'
git rm -r --cached --ignore-unmatch -- \
  .deriveddata-device .deriveddata-ios .deriveddata-sim .verification
git status --short
```

1. `[x]` Добавить правила `.deriveddata-*`, `.verification/`, `DerivedData/`, `build/`, user state и local secrets.
2. `[x]` Просмотреть tracked list и подтвердить, что среди него нет исходников/ручных fixtures.
3. `[x]` Выполнить `git rm --cached`; команда изменила только index.
4. `[x]` Проверить, что локальные каталоги остались на диске, а повторная сборка создаёт только ignored noise.

**Acceptance criteria**

- `git ls-files '.deriveddata*' '.verification/**'` не возвращает build products/caches.
- Clean checkout + build меняет только ignored paths.
- Cleanup commit не содержит удаления исходников, project configuration или тестовых fixtures.

## 4. P1 - transcription pipeline

### P1.1. Разделить Recognize и Format/Apply template `[~]`

Пользовательские действия и orchestration должны быть независимы:

1. `[x]` `Recognize` запускает только STT, пишет `rawTranscript` и никогда не применяет системный template.
2. `[x]` `Format/Apply template` доступен только при наличии raw transcript, вызывает `TextProcessingServicing` и пишет `processedTranscript`.
3. `[~]` Повторный Recognize сохраняет предыдущие результаты при ошибке и очищает processed при успехе; явное подтверждение замены и metadata `stale` ещё не реализованы.
4. `[x]` Повторный Apply не вызывает повторную загрузку аудио.
5. `[x]` История явно показывает raw, processed и тип ошибки; share/copy отдельно выбирают исходный или оформленный текст.

**Acceptance criteria**

- Recognize без template и с выбранным template создаёт одинаковый raw transcript.
- Apply template можно повторить с другим template без STT-запроса.
- Ошибка Responses API не меняет raw и не скрывает последний успешный processed result без явного решения пользователя.

### P1.2. File STT model matrix `[~]`

Ввести конфигурацию `TranscriptionModelProfile`, выбранную настройкой/feature config, а не hardcoded switch в service:

- quality file STT: `gpt-4o-transcribe`;
- budget file STT: `gpt-4o-mini-transcribe`;
- legacy compatibility fallback: `whisper-1`;
- optional post-record diarization: `gpt-4o-transcribe-diarize`;
- существующий Sber SaluteSpeech остаётся отдельным `TranscriptionEngine`.

Этапы:

1. `[~]` Quality/budget/Sber профили доступны через production picker; полноценный capability registry для file/stream/output/prompt/logprob/diarization/limits ещё не реализован.
2. `[~]` Raw-only `TranscriptionServicing` отделён от UI, fixture tests для quality/budget проходят; отдельные adapters и общий contract suite ещё требуются.
3. `[ ]` Выбирать fallback только по конфигурации и классу ошибки; не делать скрытый fallback после auth/permission ошибок.
4. `[ ]` Для `gpt-4o-transcribe-diarize` хранить speaker segments отдельно от plain text и применять требуемую chunk strategy для длинных записей.
5. `[ ]` Сохранять фактически использованный model ID/profile в metadata записи.

**Acceptance criteria**

- Quality, budget, legacy и diarization профили проверяются одним набором fixtures.
- UI не содержит model-specific branching кроме отображения доступных capability-driven опций.
- Fallback отображается пользователю и фиксируется в metadata; стоимость/качество не меняются молча.
- Diarized result можно экспортировать с speaker labels и как plain text.

Официальная справка по поддерживаемым file STT моделям и форматам: [Speech to text](https://developers.openai.com/api/docs/guides/speech-to-text#transcriptions).

### P1.3. Large audio и bounded memory `[ ]`

1. `[ ]` Удалить любые предположения о фиксированном 44-byte WAV header и ручной `dropFirst(44)` parsing.
2. `[ ]` Читать/конвертировать контейнеры через `AVAudioFile` или `AVAssetReader` с проверкой фактического format description.
3. `[ ]` Для небольших файлов использовать streaming multipart upload из файла/stream, не загружая весь audio в `Data`.
4. `[ ]` Для превышения API/policy threshold делить по duration/size с bounded overlap, sequence IDs и deterministic merge.
5. `[ ]` Для diarization использовать capability-specific server chunk policy; не применять общий prompt/timestamp policy к несовместимой модели.
6. `[ ]` Ввести bounded queue, cancellation, progress, temporary-file cleanup и retry только незавершённого chunk.
7. `[ ]` Зафиксировать thresholds и merge policy в конфигурации с тестами boundary values.

**Acceptance criteria**

- 60+ минут audio обрабатываются в согласованном memory budget без полного файла в RAM.
- WAV с дополнительными chunks, CAF/M4A/imported formats читаются через системные readers, а не header offsets.
- Chunk retry не дублирует текст и не меняет порядок сегментов.
- Cancellation закрывает readers/uploads и удаляет только принадлежащие операции временные файлы.

### P1.4. True live `gpt-realtime-whisper` `[ ]`

Текущий post-record WebSocket путь остаётся отдельным engine до миграции. True live строится как новый режим:

1. `[ ]` `AVAudioEngine` tap выдаёт нормализованные frames в `AudioCaptureSource`.
2. `[ ]` Те же frames одновременно пишутся в локальный WAV через отдельный writer; сетевой сбой не останавливает локальную запись.
3. `[ ]` iOS-клиент подключается к Realtime API по WebRTC.
4. `[ ]` Backend token broker хранит standard API key, аутентифицирует пользователя/устройство, применяет rate limits и выдаёт short-lived ephemeral client secret или создаёт unified WebRTC session.
5. `[ ]` Standard API key никогда не передаётся в mobile client для production true live.
6. `[ ]` Data channel events преобразуются в typed partial/final events `TranscriptionEngine`.
7. `[ ]` Session reconnect не создаёт второй writer и не теряет связь с локальным recording ID.

Partial/final state machine:

`idle -> connecting -> capturing -> partial(revision N) -> finalizing -> final`

Допустимые ответвления: `offlineQueued`, `failed(recoverable/nonRecoverable)`, `cancelled`. Partial revisions монотонны и не сохраняются как final. Финализация локального WAV и final transcript являются отдельными подтверждаемыми операциями.

**Acceptance criteria**

- Partial текст обновляется без перезаписи подтверждённого final старой ревизией.
- Потеря сети сохраняет локальный WAV и переводит задачу в post-record/offline fallback.
- Истечение ephemeral secret обрабатывается повторной авторизованной выдачей, а не standard key в приложении.
- Background/interruption/route change не оставляют capture/session в ложном активном состоянии.
- True live и post-record engines различимы в UI и metadata.

Официальная схема клиентского WebRTC и ephemeral/unified server flow: [Realtime API with WebRTC](https://developers.openai.com/api/docs/guides/realtime-webrtc).

### P1.5. Offline/local fallback `[ ]`

1. `[ ]` Провести decision gate между Apple Speech/on-device возможностями и bundled local STT (например, Core ML), включая язык, размер модели, latency, privacy и лицензирование.
2. `[ ]` Реализовать выбранный вариант как `TranscriptionEngine`, а не отдельный UI-flow.
3. `[ ]` При отсутствии сети всегда сохранять WAV и предлагать local recognition или очередь post-record cloud STT.
4. `[ ]` Маркировать происхождение результата `local/cloud`, model/version и confidence metadata, если доступно.
5. `[ ]` Не заменять более качественный cloud final локальным fallback без явного правила пользователя.

**Acceptance criteria**

- Airplane mode не блокирует запись, историю и экспорт локального WAV.
- Поддерживаемый local engine создаёт raw transcript без cloud credential.
- Неподдерживаемый язык даёт понятный fallback choice, а не silent failure.

### P1.6. Format/Apply template через Responses API `[~]`

1. `[x]` Реализовать `TextProcessingServicing` поверх Responses API и отдельный GigaChat adapter path.
2. `[~]` Processing model выбирается через `ProcessingModelProfile` (Luna/Terra); capability registry для structured output/reasoning/context/availability/cost ещё не реализован.
3. `[~]` Model ID вынесен из feature/service в профиль, но versioned remote/app config и capability fallback ещё не реализованы.
4. `[ ]` Перед запросом оценивать размер raw transcript и применять documented chunk/map-reduce policy при превышении context budget.
5. `[ ]` Версионировать template и prompt builder в коде; сохранять version/model metadata результата.
6. `[ ]` Добавить eval fixtures для каждого системного template и schema validation для structured output, где это требуется.

**Acceptance criteria**

- Замена processing model выполняется конфигурацией после capability check, без изменения feature flow.
- Responses output разбирается по типам; код не предполагает, что текст всегда находится в первом output item.
- Один raw transcript можно форматировать несколькими templates с воспроизводимым metadata trail.
- Ошибка context/model capability выявляется до destructive update записи.

Официальный API-путь для text processing: [Text generation with Responses API](https://developers.openai.com/api/docs/guides/text).

## 5. P2 - companion device и пользовательское качество

### P2.1. Transport decision gate BLE/Wi-Fi/MFi `[ ]`

До implementation выбрать транспорт по измерениям, а не по удобству прототипа:

1. `[ ]` Зафиксировать required bitrate, latency, range, background behavior, pairing UX, power budget и accessory certification constraints.
2. `[ ]` Прототипировать BLE и Wi-Fi на целевом hardware; MFi рассматривать при требованиях проводного/сертифицированного accessory path.
3. `[ ]` Принять ADR с выбранным primary transport, fallback transport и причинами отказа от альтернатив.
4. `[ ]` Зафиксировать feature flag: companion device не блокирует базовый релиз, пока gate не пройден.

**Acceptance criteria**

- ADR содержит измеренные throughput/latency/drop rates и background ограничения.
- Выбранный транспорт выдерживает целевой audio/control workload с запасом.
- Не выбранный транспорт не просачивается в domain API.

### P2.2. Device protocol и connection lifecycle `[ ]`

1. `[ ]` Реализовать `DeviceTransport` и `DeviceConnectionService` с fake transport.
2. `[ ]` Ввести handshake: `protocolVersion`, device ID, audio codecs/sample rates/channels, frame duration, control capabilities, battery, firmware.
3. `[ ]` Версионировать frames/control messages; неизвестная major version отклоняется безопасно, minor capability согласуется.
4. `[ ]` Реализовать reconnect state machine, sequence numbers, timestamps, acknowledgements и bounded backpressure queue.
5. `[ ]` Определить drop policy: control messages не теряются; audio gaps обнаруживаются и маркируются; memory не растёт без границ.
6. `[ ]` Добавить battery/charging/firmware state и minimum supported firmware policy.
7. `[ ]` При disconnect автоматически продолжать/предлагать запись с микрофона iPhone без потери уже записанного local audio.

**Acceptance criteria**

- Fake transport воспроизводит reorder, duplicate, drop, timeout, reconnect и backpressure.
- Несовместимая protocol/firmware version не приводит к crash или повреждённой записи.
- Fallback на iPhone mic явно отражается в metadata и UI.
- Reconnect не создаёт две активные capture sessions.

### P2.3. Device status UI `[ ]`

1. `[ ]` Показывать source: iPhone mic/companion, connection state, battery, firmware warning и текущий fallback.
2. `[ ]` Дать явные действия connect/disconnect/retry/use iPhone mic.
3. `[ ]` Не блокировать вкладку «Запись» отсутствующим companion device.
4. `[ ]` Добавить accessibility labels и диагностический экран без секретов/аудиоконтента.

**Acceptance criteria**

- Пользователь понимает, какой микрофон сейчас записывает.
- Потеря устройства имеет одно явное recovery action и безопасный automatic fallback.
- UI проходит Dynamic Type/VoiceOver на connection/error states.

### P2.4. Accessibility, history и export `[ ]`

1. `[ ]` Проверить Dynamic Type до accessibility XXXL, VoiceOver, Reduce Motion, Increase Contrast, Bold Text и light/dark.
2. `[ ]` Добавить поиск/сортировку истории и явные empty/loading/error/partial/final states.
3. `[ ]` Экспортировать WAV, raw text, processed text и diarized text с предсказуемыми UTF-8 именами.
4. `[ ]` Подтверждать destructive delete и показывать partial file/metadata failure.
5. `[ ]` Защитить несохранённые изменения templates и определить limits.

**Acceptance criteria**

- Полный базовый сценарий выполняется с VoiceOver.
- Экспорт сохраняет кириллицу, speaker labels и выбранную версию текста.
- 1000 записей не приводят к неприемлемому startup/scroll latency.

## 6. P3 - эксплуатация и выпуск

### P3.1. Наблюдаемость без чувствительных данных `[ ]`

1. `[ ]` Ввести структурированные категории recording/storage/recognize/format/device.
2. `[ ]` Логировать operation ID, duration, bytes, provider/model profile, latency и error class.
3. `[ ]` Не логировать keys/tokens, audio, raw/processed transcript, prompts, SDP и backend broker responses.
4. `[ ]` Добавить redacted diagnostic export и SLO: crash-free, recording-save success, recognition success, format success, device reconnect success.

**Acceptance criteria**

- Один redacted report локализует этап отказа без пользовательского контента.
- Secret/log scan не находит credentials, transcripts или ephemeral secrets.

### P3.2. CI, configuration и staged rollout `[ ]`

1. `[ ]` Добавить clean XcodeGen generation, build, unit, integration, UI-smoke и archive validation в CI на закреплённом Xcode.
2. `[ ]` Разделить Debug/Beta/Release endpoints и feature flags; запретить production secrets в source/build settings.
3. `[ ]` Проверять privacy manifest, entitlements, archive content и tracked-artifact hygiene.
4. `[ ]` Добавить model/template eval gate перед сменой `ProcessingModelProfile`.
5. `[ ]` Выпускать internal TestFlight -> ограниченная external group -> staged rollout с 24/72-hour review.

**Acceptance criteria**

- Release candidate воспроизводимо собирается из clean checkout после `xcodegen`.
- Один и тот же archive проходит все gates и не пересобирается между группами.
- Model/config rollout можно остановить независимо от binary rollout.

## 7. Зависимости и порядок выполнения

1. Закрыть P0 tests, upgrade verification, privacy bundle validation и repo hygiene.
2. Ввести `RecordingRepository`, `AudioCaptureSource`, `TranscriptionEngine`, `TextProcessingEngine`, `CredentialStore` facade.
3. Разделить Recognize и Format/Apply template в domain state и UI.
4. Реализовать file STT profiles и large-audio policy.
5. Реализовать Responses API processing с capability/config registry и evals.
6. Реализовать true live capture + simultaneous WAV, затем WebRTC и backend token broker.
7. Добавить offline/local engine и network-loss handoff.
8. Провести companion transport decision gate; только после ADR реализовывать device protocols/UI.
9. Завершить P2 quality и P3 operations/release automation.

Критические зависимости:

- backend service/auth/rate limiting для WebRTC session или ephemeral client secret;
- тестовые OpenAI/Sber проекты без production data;
- поддерживаемые Xcode/iOS SDK и реальные iPhone;
- выбранный local STT runtime/model и лицензирование;
- companion hardware/firmware owner и protocol versioning process;
- App Store privacy answers и privacy policy.

## 8. Migration и rollback

### 8.1. Credentials

1. Legacy migration уже реализована, но должна быть подтверждена upgrade suite на предыдущей установленной версии.
2. Legacy value удаляется только после успешной записи Keychain; при ошибке остаётся source для retry.
3. Rollback binary не должен создавать две writable credential copies. Предыдущая версия допускается только после проверки её поведения с очищенными legacy keys.
4. Backend broker rollout независим: true live feature flag остаётся off до проверки ephemeral/unified session path.

### 8.2. SwiftData и transcripts

1. Перед schema change создать fixture store предыдущей версии и backup каталога `Recordings`.
2. Проверить optional migration полей raw/processed/error и последующее versioned schema изменение.
3. Старый `transcriptPreview` читать как compatibility fallback, но новые записи писать в raw/processed/error.
4. При разделении Recognize/Format сохранить существующий текст: классифицировать по provider/prompt metadata, а при неоднозначности не уничтожать preview и пометить `legacyUnknown`.
5. Rollback на несовместимую SwiftData schema запрещён; использовать forward-fix или заранее проверенную совместимую build.

### 8.3. Model/config rollback

1. Model IDs и capabilities версионируются в config; unknown/disabled model не приводит к silent replacement.
2. Откат processing profile не удаляет результаты новой модели.
3. Prompt/template version хранится с processed result; rollback создаёт новую версию, а не переписывает старую.

### 8.4. Companion rollback

1. Companion feature закрыт feature flag до прохождения transport/device gates.
2. При rollback протокола приложение сохраняет fallback на iPhone mic.
3. Minimum firmware change выпускается staged и не блокирует локальную запись.

Критерии немедленной остановки rollout: потеря/повреждение WAV, потеря keys после upgrade, raw/processed overwrite, crash loop, standard API key на клиенте true live, отправка невыбранному provider, утечка secret/content в лог, неконтролируемый рост memory/queue.

## 9. Test matrix

| Область | Конфигурации | Сценарии | Тип проверки | Gate |
| --- | --- | --- | --- | --- |
| Production shell | compact iPhone, target iPhone | 3 tabs, FAQ, Live absent | UI | A |
| Credentials | clean, legacy-only, Keychain-only, both, Keychain failure | add/update/delete, migration, retry, relaunch | Unit + upgrade + device | A |
| Privacy | Debug/Release app, archive | manifest present, declared APIs, no secret strings | Build validation + review | A |
| Persistence | previous/current store | raw/processed/error, save failure, retry, restart, stale operation | Repository integration | A |
| Repo hygiene | clean checkout/build | no tracked DerivedData, ignored outputs only | CI script | A |
| Recognize actions | no template/selected template | raw identical, no Format side effect | Unit + UI | B |
| File STT | quality/budget/legacy/diarize/Sber | success, auth, 429, 5xx, malformed, cancel, fallback | Fixture integration | B |
| Large audio | WAV chunks, CAF/M4A, mono/stereo, 60+ min | reader, multipart stream, chunk retry/merge, memory | Integration + performance | B |
| Format | profiles/templates/context boundaries | Responses parsing, capability mismatch, eval, retry | Fixture + eval | B |
| True live | Wi-Fi/cellular/loss/reconnect | AVAudioEngine, simultaneous WAV, partial/final, cancel | Integration + device | C |
| Broker | authenticated/expired/rate-limited user | ephemeral/unified session, no standard key on client | Backend integration + security | C |
| Offline | airplane mode, unsupported language | local engine, queue, cloud handoff, WAV preservation | Integration + device | C |
| Audio session | permission states, call/Siri, route/Bluetooth | start/stop/interruption/recovery | Device | C |
| Device transport | fake BLE/Wi-Fi/MFi adapter | drop/reorder/duplicate/backpressure/reconnect | Contract + fake transport | Companion |
| Device compatibility | protocol/firmware/battery matrix | handshake, reject/compat, fallback iPhone mic | Integration + hardware | Companion |
| Accessibility | Dynamic Type, VoiceOver, contrast, themes | record/recognize/format/export/device state | UI + manual | D |
| Release | clean checkout, Debug/Beta/Release | xcodegen, build, archive, install, smoke | CI + device | D |

Минимум устройств: compact iPhone на минимальной поддерживаемой iOS, основной целевой iPhone на актуальной iOS, отдельное устройство/версия для upgrade, companion hardware revisions после выбора транспорта.

## 10. Release gates

### Gate A - P0 security/data baseline `[OPEN]`

- CredentialStore и migration unit tests проходят.
- Upgrade предыдущей установленной версии сохраняет три keys, history, prompts, WAV и transcripts.
- Privacy manifest находится в `.app`/`.xcarchive` и согласован с App Store privacy answers.
- Raw/processed/error и safe persistence retry проходят failure/restart tests.
- Production shell UI-smoke проходит.
- Tracked DerivedData удалены из Git index отдельным reviewed cleanup.

**Gate A не считается завершённым только на основании наличия кода.**

### Gate B - Recognize/Format feature complete `[OPEN]`

- Recognize и Format/Apply template разделены.
- File STT quality/budget/legacy/diarize profiles и large-audio policy проходят contract/integration tests.
- Responses API processing использует capability/config registry и eval gate.
- Нет known defect с потерей raw/processed результата или неконтролируемым fallback.

### Gate C - live/offline readiness `[OPEN]`

- True live использует `AVAudioEngine`, simultaneous local WAV, WebRTC и backend-issued ephemeral/unified session.
- Partial/final state machine, reconnect, cancellation и network loss проверены на устройстве.
- Offline/local fallback и post-record queue сохраняют запись.
- Standard API key отсутствует в mobile true-live path.

### Companion gate - optional feature `[OPEN]`

- Transport ADR утверждён на измерениях.
- Protocol/version/capability negotiation и fake transport tests проходят.
- Reconnect/backpressure/battery/firmware UI проверены.
- Fallback на iPhone mic обязателен.
- Если gate не пройден, companion feature остаётся выключенным и не блокирует базовый релиз.

### Gate D - release candidate и staged rollout `[OPEN]`

- P2 accessibility/history/export проверки завершены.
- Clean XcodeGen build/archive проходит в CI и устанавливается на устройство.
- Observability redacted, SLO/alerts и rollback owner определены.
- Internal TestFlight выдержал согласованное окно без P0/P1 regressions.
- Расширение группы разрешено только после review метрик 24/72 часа.

До прохождения Gate A сборка не готова к внешнему TestFlight. Выполнение будущих этапов в этом документе не подразумевается: завершёнными считаются только явно отмеченные кодовые части, а все verification-зависимости остаются открытыми.
