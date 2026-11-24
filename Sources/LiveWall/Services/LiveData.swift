import Foundation
import AppKit
import IOKit.ps
import EventKit

// MARK: - Системные данные для виджетов: CPU, память, батарея, музыка, календарь

@MainActor
final class SystemInfoService: ObservableObject {
    @Published private(set) var info: [String: String] = [:]
    @Published var calendarStatus = ""

    weak var app: AppState?
    private var timer: Timer?
    private var prevTicks: (used: UInt64, total: UInt64)?
    private let eventStore = EKEventStore()
    private var nowPlaying: (title: String, artist: String, playing: Bool) = ("", "", false)
    private var nextEvent: (title: String, time: String) = ("", "")
    private var lastCalendarFetch = Date.distantPast

    /// Данные собираются, только пока есть видимые обои (вызывается движком).
    func setActive(_ active: Bool) {
        if active && timer == nil {
            refresh()
            timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        } else if !active {
            timer?.invalidate(); timer = nil
        }
    }

    func refresh() {
        var d = info
        if let cpu = cpuUsage() { d["cpu"] = "\(Int(cpu.rounded()))%" }
        if let mem = memoryUsage() { d["ram"] = "\(Int(mem.rounded()))%" }
        let (bat, charging) = battery()
        d["battery"] = bat.map { "\($0)%" } ?? "—"
        d["charging"] = charging ? "⚡︎" : ""
        if app?.settings.nowPlayingWidgets ?? true { fetchNowPlaying() }
        d["track"] = nowPlaying.title.isEmpty ? tr("Ничего не играет") : nowPlaying.title
        d["artist"] = nowPlaying.artist
        if app?.settings.calendarWidgets == true, Date().timeIntervalSince(lastCalendarFetch) > 60 { fetchNextEvent() }
        d["event"] = nextEvent.title.isEmpty ? tr("Событий нет") : nextEvent.title
        d["eventTime"] = nextEvent.time
        if let amb = app?.ambient {
            d["temp"] = amb.temperature.map { "\(Int($0.rounded()))°" } ?? "—"
            d["weather"] = amb.conditionTitle
            d["city"] = amb.cityName
        }
        if d != info {
            info = d
            app?.engine.pushInfo(d)
        }
    }

    // CPU: разница тиков процессора между замерами
    private func cpuUsage() -> Double? {
        var count: mach_msg_type_number_t = 0
        var infoArr: processor_info_array_t?
        var cpus: natural_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpus, &infoArr, &count) == KERN_SUCCESS,
              let infoArr else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: infoArr), vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.size)) }
        var used: UInt64 = 0, total: UInt64 = 0
        for i in 0..<Int(cpus) {
            let base = Int(CPU_STATE_MAX) * i
            let user = UInt64(infoArr[base + Int(CPU_STATE_USER)]), sys = UInt64(infoArr[base + Int(CPU_STATE_SYSTEM)])
            let nice = UInt64(infoArr[base + Int(CPU_STATE_NICE)]), idle = UInt64(infoArr[base + Int(CPU_STATE_IDLE)])
            used += user + sys + nice
            total += user + sys + nice + idle
        }
        defer { prevTicks = (used, total) }
        guard let p = prevTicks, total > p.total else { return nil }
        return Double(used - p.used) / Double(total - p.total) * 100
    }

    private func memoryUsage() -> Double? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard r == KERN_SUCCESS else { return nil }
        let page = Double(vm_kernel_page_size)
        let used = Double(stats.active_count + stats.wire_count + stats.compressor_page_count) * page
        return used / Double(ProcessInfo.processInfo.physicalMemory) * 100
    }

    private func battery() -> (Int?, Bool) {
        guard let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snap)?.takeRetainedValue() as? [CFTypeRef] else { return (nil, false) }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(snap, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
            let cap = d[kIOPSCurrentCapacityKey] as? Int
            let charging = (d[kIOPSIsChargingKey] as? Bool) ?? false
            if cap != nil { return (cap, charging) }
        }
        return (nil, false)
    }

    // «Сейчас играет» — системный MediaRemote (работает с Музыкой, Spotify, браузерами)
    private typealias MRGetInfo = @convention(c) (DispatchQueue, @escaping @convention(block) (NSDictionary?) -> Void) -> Void
    private static let mrGetInfo: MRGetInfo? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
              let sym = dlsym(h, "MRMediaRemoteGetNowPlayingInfo") else { return nil }
        return unsafeBitCast(sym, to: MRGetInfo.self)
    }()

    private func fetchNowPlaying() {
        guard let f = Self.mrGetInfo else { return }
        f(DispatchQueue.main) { [weak self] dict in
            let title = dict?["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
            let artist = dict?["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
            let rate = (dict?["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0
            MainActor.assumeIsolated { self?.nowPlaying = (title, artist, rate > 0) }
        }
    }

    // Календарь
    func requestCalendarAccess() {
        eventStore.requestFullAccessToEvents { [weak self] granted, error in
            Task { @MainActor in
                guard let self else { return }
                if granted {
                    self.calendarStatus = tr("Доступ к календарю есть")
                    self.lastCalendarFetch = .distantPast
                    self.refresh()
                } else {
                    self.calendarStatus = tr("Нет доступа. Разрешите LiveWall в «Конфиденциальность и безопасность → Календари».")
                    self.app?.settings.calendarWidgets = false
                }
            }
        }
    }

    private func fetchNextEvent() {
        lastCalendarFetch = Date()
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
        let now = Date()
        let pred = eventStore.predicateForEvents(withStart: now, end: now.addingTimeInterval(24 * 3600), calendars: nil)
        let ev = eventStore.events(matching: pred).filter { !$0.isAllDay && $0.endDate > now }.sorted { $0.startDate < $1.startDate }.first
        if let ev {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            nextEvent = (ev.title ?? "", f.string(from: ev.startDate))
        } else {
            nextEvent = ("", "")
        }
    }
}

// MARK: - Время суток и погода (Open-Meteo, без ключа)

struct AmbientState: Equatable {
    var night: Double = 0          // 0 день … 1 ночь
    var golden: Double = 0         // 0 … 1 «золотой час»
    var precip: String = "none"    // none | rain | snow
    var intensity: Double = 0      // 0 … 1
    var cloud: Double = 0          // 0 … 1
    var temperature: Double? = nil
    var code: Int? = nil
    var cityName: String = ""
    var sunrise: Date? = nil
    var sunset: Date? = nil

    var conditionTitle: String {
        guard let c = code else { return "—" }
        switch c {
        case 0: return tr("Ясно")
        case 1, 2: return tr("Малооблачно")
        case 3: return tr("Пасмурно")
        case 45, 48: return tr("Туман")
        case 51...57: return tr("Морось")
        case 61...67, 80...82: return tr("Дождь")
        case 71...77, 85, 86: return tr("Снег")
        case 95...99: return tr("Гроза")
        default: return "—"
        }
    }

    var js: String {
        let d: [String: Any] = ["night": night, "golden": golden, "precip": precip, "intensity": intensity, "cloud": cloud]
        guard let data = try? JSONSerialization.data(withJSONObject: d), let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}

@MainActor
final class AmbientService: ObservableObject {
    @Published private(set) var state = AmbientState()
    @Published var status = ""
    weak var app: AppState?
    private var timer: Timer?
    private var lastWeather = Date.distantPast
    private var weatherCode: Int?
    private var temperature: Double?
    private var cloud: Double = 0
    private var sunrise: Date?
    private var sunset: Date?

    func start() {
        guard timer == nil else { return }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard let s = app?.settings else { return }
        if s.weatherLat != 0 || s.weatherLon != 0, Date().timeIntervalSince(lastWeather) > 1800 {
            fetchWeather(lat: s.weatherLat, lon: s.weatherLon)
        }
        recompute()
    }

    func recompute() {
        let cal = Calendar.current, now = Date()
        let rise = sunrise ?? cal.date(bySettingHour: 7, minute: 0, second: 0, of: now)!
        let set = sunset ?? cal.date(bySettingHour: 18, minute: 30, second: 0, of: now)!
        let t = now.timeIntervalSince1970, r = rise.timeIntervalSince1970, st = set.timeIntervalSince1970
        let ramp: Double = 3600 // час сумерек
        var night: Double
        if t < r - ramp || t > st + ramp { night = 1 }
        else if t < r + ramp { night = max(0, min(1, (r + ramp - t) / (2 * ramp))) }
        else if t > st - ramp { night = max(0, min(1, (t - (st - ramp)) / (2 * ramp))) }
        else { night = 0 }
        let golden = max(0, 1 - min(abs(t - r), abs(t - st)) / 2700)

        var st2 = AmbientState()
        st2.night = night
        st2.golden = golden
        st2.cloud = cloud
        st2.temperature = temperature
        st2.code = weatherCode
        st2.cityName = app?.settings.weatherCityName ?? ""
        st2.sunrise = sunrise; st2.sunset = sunset
        if let c = weatherCode {
            switch c {
            case 51...67, 80...82, 95...99:
                st2.precip = "rain"
                st2.intensity = [51, 61, 80].contains(c) ? 0.35 : ([53, 63, 81].contains(c) ? 0.65 : 1)
            case 71...77, 85, 86:
                st2.precip = "snow"
                st2.intensity = [71, 85].contains(c) ? 0.4 : ([73].contains(c) ? 0.7 : 1)
            default: break
            }
        }
        if st2 != state {
            state = st2
            app?.engine.pushAmbient(st2)
            app?.sysInfo.refresh()
        }
        updateStatus()
    }

    private func updateStatus() {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        var parts: [String] = []
        if !state.cityName.isEmpty { parts.append(state.cityName) }
        if let t = state.temperature { parts.append("\(Int(t.rounded()))°, \(state.conditionTitle.lowercased())") }
        if let r = sunrise, let s = sunset { parts.append(tr("восход %@, закат %@", f.string(from: r), f.string(from: s))) }
        status = parts.isEmpty ? tr("Город не указан — используется время по умолчанию (07:00–18:30)") : parts.joined(separator: " · ")
    }

    /// Поиск города через геокодер Open-Meteo.
    func findCity(_ name: String) {
        let q = name.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { status = tr("Введите название города"); return }
        guard var comps = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search") else { return }
        comps.queryItems = [URLQueryItem(name: "name", value: q), URLQueryItem(name: "count", value: "1"),
                            URLQueryItem(name: "language", value: Loc.isEnglish ? "en" : "ru")]
        guard let url = comps.url else { return }
        status = tr("Поиск города…")
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let first = (j["results"] as? [[String: Any]])?.first,
                      let lat = first["latitude"] as? Double, let lon = first["longitude"] as? Double else {
                    status = tr("Город не найден"); return
                }
                let country = first["country"] as? String ?? ""
                let cityName = (first["name"] as? String ?? q) + (country.isEmpty ? "" : ", \(country)")
                app?.settings.weatherLat = lat
                app?.settings.weatherLon = lon
                app?.settings.weatherCityName = cityName
                lastWeather = .distantPast
                tick()
            } catch {
                status = tr("Ошибка сети: %@", error.localizedDescription)
            }
        }
    }

    func clearCity() {
        app?.settings.weatherLat = 0; app?.settings.weatherLon = 0
        app?.settings.weatherCityName = ""; app?.settings.weatherCity = ""
        weatherCode = nil; temperature = nil; sunrise = nil; sunset = nil; cloud = 0
        recompute()
    }

    private func fetchWeather(lat: Double, lon: Double) {
        lastWeather = Date()
        let s = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,weather_code,cloud_cover&daily=sunrise,sunset&timezone=auto&forecast_days=1"
        guard let url = URL(string: s) else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            if let cur = j["current"] as? [String: Any] {
                temperature = cur["temperature_2m"] as? Double
                weatherCode = (cur["weather_code"] as? NSNumber)?.intValue
                cloud = ((cur["cloud_cover"] as? NSNumber)?.doubleValue ?? 0) / 100
            }
            if let daily = j["daily"] as? [String: Any] {
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd'T'HH:mm"
                if let tz = j["timezone"] as? String { f.timeZone = TimeZone(identifier: tz) }
                sunrise = (daily["sunrise"] as? [String])?.first.flatMap { f.date(from: $0) }
                sunset = (daily["sunset"] as? [String])?.first.flatMap { f.date(from: $0) }
            }
            recompute()
        }
    }
}
