import AppKit

/// Отладка: рисует сцены обоими движками (Metal и WebKit) в невидимом окне и сохраняет кадры,
/// чтобы сравнить их. Запуск: LW_RENDER_TEST="id1,id2" LW_RENDER_OUT=/папка LiveWall
/// (id можно указывать началом, например «3212ED02»). После проверки приложение выходит.
@MainActor
enum RenderTest {
    static var requested: Bool { ProcessInfo.processInfo.environment["LW_RENDER_TEST"] != nil }

    private static var window: DesktopWindow?
    private static var current: WallpaperRenderer?

    static func run() {
        let env = ProcessInfo.processInfo.environment
        let prefixes = (env["LW_RENDER_TEST"] ?? "").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces).uppercased() }
        let out = URL(fileURLWithPath: env["LW_RENDER_OUT"] ?? NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        Paths.ensure()
        RuntimeFiles.install()
        let library = LibraryStore()
        let items = prefixes.compactMap { p in library.items.first { $0.id.uppercased().hasPrefix(p) } }
        // Окно на уровне рабочего стола, как у настоящих обоев: в невидимом окне WebKit
        // почти останавливает страницу, и замер нагрузки был бы нечестным
        let frame = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1470, height: 956)
        let w = DesktopWindow(frame: frame)
        w.orderFrontRegardless()
        window = w
        // LW_RENDER_ENGINES=metal,webkit — какие движки; LW_RENDER_HOLD — секунд на каждый (для замеров)
        let engines = (env["LW_RENDER_ENGINES"] ?? "metal,webkit").split(separator: ",").map(String.init)
        var jobs: [(WallpaperItem, Bool)] = []
        for it in items { for e in engines { jobs.append((it, e == "metal")) } }
        next(jobs, out: out)
    }

    private static func next(_ jobs: [(WallpaperItem, Bool)], out: URL) {
        guard let (item, native) = jobs.first, let w = window else { NSLog("LW render test done"); exit(0) }
        current?.stop(); current?.view.removeFromSuperview()
        let r = RendererFactory.make(item: item, nativeScenes: native) { msg in NSLog("LW render test error %@: %@", item.title, msg) }
        let engine = (r is MetalSceneRenderer) ? "metal" : "webkit"
        r.view.frame = w.container.bounds
        w.container.addSubview(r.view)
        let env = ProcessInfo.processInfo.environment
        r.setFPS(Int(env["LW_RENDER_FPS"] ?? "") ?? 30)
        r.setSmartFPS(Int(env["LW_RENDER_SMART"] ?? "") ?? 0)
        r.start()
        current = r
        NSLog("LW render test start %@ %@", item.title, engine)
        let hold = Double(env["LW_RENDER_HOLD"] ?? "") ?? 5
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) {
            MainActor.assumeIsolated {
                r.snapshot { img in
                    MainActor.assumeIsolated {
                        let name = "\(item.id.prefix(8))-\(engine).jpg"
                        if let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                           let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
                            try? jpg.write(to: out.appendingPathComponent(name))
                            NSLog("LW render test wrote %@", name)
                        } else {
                            NSLog("LW render test: no image for %@", name)
                        }
                        next(Array(jobs.dropFirst()), out: out)
                    }
                }
            }
        }
    }
}
