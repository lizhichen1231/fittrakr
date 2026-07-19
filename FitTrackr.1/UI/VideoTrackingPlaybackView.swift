import SwiftUI
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers
import Combine

// MARK: - 视频来源辅助

/// 扫描 App bundle 里打包的视频(把 .mov/.mp4 拖进工程,同步文件组会自动打包)。
enum BundleVideos {
    static func all() -> [URL] {
        let exts = ["mov", "mp4", "m4v", "MOV", "MP4", "M4V"]
        var urls: [URL] = []
        for e in exts {
            urls += Bundle.main.urls(forResourcesWithExtension: e, subdirectory: nil) ?? []
        }
        // 按文件名去重 + 排序
        var seen = Set<String>()
        return urls
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .filter { seen.insert($0.lastPathComponent).inserted }
    }
}

#if DEBUG
/// DEBUG-only:App bundle 内 `DebugReplayClips/` 子目录的 DanceTrack 回放测试片
/// (由 pbxproj 的 `[Debug] Copy Replay Clips` 脚本相位在 Debug 构建时拷入;Release 不拷)。
enum DebugReplayClips {
    static func all() -> [URL] {
        (Bundle.main.urls(forResourcesWithExtension: "mp4", subdirectory: "DebugReplayClips") ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
#endif

/// 把外部(相册/文件)选中的视频拷贝到临时目录,避免安全作用域 / 临时 URL 失效后读不到。
enum TempVideo {
    static func copyIntoTemp(_ src: URL, securityScoped: Bool) -> URL? {
        var didAccess = false
        if securityScoped { didAccess = src.startAccessingSecurityScopedResource() }
        defer { if didAccess { src.stopAccessingSecurityScopedResource() } }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("playback", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let ext = src.pathExtension.isEmpty ? "mov" : src.pathExtension
        let dest = dir.appendingPathComponent("clip_\(UUID().uuidString).\(ext)")
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: src, to: dest)
            return dest
        } catch {
            return nil
        }
    }
}

/// 相册视频选择器(PHPicker,出进程运行,不需要相册权限/Info.plist 描述)。
struct PhotoVideoPicker: UIViewControllerRepresentable {
    let onPick: (URL?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .videos
        config.selectionLimit = 1
        let vc = PHPickerViewController(configuration: config)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: (URL?) -> Void
        init(onPick: @escaping (URL?) -> Void) { self.onPick = onPick }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            let typeID = UTType.movie.identifier
            guard let provider = results.first?.itemProvider,
                  provider.hasItemConformingToTypeIdentifier(typeID) else {
                onPick(nil); return
            }
            // 闭包里的 URL 是临时文件,只在闭包内有效 → 立刻拷贝。
            provider.loadFileRepresentation(forTypeIdentifier: typeID) { url, _ in
                let copied = url.flatMap { TempVideo.copyIntoTemp($0, securityScoped: false) }
                DispatchQueue.main.async { self.onPick(copied) }
            }
        }
    }
}

// MARK: - 回放主界面(选片)

/// 模拟器回放追踪测试界面:选一段视频(bundle / 相册 / 文件)→ 用 VideoFileSource
/// 灌进与实时摄像头同一条 tracking pipeline → 复用同一套 overlay 渲染。
/// 全程不需要真机、不需要摄像头权限。
struct VideoTrackingPlaybackView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedURL: URL?
    @State private var isTestClip = false   // 选中的是 DebugReplayClips 测试片 → loop关 + 落盘SUMMARY
    @State private var showPhotoPicker = false
    @State private var importing = false
    @State private var loadError: String?

    var body: some View {
        NavigationView {
            Group {
                if let url = selectedURL {
                    PlaybackPlayerView(url: url, isTest: isTestClip) { selectedURL = nil }
                } else {
                    chooser
                }
            }
            .navigationTitle(selectedURL == nil ? "回放追踪测试" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var chooser: some View {
        List {
            #if DEBUG
            Section("🎬 DanceTrack 回放测试(DEBUG)") {
                let clips = DebugReplayClips.all()
                if clips.isEmpty {
                    Text("DebugReplayClips 为空。跑 ~/Datasets/DanceTrack_subset/_rz.py 生成 mp4 后重 build(Debug 配置)。")
                        .font(.footnote).foregroundColor(.secondary)
                } else {
                    ForEach(clips, id: \.self) { u in
                        Button {
                            isTestClip = true; selectedURL = u   // loop关 + 起 ReplayLogger + 落盘SUMMARY
                        } label: {
                            Label(u.lastPathComponent, systemImage: "figure.dance")
                        }
                    }
                }
            }
            #endif

            Section("App Bundle 内置视频") {
                let vids = BundleVideos.all()
                if vids.isEmpty {
                    Text("Bundle 里暂无视频。把带人、有移动的 .mov/.mp4 拖进 FitTrackr.1/ 目录(同步文件组会自动打包),或用下面的相册/文件选择。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(vids, id: \.self) { u in
                        Button {
                            isTestClip = false; selectedURL = u
                        } label: {
                            Label(u.lastPathComponent, systemImage: "film")
                        }
                    }
                }
            }

            Section("其他来源") {
                Button {
                    showPhotoPicker = true
                } label: {
                    Label("从相册选视频", systemImage: "photo.on.rectangle")
                }
                Button {
                    importing = true
                } label: {
                    Label("从文件选视频", systemImage: "folder")
                }
            }

            if let e = loadError {
                Section {
                    Text(e).font(.footnote).foregroundColor(.red)
                }
            }
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoVideoPicker { url in
                if let url { isTestClip = false; selectedURL = url } else { loadError = "无法加载所选相册视频" }
            }
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let src = urls.first,
                   let copied = TempVideo.copyIntoTemp(src, securityScoped: true) {
                    isTestClip = false; selectedURL = copied
                } else {
                    loadError = "无法读取所选文件"
                }
            case .failure(let err):
                loadError = err.localizedDescription
            }
        }
    }
}

// MARK: - 回放播放器(复用 tracking pipeline + overlay)

/// 持有播放 VM 与其帧源,使「丢帧」开关能在播放中实时切换。
private final class PlaybackModel: ObservableObject {
    let vm: CameraViewModel
    private let source: VideoFileSource
    private var vmRelay: AnyCancellable?
    let isTest: Bool
    let totalFrames: Int
    @Published var finished = false   // 测试片自然播完(loop关)→ 停末帧 + SUMMARY 已落盘

    @Published var dropLate: Bool {
        didSet { source.dropLateFrames = dropLate }
    }

    init(url: URL, isTest: Bool) {
        self.isTest = isTest
        // realtime:按 PTS 节流(2.2 已确认 → clip_5 LOST 计时成立);
        // 测试片 loop关(播完停末帧 + 出 SUMMARY);普通片 loop开(免"播完黑屏")。默认开丢帧。
        let s = VideoFileSource(url: url, realtime: true, loop: !isTest, dropLateFrames: true)
        let camVM = CameraViewModel(source: s)
        self.source = s
        self.vm = camVM
        self.dropLate = true   // init 内赋值不触发 didSet,已在上面以同值初始化 source

        // 总帧数(时长 × 名义帧率),供 HUD 显示 f/total(与 VideoFileSource 同一套同步 API)
        let asset = AVURLAsset(url: url)
        let dur = CMTimeGetSeconds(asset.duration)
        let fps = Double(asset.tracks(withMediaType: .video).first?.nominalFrameRate ?? 30)
        self.totalFrames = (dur.isFinite && fps > 0) ? Int((dur * fps).rounded()) : 0

        // 关键:vm 是嵌套的 ObservableObject。SwiftUI 只订阅了本 model(@StateObject),
        // 不会自动收到 vm 的 @Published 更新(processedCGImage/personBox/isTracking/perfHUD),
        // 否则界面冻在初值 → 黑屏 + 恒「搜索目标」。这里把 vm 的变更转发给本对象,
        // 让观察 model 的界面随每帧重绘。
        vmRelay = camVM.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }

        #if DEBUG
        if isTest {
            // 起日志器:接管 stdout → 落盘 Documents/ReplayLogs + 边写边解析计数
            ReplayLogger.shared.start(clip: url.deletingPathExtension().lastPathComponent)
            source.onFinished = { [weak self] in
                ReplayLogger.shared.stop()   // 写 SUMMARY + 还原 stdout
                DispatchQueue.main.async { self?.finished = true }
            }
        }
        #endif
    }

    /// 返回/关闭时调用:确保 stdout 一定被还原(stop 幂等,未 active 时空转)。
    func teardown() {
        #if DEBUG
        ReplayLogger.shared.stop()
        #endif
    }
}

private struct PlaybackPlayerView: View {
    @StateObject private var model: PlaybackModel
    private let onBack: () -> Void
    private let title: String
    #if DEBUG
    @State private var dSel = 0   // 0=off 1=D1 2=D2 3=D3,确诊 lockLargest 按什么选
    #endif

    init(url: URL, isTest: Bool = false, onBack: @escaping () -> Void) {
        _model = StateObject(wrappedValue: PlaybackModel(url: url, isTest: isTest))
        self.onBack = onBack
        self.title = url.lastPathComponent
    }

    var body: some View {
        GeometryReader { geo in
            let vm = model.vm
            ZStack {
                Color.black.ignoresSafeArea()

                // 处理后帧 + 框/死区/手部骨架(与实时相机界面同一套渲染)
                PreviewCanvasView(pixelBuffer: vm.processedPB,
                                  image: vm.processedCGImage,
                                  handLandmarks: vm.handLandmarks,
                                  personBoxN: vm.personBox,
                                  // 死区随 debug 开关显隐(回放默认关 → 干净)
                                  deadZoneFraction: vm.showDebugOverlay ? vm.deadZoneFraction : .zero)
                    .ignoresSafeArea()

                // 骨架叠加层(读取 SkeletonAddon 共享状态)
                SkeletonDebugOverlayView()
                    .ignoresSafeArea()

                VStack(spacing: 8) {
                    #if DEBUG
                    // Part 2.3 第0行:clip 名 + 帧号/总帧 + 回放时间(与 console 日志逐帧对齐;
                    // 帧号/时间取自 ReplayLogger 解析的 PROBE,follow 为 private 无法直读)。
                    if model.isTest {
                        HStack {
                            Text("🎬 \(title)  f\(ReplayLogger.shared.lastFrame)/\(model.totalFrames)  t=\(String(format: "%.1f", ReplayLogger.shared.lastTime))s"
                                 + (model.finished ? "  ✓播完·SUMMARY已写ReplayLogs" : ""))
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(model.finished ? .green : .white)
                                .lineLimit(1).minimumScaleFactor(0.4)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(.black.opacity(0.6), in: Capsule())
                            Spacer()
                        }
                    }
                    #endif
                    HStack {
                        Button(action: onBack) {
                            Label("重选", systemImage: "chevron.left")
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        Spacer()
                        Text(vm.isTracking ? vm.trackingInfo : "搜索目标…")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                    }

                    // 卡2 验证控件(纯接线,不碰检测/注入/锁定逻辑)
                    HStack(spacing: 8) {
                        // 锁定/录制 → vm.toggleRecord()(触发 lockLargest 锁最大框=主角,isLocked=true → findTarget 开跑)
                        Button {
                            vm.toggleRecord()
                        } label: {
                            Label(vm.isRecording ? "锁定中" : "锁定",
                                  systemImage: vm.isRecording ? "lock.fill" : "lock.open")
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(vm.isRecording ? Color.red.opacity(0.75) : Color.white.opacity(0.15), in: Capsule())
                        }
                        #if DEBUG
                        // 假人注入开关(= showDebugOverlay)。手动 Binding(vm 非 @ObservedObject);刷新靠 vmRelay。
                        Toggle(isOn: Binding(get: { vm.showDebugOverlay },
                                             set: { vm.showDebugOverlay = $0 })) {
                            Text("假人").font(.system(size: 13, weight: .semibold))
                        }
                        .toggleStyle(.button)
                        .tint(.orange)
                        #endif
                        Spacer()
                    }

                    #if DEBUG
                    // D-场景选择器:点一下即切(不用改代码重 build)。选中后 console 每帧打 LOCK 决策行。
                    HStack(spacing: 6) {
                        ForEach(Array(["off", "D1大小", "D2位置", "D3爹"].enumerated()), id: \.offset) { idx, name in
                            Button {
                                dSel = idx
                                switch idx {
                                case 1: FakePersonInjector.shared.dScenario = .d1
                                case 2: FakePersonInjector.shared.dScenario = .d2
                                case 3: FakePersonInjector.shared.dScenario = .d3
                                default: FakePersonInjector.shared.dScenario = .off
                                }
                            } label: {
                                Text(name)
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(dSel == idx ? Color.purple.opacity(0.8) : Color.white.opacity(0.15), in: Capsule())
                            }
                        }
                        Spacer()
                    }
                    #endif

                    HStack {
                        Text(vm.perfHUD)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.green)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.black.opacity(0.55), in: Capsule())
                        Spacer()
                        // 实时丢帧(开)= 跟住真实时间、跳过处理不过来的帧;关 = 逐帧慢放看得全
                        Toggle(isOn: $model.dropLate) {
                            Text("实时丢帧").font(.system(size: 11, weight: .semibold))
                        }
                        .toggleStyle(.button)
                        .tint(.blue)
                    }

                    // 卡2 最简 HUD:候选人数 + 锁谁(细节看 console REPLAY/FAKE 行)
                    if !vm.fakeHUD.isEmpty {
                        HStack {
                            Text("👥 " + vm.fakeHUD)
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundColor(vm.fakeHUD.contains("假人") ? .red : .green)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(.black.opacity(0.6), in: Capsule())
                            Spacer()
                        }
                    }

                    #if DEBUG
                    // 卡3 跟踪态:锁谁/状态/找回@(单色等宽);找回 nx 接近 0/1 = crop 外找回=全帧搜索
                    if !vm.trkHUD.isEmpty {
                        HStack {
                            Text(vm.trkHUD)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(.white)
                                .lineLimit(1).minimumScaleFactor(0.5)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(.black.opacity(0.55), in: Capsule())
                            Spacer()
                        }
                    }
                    #endif

                    // 临时:cx vs 几何 诊断行(回放也读)
                    if !vm.dbgCropHUD.isEmpty {
                        HStack {
                            Text(vm.dbgCropHUD)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(.cyan)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(.black.opacity(0.6), in: Capsule())
                            Spacer()
                        }
                    }

                    Spacer()

                    Text(title)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.6))
                        .padding(.bottom, 8)
                }
                .padding(.horizontal, 16)
                .padding(.top, 60)
            }
            .onAppear {
                vm.updateOutputSize(for: geo.size)
                vm.start()
            }
            .onChange(of: geo.size) { newSize in
                vm.updateOutputSize(for: newSize)
            }
            .onDisappear { vm.stop(); model.teardown() }   // teardown:还原 stdout(测试片提前返回也不漏)
        }
        .preferredColorScheme(.dark)
    }
}
