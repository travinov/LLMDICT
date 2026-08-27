import SwiftUI

struct GuideScreen: View {
    var body: some View {
        ZStack {
            AppBackdrop().ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    heroCard
                    quickStartCard
                    faqCard
                }
                .padding(20)
            }
            .floatingTabBarClearance()
        }
        .navigationTitle("Инструкции")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    private var heroCard: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text("FAQ и быстрый старт")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)

                Text("Здесь собраны ответы по токенам, VPN, промптам и типовым проблемам с транскрибацией.")
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.white.opacity(0.78))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var quickStartCard: some View {
        guideCard(title: "Быстрый старт", icon: "wand.and.stars") {
            quickStartStep("1", "Откройте настройки и вставьте `Authorization Key (Base64)` для SaluteSpeech.")
            quickStartStep("2", "Если нужен постпроцессинг текста, добавьте ключ OpenAI или GigaChat.")
            quickStartStep("3", "В поле промпта используйте блоки `{system}` и `{user}`.")
            quickStartStep("4", "Для OpenAI из России обычно нужен VPN или совместимый прокси.")
        }
    }

    private var faqCard: some View {
        guideCard(title: "FAQ", icon: "questionmark.circle") {
            VStack(spacing: 12) {
                ForEach(GuideTopic.faqTopics) { topic in
                    NavigationLink {
                        GuideTopicDetailScreen(topic: topic)
                    } label: {
                        faqQuestionCard(topic)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func guideCard<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        GlassPanel(cornerRadius: 24) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color(red: 0.99, green: 0.79, blue: 0.57))
                        .frame(width: 34, height: 34)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Text(title)
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white)
                }

                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func quickStartStep(_ badge: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(badge)
                .font(.system(.footnote, design: .rounded, weight: .bold))
                .foregroundStyle(Color(red: 0.99, green: 0.79, blue: 0.57))
                .frame(width: 26, height: 26)
                .background(.white.opacity(0.08), in: Circle())

            Text(text)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.white.opacity(0.82))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func faqQuestionCard(_ topic: GuideTopic) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(topic.accent.opacity(0.24))
                    .frame(width: 42, height: 42)

                Image(systemName: topic.icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(topic.title)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(topic.summary)
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [
                    .white.opacity(0.12),
                    topic.accent.opacity(0.2)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct GuideTopicDetailScreen: View {
    @Environment(\.openURL) private var openURL

    let topic: GuideTopic

    var body: some View {
        ZStack {
            AppBackdrop().ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    heroCard

                    if topic.steps.isEmpty == false {
                        detailCard(title: "Что делать", icon: "list.number") {
                            VStack(spacing: 12) {
                                ForEach(Array(topic.steps.enumerated()), id: \.offset) { index, step in
                                    detailStep(index + 1, step)
                                }
                            }
                        }
                    }

                    if let codeSample = topic.codeSample {
                        detailCard(title: "Пример", icon: "curlybraces") {
                            Text(codeSample)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.92))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                    }

                    if let noteTitle = topic.noteTitle, let noteText = topic.noteText {
                        detailCard(title: noteTitle, icon: "exclamationmark.triangle") {
                            Text(noteText)
                                .font(.system(.subheadline, design: .rounded))
                                .foregroundStyle(.white.opacity(0.8))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                    }

                    if topic.facts.isEmpty == false {
                        detailCard(title: "Кратко", icon: "sparkles.rectangle.stack") {
                            VStack(spacing: 12) {
                                ForEach(topic.facts, id: \.self) { fact in
                                    factRow(fact)
                                }
                            }
                        }
                    }

                    if let linkTitle = topic.linkTitle, let linkURL = topic.linkURL {
                        Button {
                            guard let url = URL(string: linkURL) else { return }
                            openURL(url)
                        } label: {
                            Label(linkTitle, systemImage: "arrow.up.right")
                                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(topic.accent.opacity(0.24), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
            .floatingTabBarClearance()
        }
        .navigationTitle("FAQ")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    private var heroCard: some View {
        GlassPanel(cornerRadius: 28) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(topic.accent.opacity(0.24))
                            .frame(width: 48, height: 48)

                        Image(systemName: topic.icon)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Вопрос")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .tracking(2.2)
                            .foregroundStyle(.white.opacity(0.58))

                        Text(topic.title)
                            .font(.system(.title3, design: .rounded, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }

                Text(topic.summary)
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func detailCard<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        GlassPanel(cornerRadius: 24) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(topic.accent)
                        .frame(width: 32, height: 32)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Text(title)
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white)
                }

                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func detailStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(.footnote, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(topic.accent.opacity(0.24), in: Circle())

            Text(text)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.white.opacity(0.82))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func factRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(topic.accent)
                .padding(.top, 5)

            Text(text)
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(.white.opacity(0.74))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct GuideTopic: Identifiable {
    let id: String
    let title: String
    let summary: String
    let icon: String
    let accent: Color
    let steps: [String]
    let facts: [String]
    let noteTitle: String?
    let noteText: String?
    let codeSample: String?
    let linkTitle: String?
    let linkURL: String?

    static let faqTopics: [GuideTopic] = [
        GuideTopic(
            id: "sber-tokens",
            title: "Как получить токены на developers.sber.ru?",
            summary: "Для Sber в приложении нужен не access token, а именно Authorization Key в формате Base64.",
            icon: "key.horizontal.fill",
            accent: Color(red: 0.99, green: 0.73, blue: 0.38),
            steps: [
                "Откройте developers.sber.ru и создайте проект для нужного API.",
                "Для расшифровки нужен проект SaluteSpeech API. Для обработки текста нужен GigaChat API.",
                "В кабинете проекта сгенерируйте Authorization Key.",
                "Скопируйте строку как есть и вставьте её в поле с пометкой Authorization Key (Base64)."
            ],
            facts: [
                "Не вставляйте access_token из ответа OAuth.",
                "Не добавляйте префиксы Basic или Bearer.",
                "Если используете только транскрибацию, достаточно ключа SaluteSpeech."
            ],
            noteTitle: "Что чаще всего ломает авторизацию",
            noteText: "Ошибка `credentials doesn't match db data` обычно означает, что ключ относится не к тому API или вместо Authorization Key был вставлен временный access token.",
            codeSample: nil,
            linkTitle: "Открыть products на developers.sber.ru",
            linkURL: "https://developers.sber.ru/portal/products"
        ),
        GuideTopic(
            id: "prompts",
            title: "Как настроить промпты и какой синтаксис использовать?",
            summary: "Промпт можно разбивать на системную роль и пользовательскую команду, чтобы модель стабильно форматировала текст.",
            icon: "text.bubble.fill",
            accent: Color(red: 0.47, green: 0.78, blue: 0.98),
            steps: [
                "В блоке {system} задайте постоянную роль модели и правила редактирования.",
                "В блоке {user} опишите, что нужно сделать с расшифровкой.",
                "Пишите короткие, однозначные инструкции без противоречий.",
                "Если нужен строгий формат результата, опишите его прямо в {user}."
            ],
            facts: [
                "Текст расшифровки подставляется приложением после вашей инструкции.",
                "Слишком длинные промпты обычно не улучшают результат, а делают его менее предсказуемым.",
                "Один и тот же синтаксис подходит и для OpenAI, и для GigaChat."
            ],
            noteTitle: "Практика",
            noteText: "Лучше всего работают промпты, где отдельно описана роль модели и отдельно описан ожидаемый результат: абзацы, исправление пунктуации, заголовки, краткое резюме и так далее.",
            codeSample: """
{system} Ты редактор русской речи. Исправь пунктуацию и убери слова-паразиты.
{user} Обработай расшифровку, разбей на абзацы и сохрани смысл без сокращений.
""",
            linkTitle: nil,
            linkURL: nil
        ),
        GuideTopic(
            id: "openai-vpn",
            title: "Почему OpenAI не работает без VPN?",
            summary: "Из России прямой доступ к OpenAI API часто недоступен, поэтому запросы могут падать по сети ещё до обработки ключа.",
            icon: "network.badge.shield.half.filled",
            accent: Color(red: 0.58, green: 0.88, blue: 0.66),
            steps: [
                "Убедитесь, что у вас есть рабочий OpenAI API key.",
                "Проверьте, что Base URL указывает на OpenAI API или на ваш совместимый прокси.",
                "Если вы находитесь в России, включите VPN или используйте доступный прокси-шлюз.",
                "После этого повторите запрос на обработку."
            ],
            facts: [
                "Типовые симптомы: network error, timeout, 403, пустой ответ.",
                "Сам ключ может быть корректным, но сеть до OpenAI может не доходить.",
                "Если используете свой proxy Base URL, VPN может быть не нужен."
            ],
            noteTitle: "Важно",
            noteText: "Проблема в этом случае не в промпте и не в модели, а в сетевой доступности API из вашей текущей страны или провайдера.",
            codeSample: nil,
            linkTitle: "Открыть OpenAI API Keys",
            linkURL: "https://platform.openai.com/api-keys"
        ),
        GuideTopic(
            id: "live-translate",
            title: "Как работает Live Translate?",
            summary: "Это режим переводчика для разговора с незнакомым человеком, когда телефон остаётся у владельца.",
            icon: "translate",
            accent: Color(red: 0.36, green: 0.72, blue: 0.92),
            steps: [
                "Выберите свой язык и язык собеседника. Для собеседника можно оставить Auto.",
                "Удерживайте `Я говорю`, произнесите фразу и отпустите кнопку.",
                "Приложение переведёт фразу на язык собеседника и озвучит её через динамик.",
                "Для ответа удерживайте `Собеседник говорит` и направьте микрофон в сторону человека.",
                "После ответа приложение переведёт фразу на ваш язык и добавит обе версии в журнал диалога."
            ],
            facts: [
                "Телефон не нужно передавать собеседнику.",
                "Одновременно активна только одна сторона разговора.",
                "Для TestFlight лучше использовать ephemeral token endpoint, а не хранить постоянный OpenAI ключ в приложении."
            ],
            noteTitle: "Сеть и приватность",
            noteText: "Live Translate зависит от доступности OpenAI Realtime API. Из России может потребоваться VPN или собственный backend/proxy. По умолчанию сохраняется только текст диалога, а аудиофрагменты отключены.",
            codeSample: nil,
            linkTitle: "Документация OpenAI Realtime Translation",
            linkURL: "https://developers.openai.com/api/docs/guides/realtime-translation"
        ),
        GuideTopic(
            id: "sber-credentials",
            title: "Почему Sber отвечает credentials doesn't match db data?",
            summary: "Это почти всегда ошибка типа ключа или несоответствие проекта выбранному API.",
            icon: "exclamationmark.lock.fill",
            accent: Color(red: 0.98, green: 0.56, blue: 0.42),
            steps: [
                "Проверьте, что для SaluteSpeech вы используете ключ именно от SaluteSpeech API.",
                "Проверьте, что для GigaChat используете отдельный ключ GigaChat API, если он нужен.",
                "Удалите из поля любые префиксы вроде Basic и Bearer.",
                "Убедитесь, что вставили полный Base64 Authorization Key без обрезки."
            ],
            facts: [
                "Access token из OAuth-ответа сюда не подходит.",
                "Ключ от одного проекта Sber не всегда подходит для другого API.",
                "Если ключ был перевыпущен, старый надо заменить в настройках."
            ],
            noteTitle: "Суть ошибки",
            noteText: "Sber не находит корректную связку client credentials в своей базе для того API, к которому вы обращаетесь.",
            codeSample: nil,
            linkTitle: "Открыть кабинет Sber",
            linkURL: "https://developers.sber.ru/portal/products"
        ),
        GuideTopic(
            id: "gigachat-key",
            title: "Когда нужен второй ключ GigaChat?",
            summary: "Он нужен только для этапа постобработки текста, если после транскрибации вы отправляете результат в LLM по промпту.",
            icon: "brain.head.profile",
            accent: Color(red: 0.99, green: 0.63, blue: 0.68),
            steps: [
                "Если вам нужна только расшифровка речи в текст, используйте SaluteSpeech.",
                "Если хотите дополнительно редактировать, структурировать или сокращать текст через LLM, добавьте GigaChat ключ.",
                "Выберите нужный режим обработки в приложении.",
                "При необходимости задайте промпт с правилами редактирования."
            ],
            facts: [
                "Без GigaChat можно получить чистую транскрибацию.",
                "С GigaChat можно привести текст к заметке, протоколу, письму или конспекту.",
                "Если используете OpenAI вместо GigaChat, второй Sber-ключ для LLM не нужен."
            ],
            noteTitle: "Коротко",
            noteText: "SaluteSpeech отвечает за speech-to-text, а GigaChat или OpenAI за смысловую обработку уже готового текста.",
            codeSample: nil,
            linkTitle: nil,
            linkURL: nil
        )
    ]
}
