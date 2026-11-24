import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var engine: WallpaperEngine
    @EnvironmentObject var library: LibraryStore

    private func b<T>(_ kp: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { app.settings[keyPath: kp] }, set: { app.settings[keyPath: kp] = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: tr("Настройки"), subtitle: tr("Производительность, звук, мониторы и система"))
            form
        }
    }

    private var form: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    LogoMark(size: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("LiveWall 1.0").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text)
                        Text(tr("Живые обои для macOS")).font(.system(size: 12)).foregroundStyle(Theme.text2)
                    }
                    Spacer()
                    Button { app.overlay = .onboarding } label: { Label(tr("Гайд"), systemImage: "sparkles") }
                        .buttonStyle(GhostButtonStyle(compact: true))
                    Button { app.overlay = .tos } label: { Label(tr("Условия"), systemImage: "doc.text") }
                        .buttonStyle(GhostButtonStyle(compact: true))
                    Button { app.overlay = .credits } label: { Label(tr("Титры"), systemImage: "film.stack") }
                        .buttonStyle(CrimsonButtonStyle())
                }
                .padding(.vertical, 4)
                Toggle(tr("Показывать заставку при запуске"), isOn: b(\.showSplash))
            }

            UpdateSettingsSection()

            Section(tr("Язык")) {
                Picker(tr("Язык интерфейса"), selection: b(\.language)) {
                    Text(tr("Как в системе")).tag("system")
                    Text(tr("Русский")).tag("ru")
                    Text("English").tag("en")
                }
                .pickerStyle(.segmented)
            }

            Section(tr("Производительность")) {
                Picker(tr("Ограничение FPS"), selection: b(\.fpsLimit)) {
                    ForEach([10, 15, 24, 30, 60, 120], id: \.self) { Text($0 == 15 ? tr("15 кадров/с (экономно)") : tr("%@ кадров/с", $0)).tag($0) }
                }
                Toggle(tr("Пауза, когда приложение открыто на весь экран"), isOn: b(\.pauseOnFullscreen))
                Toggle(tr("Пауза, когда окно развёрнуто почти на весь экран"), isOn: b(\.pauseOnMaximized))
                Toggle(tr("Пауза, когда рабочий стол закрыт окнами (экономия CPU)"), isOn: b(\.pauseWhenCovered))
                Toggle(tr("Пауза при работе от батареи"), isOn: b(\.pauseOnBattery))
                Toggle(tr("Пауза при блокировке экрана и сне дисплея"), isOn: b(\.pauseOnLock))
                Toggle(tr("Пауза всех обоев"), isOn: $engine.userPaused)
            }

            Section(tr("Звук обоев")) {
                Toggle(tr("Без звука"), isOn: b(\.muted))
                SliderRow(title: tr("Громкость"), value: b(\.volume), range: 0...1, format: "%.2f")
                    .disabled(app.settings.muted)
                Text(tr("Звук воспроизводится только с основного монитора.")).font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle(tr("Обои реагируют на системный звук"), isOn: b(\.audioReactive))
                LabeledContent(tr("Состояние")) { Text(app.audioStatus).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
                HStack {
                    if app.audioNeedsPermission {
                        Button(tr("Выдать доступ")) { app.updateAudioCapture(userInitiated: true) }
                            .buttonStyle(CrimsonButtonStyle())
                    }
                    Button(tr("Открыть настройки конфиденциальности")) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                    .buttonStyle(GhostButtonStyle(compact: true))
                    Button(tr("Перезапустить LiveWall")) { AppRestart.now() }
                        .buttonStyle(GhostButtonStyle(compact: true))
                }
            } header: {
                Text(tr("Аудио-визуализация"))
            } footer: {
                Text(tr("Для захвата системного звука macOS требует разрешение «Запись экрана и системного звука». Видео при этом не записывается. Спектр доступен веб-обоям (wallpaperRegisterAudioListener), шейдерам (iAudio, iSpectrum) и сценам."))
            }

            Section(tr("Интерактивность")) {
                Toggle(tr("Обои реагируют на движение мыши (параллакс, эффекты)"), isOn: b(\.mouseInteraction))
                Toggle(tr("Передавать клики по рабочему столу в обои"), isOn: b(\.clickInteraction))
            }

            Section {
                Toggle(tr("Адаптировать сцены к времени суток и погоде"), isOn: b(\.ambientEnabled))
                HStack {
                    TextField(tr("Город для погоды"), text: b(\.weatherCity))
                        .onSubmit { app.ambientService.findCity(app.settings.weatherCity) }
                    Button(tr("Найти")) { app.ambientService.findCity(app.settings.weatherCity) }
                        .buttonStyle(CrimsonButtonStyle())
                    if !app.settings.weatherCityName.isEmpty {
                        Button(tr("Сбросить")) { app.ambientService.clearCity() }.buttonStyle(GhostButtonStyle(compact: true))
                    }
                }
                AmbientStatusRow()
            } header: {
                Text(tr("Время суток и погода"))
            } footer: {
                Text(tr("Сцены с включённой адаптацией темнеют ночью, теплеют на закате, а в дождь и снег показывают осадки. Погода — Open-Meteo: туда отправляется только название города и координаты."))
            }

            Section {
                Toggle(tr("«Сейчас играет» из Музыки, Spotify и браузеров"), isOn: b(\.nowPlayingWidgets))
                Toggle(tr("Ближайшее событие из Календаря"), isOn: Binding(get: { app.settings.calendarWidgets }, set: { v in
                    app.settings.calendarWidgets = v
                    if v { app.sysInfo.requestCalendarAccess() }
                }))
                if !app.sysInfo.calendarStatus.isEmpty {
                    Text(app.sysInfo.calendarStatus).font(.caption).foregroundStyle(Theme.text2)
                }
            } header: {
                Text(tr("Виджеты"))
            } footer: {
                Text(tr("Виджеты — это текстовые слои сцены с токенами: {cpu} {ram} {battery} {track} {artist} {event} {eventTime} {temp} {weather} {city}. Готовые пресеты — в редакторе сцен, кнопка «+» → «Виджет»."))
            }

            Section(tr("Мониторы")) {
                Toggle(tr("Растянуть одни обои на все мониторы"), isOn: b(\.spanMode))
                ForEach(engine.screens) { s in
                    LabeledContent(s.name) {
                        Text(library.item(engine.desiredItem(for: s.key))?.title ?? "—").foregroundStyle(.secondary)
                    }
                }
            }

            Section(tr("Система")) {
                Toggle(tr("Запускать при входе в систему"), isOn: b(\.launchAtLogin))
                if Bundle.main.bundlePath.hasSuffix(".app") == false {
                    Text(tr("Автозапуск работает только для собранного LiveWall.app.")).font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button(tr("Открыть папку данных")) { NSWorkspace.shared.open(Paths.root) }.buttonStyle(GhostButtonStyle(compact: true))
                    Button(tr("Добавить примеры заново")) { Samples.install(into: library) }.buttonStyle(GhostButtonStyle(compact: true))
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .toggleStyle(CrimsonToggleStyle())
    }
}

/// Строка статуса погоды (отдельный View, чтобы следить за AmbientService).
struct AmbientStatusRow: View {
    @ObservedObject var ambient = AppState.shared.ambientService
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: ambient.state.night > 0.5 ? "moon.stars.fill" : (ambient.state.golden > 0.3 ? "sunset.fill" : "sun.max.fill"))
                .foregroundStyle(Theme.scarlet)
            Text(ambient.status).font(.caption).foregroundStyle(Theme.text2)
        }
    }
}
