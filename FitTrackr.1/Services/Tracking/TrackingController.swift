import AVFoundation
import Vision
import CoreImage
import QuartzCore

enum CaptureMode { case fitness, dance }

struct FollowResult {
    let fps: Double
    let zoom: CGFloat
    let confidence: CGFloat
    let rawBox: CGRect?
    let stableBox: CGRect?
    let cropRect: CGRect
    let previewCG: CGImage?
    let ciScaled: CIImage?
    var previewPB: CVPixelBuffer? = nil   // 刀1:录制中 renderCrop 直渲的 CVPixelBuffer(供 Recorder 直吃,替软 blit)
    let pts: CMTime
    let sensorSize: CGSize
    // 阶段计时（ms），供 HUD/日志显示
    var msRect: Double = 0
    var msPose: Double = 0
    var msRender: Double = 0
}

// 可热调参数
extension TrackingController {
    struct Tunables {
        var deadZoneW: CGFloat
        var deadZoneH: CGFloat

        var natFreqHzX: CGFloat
        var natFreqHzY: CGFloat
        var damping:   CGFloat
        var softZoneGain: CGFloat
        var maxVelPxPerSec: CGFloat
        var maxAccPxPerSec2: CGFloat

        var maxZoom: CGFloat
        //DEPRECATED: 不再驱动 zoom，变焦参数见 ZoomConfig；保留仅为兼容 Tunables/UI/预设序列化，待 UI 重构时清理。
        var zoomDeadband: CGFloat
        //DEPRECATED: 不再驱动 zoom，变焦参数见 ZoomConfig；保留仅为兼容 Tunables/UI/预设序列化，待 UI 重构时清理。
        var maxZoomChangePerSec: CGFloat
        //DEPRECATED: 不再驱动 zoom，变焦参数见 ZoomConfig；保留仅为兼容 Tunables/UI/预设序列化，待 UI 重构时清理。
        var maxZoomInPerSec: CGFloat
        //DEPRECATED: 不再驱动 zoom，变焦参数见 ZoomConfig；保留仅为兼容 Tunables/UI/预设序列化，待 UI 重构时清理。
        var maxZoomOutPerSec: CGFloat
        //DEPRECATED: 不再驱动 zoom，变焦参数见 ZoomConfig；保留仅为兼容 Tunables/UI/预设序列化，待 UI 重构时清理。
        var targetWidthLower: CGFloat
        //DEPRECATED: 不再驱动 zoom，变焦参数见 ZoomConfig；保留仅为兼容 Tunables/UI/预设序列化，待 UI 重构时清理。
        var targetWidthUpper: CGFloat

        // 抖抑 & 检测频率
        var microMovePx: CGFloat
        var detInterval: CGFloat

        // 自适应阻尼/频率
        var adaptiveEnabled: Bool
        var jitterLowPx: CGFloat
        var jitterHighPx: CGFloat
    }
}

final class TrackingController {

    // ——— 优化后的默认参数 ——— //
    struct Cfg {
        // Detection / Follow - 平衡灵敏和防抖
        var detectIntervalFrames = 1  // 每帧都检测，提高响应速度
        var deadZone = CGSize(width: 0.35, height: 0.45)  // 适中的死区
        var inPlaceDeadZone = CGSize(width: 0.40, height: 0.50)  // 原地运动时的特殊死区

        // PD smoothing - 更灵敏的响应
        var natFreqHzX: CGFloat = 1.9  // 提高频率，更快响应
        var natFreqHzY: CGFloat = 2.1
        var damping: CGFloat = 1.08  // 适中的阻尼
        var softZoneGain: CGFloat = 0.70
        var maxVelPxPerSec: CGFloat = 2200  // 提高最大速度
        var maxAccPxPerSec2: CGFloat = 3500  // 提高最大加速度

        // 速度阻尼
        var velocityDamping: CGFloat = 0.95  // 轻微阻尼

        // Zoom
        var maxZoom: CGFloat = 5.0   // ← 仍在用：作为 ZoomController 的 maxZoom 上限（init/applyPreset 同步；激进档 5.0）

        // —— 以下变焦参数均已 DEPRECATED：不再驱动 zoom，变焦控制律见 ZoomController / ZoomConfig。
        //    保留仅为兼容 Tunables/UI/预设序列化，待 UI 重构时清理。 ——
        var targetHeightRange: ClosedRange<CGFloat> = 0.65...0.80
        var zoomNatFreqHz: CGFloat = 3.0
        var zoomDamping: CGFloat = 1.0
        var zoomMaxVelPerSec: CGFloat = 1.2
        var zoomMaxAccPerSec2: CGFloat = 3.0
        var zoomDeadband: CGFloat = 0.014
        var maxZoomChangePerSec: CGFloat = 3.0
        var maxZoomInPerSec: CGFloat = 1.5
        var maxZoomOutPerSec: CGFloat = 1.2
        var targetWidthRange: ClosedRange<CGFloat> = 0.58...0.66
        var zoomChangeThreshold: CGFloat = 0.001
        var zoomSmoothAlpha: CGFloat = 0.1

        // Anti-jitter - 适度防抖
        var microMovePxOut: CGFloat = 6.0  // 适中的微移阈值
        var jitterThreshold: CGFloat = 3.0  // 抖动阈值

        // 最小移动阈值（像素）
        var minMovementPx: CGFloat = 0.5  // 大幅降低，几乎不限制

        // Adaptive（输出像素域）
        var adaptiveEnabled = true
        var jitterLowPx: CGFloat = 2.0  // 调整抖动阈值
        var jitterHighPx: CGFloat = 10.0

        // 原地运动检测阈值 - 改进的参数
        var positionStableThreshold: CGFloat = 0.008  // 更严格
        var aspectChangeThreshold: CGFloat = 0.15
        var inPlaceDetectionFrames = 15  // 减少到15帧
        var preInPlaceDetectionFrames = 3  // 预检测帧数
        var preInPlaceThreshold: CGFloat = 0.005  // 预检测阈值

        // 位置滤波系数
        var positionFilterAlpha: CGFloat = 0.25  // 更快的响应速度

        // —— 躯干高测量预处理（门控 + 突变拒绝 + 小窗中值）——
        //    链路：算躯干高 → [门控→突变拒绝→中值] → 喂 ZoomController。就这两层，不再叠 EMA/卡尔曼。
        var torsoMinConfidence: Float = 0.5     // 肩/髋关键点置信度门控：四点任一低于此值 → 冻结（不更新 ratio）
        var torsoOutlierMaxStep: CGFloat = 0.25 // 改动B:0.15→0.25,放宽门,真·快速移动不被误判离群
        var torsoMedianWindow = 5               // 小窗中值滤波帧数（压偶发单帧跳变）
        var torsoOutlierResetFrames = 3         // 改动B:8→3,离群只惯性续走几帧就软 re-baseline,不长时间冻

        // Other
        var lostFramesThreshold = 5  // 降低阈值，更快响应丢失
        var outputSize = CGSize(width: 1080, height: 1920)
    }
    var cfg = Cfg()
    var deadZoneFraction: CGSize { cfg.deadZone }

    // ===== 三态锁定状态机(唯一权威:只有 process 的状态推进处写它,下游只读)=====
    enum LockState: Equatable {
        case unlocked                        // 未锁定(auto-lock 管进入)
        case locked                          // 身份匹配正常,跟随
        case searching(since: TimeInterval)  // 身份匹配不上,冻结+找回
        case lost                            // 搜索超时(瞬时过渡,立即转 unlocked)
    }
    var lockState: LockState = .unlocked
    let searchTimeoutSec: TimeInterval = 4.0
    // ⑤ 找回冷却(旋转门另一半):searching→locked 后此时长内禁止再进 SEARCHING(简单计时器;
    //    StateDebouncer 已于方案B·刀2 出生(镜头切换首用),此处收编排在设计稿 §9 收编序第二位,待后续纯重构刀)
    let reacqCooldownSec: TimeInterval = 2.0
    private var reacqLockedAt: TimeInterval = -100   // 上次「找回成功」时刻;-100 = 初始不在冷却
    #if DEBUG
    var dbgStateEvent = ""     // 最近一次事件缩写(保持 3s)
    var dbgStateEventUntil: TimeInterval = 0
    var dbgSearchCandSeen = 0  // 本轮 searching 累计看过的候选数(lost 日志 totalCandidatesSeen)
    // 本帧延续分/生效门槛/候选并源:由 findTarget 写到 PersonIdentifier,HUD 从那读(见 dbgStateLine)
    #endif

    // 运行态
    var frameCount = 0
    var missCount = 0
    var lastTime = Date()
    var detFrameCount = 0
    var lastDetTime = Date()

    var sensorW: CGFloat = 1920
    var sensorH: CGFloat = 1080

    var zoom: CGFloat = 1.0
    var rawBox: CGRect?
    var stableBox: CGRect?
    var confidence: CGFloat = 0
    var velX: CGFloat = 0
    var velY: CGFloat = 0
    var lastCropRect: CGRect?

    var currentMode: CaptureMode = .fitness

    // 自适应统计（输出像素域）
    var lastOutCenter: CGPoint?
    var motionHist = [CGFloat]()
    let windowFrames = 36

    // 原地运动锁定的缩放值（in-place hold 用）
    var lockedZoom: CGFloat = 0
    // 变焦控制器（单一 log 域控制器，取代历史上 卡尔曼/EMA/弹簧/帧限幅/PD/面积分割 的多套打架机制）
    let zoomController = ZoomController()

    // 新增：锁定中心点和速度历史
    var lockedCenter: CGPoint?  // 原地运动时锁定的中心点
    var lastVelX: CGFloat = 0  // 上一帧的X速度
    var lastVelY: CGFloat = 0  // 上一帧的Y速度

    // 原地运动检测相关 - 改进版
    var centerHistory = [CGPoint]()
    let centerHistorySize = 20
    var aspectRatioHistory = [CGFloat]()
    let aspectHistorySize = 10
    var isDoingExerciseInPlace = false
    var positionStableFrames = 0
    var wasInPlace = false  // 上一帧是否在原地运动

    // 新增：预检测机制
    var preInPlaceFrames = 0
    var zoomFrozen = false

    // 新增：基于髋部的原地检测
    var hipHistory: [CGPoint] = []
    let hipHistorySize = 20
    var hipBasedInPlace = false
    var hipStableFrames = 0
    let hipStableThreshold: CGFloat = 0.03  // 髋部水平位移阈值
    let hipInPlaceRequiredFrames = 10

    // 弹簧平滑系统（位置/尺寸，平移链保留；缩放已迁移到 ZoomController）
    var positionSpring: CriticalDampedSpring2D!    // 位置弹簧
    var sizeSpring: CriticalDampedSpring2D!        // 尺寸弹簧

    // ===== 智能构图系统 =====
    var zoomMode: ZoomMode = .fixed                 // 缩放模式（默认固定模式，稳定后切换到智能模式）
    var framingOffset: CGPoint = .zero              // 构图偏移（由 ShotDecider 设置）
    var smoothedFramingOffset: CGPoint = .zero      // 平滑后的构图偏移
    let actionClassifier = ActionClassifier()       // 动作分类器
    let shotDecider = ShotDecider()                 // 景别决策器

    // ===== 骨骼检测缓存（避免重复检测）=====
    var lastPoseObservation: VNHumanBodyPoseObservation?
    var lastTightBox: CGRect?  // 骨骼点计算的紧贴框（原始值）
    var smoothedTightBox: CGRect?  // 平滑后的骨骼框（用于显示黄框）
    let tightBoxSmoothAlpha: CGFloat = 0.15  // 黄框平滑系数（越小越平滑）
    var lastHeightRatio: CGFloat?  // 缓存的高度比例（全身框高/画面高，矩形兜底）
    var lastTorsoRatio: CGFloat?   // 缓存的躯干比例（肩中点→髋中点投影距离/画面高）—— 缩放主测量；缺帧/低置信/离群时保留上一帧值，避免突变
    var torsoMedianBuf: [CGFloat] = []  // 小窗中值滤波缓冲（仅放通过门控+突变拒绝的 ratio）
    var torsoOutlierStreak = 0          // 连续离群帧计数（超 cfg.torsoOutlierResetFrames 则重新基准）

    // ===================== Zoom 行为四处修正:新增常量与状态(每处独立、可单独 toggle)=====================
    // 改动1:torso 冻结回退(torso 掉点时用 bbox 高在 torso 尺度上估值,治本修过放大)
    let torsoToBoxCalibAlpha: CGFloat = 0.10   // torsoToBoxHeight 慢 EMA 系数 α
    let torsoToBoxCalibFrames = 10             // 攒够 k 帧好 torso 才认定标定完成
    var torsoToBoxHeight: CGFloat = 0          // 转换比 = torsoRatio / 全身框高比(EMA);0=未初始化
    var torsoCalibFrames = 0                   // 已累计的好 torso 帧
    var hasCalibratedRatio = false             // 是否已标定(可用 bbox 估 torso)

    // 改动2:bbox 不出框上钳(安全网,只往外拉)
    let targetBodyFraction: CGFloat = 0.90     // 全身框最多占画面高的比例
    let bodyBoxJointMinConfidence: Float = 0.3 // 判定"完整全身框"的关键点置信门控
    var lastTightBoxIsFullBody = false         // 当前 tightBox 是否含上(头/肩)下(踝)完整

    // 改动3:原地锁定的尺度逃逸(修走近不缩)
    let scaleStableThreshold: CGFloat = 0.08   // (尺度逃逸)叠在 lock 上;disableInPlaceLock=true 时 isScaleStable 不再被调 → 死代码
    let torsoScaleHistorySize = 12             // 尺度稳定判定的近期窗口
    let scaleStableMinSamples = 5              // 样本不足此数 → 不阻止锁定(维持原 hip-only 行为)
    var torsoRatioHistory: [CGFloat] = []      // 近期 torso 比例(含改动1 的估计值)

    // 改动4:稳住 dt(修时快时慢)
    let dtMin: Double = 1.0 / 60.0
    let dtMax: Double = 1.0 / 20.0             // dt 上钳:慢帧不再放大平滑步长/速率帽
    let dtSmoothAlpha: Double = 0.15           // smoothedDt 短 EMA 系数
    var smoothedDt: Double = 1.0 / 60.0        // 平滑后的 dt(喂控制律 alpha 与速率帽)
    let logDtForTuning = false                 // 关:每帧 print 是帧率回退主因(dt 已验证完)。需要时临时置 true。
    var dbgCropLine = ""                        // cx vs 几何 诊断行,仅 hudDebugEnabled 时才 format(见下)
    var hudDebugEnabled = false                 // 由 VM 从 showDebugOverlay 同步:关时不每帧 String(format:)
    var dbgDetSpec = ""                         // 检测输入规格(wide/tele/Vision/out 尺寸),仅尺寸变化时 format
    var lastDetW = -1, lastDetH = -1            // 上次 wide 帧尺寸(整数比较,避免每帧分配)
    var dbgSlewLine = ""                        // slew 闸最近一次事件(SNAP/HIT),sticky 给 HUD

    // 全局位置速率闸(流水线最后、所有分支汇合后的兜底):平滑后再夹住单帧最大移动,任何上游突变都不跳。
    // 归一化 0..1。帧率无关:单帧上限 = maxPosRate × smoothedDt。zoom 的同类闸已在 ZoomController(log 域),不重复。
    let maxPosRate: CGFloat = 0.4              // 0.8→0.4:压「连续同向累积」漂(太钝再加 velTau 而非继续降)
    var prevCropCx: CGFloat = 0
    var prevCropCy: CGFloat = 0
    var slewHitStreak = 0                       // 连续顶上限帧数(=同向冲刺长度),诊断「逐帧合规累积」
    var prevCropValid = false                 // 改B:仅【冷启动首帧】为 false→snap;运行中重置不再置 false(走 slewGate 限速)

    // 改A:pose 回退 coast(治锚抖)——pose 丢失时先保持上一帧 pose 锚 poseCoastFrames 帧,再过渡到 rect
    let poseCoastFrames = 8                     // @60fps ≈ 130ms
    var lastPoseAnchorX: CGFloat = 0
    var lastPoseAnchorY: CGFloat = 0
    var poseLostFrames = 0
    var poseAnchorValid = false

    // 改动A:软锁定(原地重阻尼,不冻死)——实现方式:dtEff = dt / stiffness 喂控制器
    //         (等价 tau_eff = tau×stiffness、rateCap_eff = maxLogZoomRate/stiffness,不改 ZoomController)
    let disableInPlaceLock = true              // 禁用整条 in-place lock:任何时候都走正常 pose 跟随。置 false 即恢复。
    let lockStiffness: CGFloat = 4.0           // 原地刚度倍数(起手 4.0)
    let lockRampTime: CGFloat = 0.3            // 刚度渐入渐出时间(秒),避免 engage/release 速度突变
    var lockStiffnessCurrent: CGFloat = 1.0    // 当前刚度(渐变)
    var prevInPlaceActive = false              // LOCK 事件日志:上一帧锁定态

    // 改动B:离群惯性续走(不冻目标)
    let torsoVelAlpha: CGFloat = 0.30          // torso 每帧速度 EMA 系数
    let torsoCoastVelDecay: CGFloat = 0.90     // coast 期间速度衰减(防长 coast 跑飞)
    let torsoCoastBlendAlpha: CGFloat = 0.30   // re-baseline 软着陆混合(别硬 snap 到 raw)
    var torsoVelocity: CGFloat = 0             // 最近有效 torso 每帧变化(coast 外推用)
    var torsoLostFrames = 0                     // 改A(zoom侧):torso 连续瞬丢帧数;< poseCoastFrames 时保持上一帧值,不 est

    // 单层离群限幅:只作用在三级兜底【选完的最终 heightRatio】上,限制每帧变化幅度(唯一出口、单一变量,不和兜底抢源)
    let maxFedRatioStep: CGFloat = 0.08         // 每帧相对上一帧喂入值最多变 ±8%
    var lastFedRatio: CGFloat?                  // 上一帧真正喂给 updateZoomLevel 的值

    // ===== 二阶临界阻尼跟随(取代出口限速 + slewGate):cropC/zoom 各跑一个临界阻尼弹簧 =====
    // target 直接喂弹簧,弹簧输出即最终值;速度惯性本身限制单帧变化(速度不可能瞬间拉满)→
    // 废帧只能让它轻微加速、下帧被拉回 → 无需额外限速(叠了反而打架)。coast/兜底只决定 target。
    var cropCenterSpring: CriticalDampedSpring2D!   // 位置(像素),responseTime 0.35(更有重量感,不易被废帧带)
    var cropZoomSpring: CriticalDampedSpring!        // zoom(log 域),responseTime 0.45(缩放比平移更慢更稳)
    var cropSpringValid = false                      // false=首帧/重置后 reset 到 target(不从旧位置缓动)

    // 整合 HUD 实时量(合进 perfHUD 一行):原始 dt(ms)、torso 四点 conf(左右肩/左右胯)、zoom 测量来源
    var dbgRawDtMs: Double = 0
    var dbgCfLsh: Float = 0, dbgCfRsh: Float = 0, dbgCfLhp: Float = 0, dbgCfRhp: Float = 0
    var dbgZoomSrc = ""

    var dbgFakeHUD = ""   // 卡2 最简 HUD:候选人数 + 锁谁(细节看 console REPLAY/FAKE 行)
    var dbgTrkHUD = ""    // 卡3 最简 HUD:锁谁 / 状态 / 找回@(取自 PersonIdentifier.dbgTrkLine,不重算)

    // 【方案B·刀3】镜头仲裁影子模式状态(仅日志+HUD,不驱动设备)
    let lensArbiter = LensArbiter()
    private var lensShadowPrevCenter: CGPoint?
    private var lensShadowVel: CGFloat = 0
    private var lensShadowLastCmdAt: TimeInterval = -1
    var dbgLensShadow = ""   // HUD 行:LENS影子 UW/Wide dz=Y/N cd=剩余 Z=当前

    // 跳变取证(只抓数据,不改逻辑):pose 四点门是否过、rect 兜底框 conf、本帧锚/ratio/rect框跳变量
    var dbgPoseValid = false
    var dbgRectConf: CGFloat = -1
    var dbgAnchorDelta: CGFloat = 0            // 锚中心相对上帧位移(占画面宽比例)
    var dbgRatioDelta: CGFloat = 0            // 喂入 ratio 相对上帧变化(绝对)
    var dbgRectBoxDelta: CGFloat = 0          // rect 框中心相对上帧位移(占画面宽比例)
    var dbgPrevAnchorX: CGFloat = -1, dbgPrevAnchorY: CGFloat = -1
    var dbgPrevFedRatio: CGFloat = -1
    var dbgPrevRectBox: CGRect?

    // =====================================================================================================

    // 位置滤波相关
    var lastFilteredX: CGFloat = 0
    var lastFilteredY: CGFloat = 0

    // 卡尔曼滤波器
    var kalmanX: SimpleKalmanFilter?
    var kalmanY: SimpleKalmanFilter?
    var kalmanW: SimpleKalmanFilter?
    var kalmanH: SimpleKalmanFilter?

    // 平移累积器（横/纵）
    var posAccX: CGFloat = 0
    var posAccY: CGFloat = 0

    // 运动预测器
    var motionPredictor = MotionPredictor()

    // ===== 多摄切换 =====
    let cameraSelector = CameraSelector()
    private(set) var currentCamera: CameraType = .wide
    private(set) var currentDigitalCrop: CGFloat = 1.0

    let ciContext = CIContext(options: [
        .workingColorSpace: CGColorSpaceCreateDeviceRGB(),
        .outputColorSpace : CGColorSpaceCreateDeviceRGB()
    ])

    // 检测降采样池（长边 720）：只缩 Vision 输入；坐标用归一化、渲染仍走全分辨率
    var detPool: CVPixelBufferPool?
    var detPoolW = 0
    var detPoolH = 0
    let detLongSide: CGFloat = 720

    // 复用 Vision request（避免每帧 new）
    let rectRequest: VNDetectHumanRectanglesRequest = {
        let r = VNDetectHumanRectanglesRequest()
        r.upperBodyOnly = false
        return r
    }()
    // ① pose 去重:原 poseRequest 已删——Step B detectPose 改读 PersonIdentifier 的帧级缓存,不再自跑。

    // 初始化时创建滤波器
    init() {
        setupKalmanFilters()
        setupSprings()
        zoomController.setMaxZoom(cfg.maxZoom)
    }

    // 设置弹簧系统（位置/尺寸，平移链；缩放已迁移到 ZoomController）
    func setupSprings() {
        // 位置弹簧：响应时间 0.20s，最大速度 1800 像素/秒
        positionSpring = CriticalDampedSpring2D(initialValue: .zero, responseTime: 0.20, maxVelocity: 1800)
        // 尺寸弹簧：响应时间 0.35s
        sizeSpring = CriticalDampedSpring2D(initialValue: .zero, responseTime: 0.35, maxVelocity: 800)
        // 二阶跟随弹簧(取代出口限速):位置 0.35s、zoom(log) 0.45s,maxVelocity 不限(惯性自限)
        cropCenterSpring = CriticalDampedSpring2D(initialValue: .zero, responseTime: 0.35)
        cropZoomSpring   = CriticalDampedSpring(initialValue: 0, responseTime: 0.45)
    }

    // MARK: - 公共 API
    func setOutputSize(_ size: CGSize) { cfg.outputSize = size }

    func getTunables() -> Tunables {
        Tunables(
            deadZoneW: cfg.deadZone.width, deadZoneH: cfg.deadZone.height,
            natFreqHzX: cfg.natFreqHzX, natFreqHzY: cfg.natFreqHzY,
            damping: cfg.damping, softZoneGain: cfg.softZoneGain,
            maxVelPxPerSec: cfg.maxVelPxPerSec, maxAccPxPerSec2: cfg.maxAccPxPerSec2,
            maxZoom: cfg.maxZoom, zoomDeadband: cfg.zoomDeadband,
            maxZoomChangePerSec: cfg.maxZoomChangePerSec,
            maxZoomInPerSec: cfg.maxZoomInPerSec,
            maxZoomOutPerSec: cfg.maxZoomOutPerSec,
            targetWidthLower: cfg.targetWidthRange.lowerBound,
            targetWidthUpper: cfg.targetWidthRange.upperBound,
            microMovePx: cfg.microMovePxOut, detInterval: CGFloat(cfg.detectIntervalFrames),
            adaptiveEnabled: cfg.adaptiveEnabled,
            jitterLowPx: cfg.jitterLowPx, jitterHighPx: cfg.jitterHighPx
        )
    }

    func updateTunables(_ t: Tunables) {
        let lower = max(0.30, min(t.targetWidthLower, 0.90))
        let upper = max(lower + 0.01, min(t.targetWidthUpper, 0.95))
        cfg.deadZone = CGSize(width: max(0, min(t.deadZoneW, 0.20)),
                              height: max(0, min(t.deadZoneH, 0.25)))
        cfg.natFreqHzX = max(0.2, min(t.natFreqHzX, 8))
        cfg.natFreqHzY = max(0.2, min(t.natFreqHzY, 8))
        cfg.damping    = max(0.5, min(t.damping, 1.2))
        cfg.softZoneGain = max(0.5, min(t.softZoneGain, 1.0))
        cfg.maxVelPxPerSec  = max(200, min(t.maxVelPxPerSec, 6000))
        cfg.maxAccPxPerSec2 = max(2000, min(t.maxAccPxPerSec2, 40000))
        cfg.maxZoom = max(1.0, min(t.maxZoom, 5.0))
        cfg.zoomDeadband = max(0.0, min(t.zoomDeadband, 0.10))
        cfg.maxZoomChangePerSec = max(0.05, min(t.maxZoomChangePerSec, 2.0))
        cfg.maxZoomInPerSec = max(0.1, min(t.maxZoomInPerSec, 3.0))
        cfg.maxZoomOutPerSec = max(0.05, min(t.maxZoomOutPerSec, 2.0))
        cfg.targetWidthRange = lower...upper

        cfg.microMovePxOut = max(0, min(t.microMovePx, 12))
        cfg.detectIntervalFrames = max(1, min(Int(round(t.detInterval)), 5))

        cfg.adaptiveEnabled = t.adaptiveEnabled
        cfg.jitterLowPx  = max(0.2, min(t.jitterLowPx, 20))
        cfg.jitterHighPx = max(cfg.jitterLowPx + 0.2, min(t.jitterHighPx, 40))
    }

    func setHardLockEnabled(_ on: Bool) {
        print("⚠️ 硬锁功能已暂时禁用")
    }

    func applyPreset(_ mode: CaptureMode) {
        currentMode = mode

        switch mode {
        case .fitness:
            cfg.maxZoom = 5.0  // 最大 5x（激进档）
            cfg.targetHeightRange = 0.60...0.75
            cfg.zoomNatFreqHz = 2.2           // 降低：更平滑的缩放响应
            cfg.zoomDamping = 1.05            // 提高：更强阻尼
            cfg.zoomMaxVelPerSec = 0.6        // 降低：限制缩放速度
            cfg.zoomMaxAccPerSec2 = 1.5       // 降低：限制缩放加速度
            cfg.targetWidthRange = 0.46...0.54
            cfg.maxZoomInPerSec = 0.8         // 降低
            cfg.maxZoomOutPerSec = 0.6        // 降低
            cfg.maxZoomChangePerSec = 1.0     // 降低
            cfg.zoomChangeThreshold = 0.005   // 提高：忽略更小的缩放变化
            cfg.zoomSmoothAlpha = 0.06        // 降低：更平滑
            cfg.deadZone = CGSize(width: 0.12, height: 0.14)  // 增大死区
            cfg.inPlaceDeadZone = CGSize(width: 0.18, height: 0.22)
            cfg.microMovePxOut = 8.0          // 提高：忽略更多微小移动
            cfg.jitterThreshold = 5.0         // 提高：更强抖动抑制
            cfg.zoomDeadband = 0.015          // 提高：缩放死区
            cfg.minMovementPx = 1.0           // 提高
            cfg.natFreqHzX = 2.0              // 降低：更平滑的平移
            cfg.natFreqHzY = 2.2              // 降低
            cfg.damping = 1.02                // 提高：更强阻尼
            cfg.velocityDamping = 0.90        // 降低：更快衰减速度
            cfg.positionFilterAlpha = 0.12    // 降低：更平滑的位置滤波
            cfg.jitterLowPx = 4.0             // 提高
            cfg.jitterHighPx = 15.0           // 提高
            cfg.positionStableThreshold = 0.008
            cfg.aspectChangeThreshold = 0.15
            cfg.inPlaceDetectionFrames = 15
            cfg.preInPlaceDetectionFrames = 3
            cfg.preInPlaceThreshold = 0.005

        case .dance:
            cfg.maxZoom = 1.5
            cfg.targetHeightRange = 0.55...0.70
            cfg.zoomNatFreqHz = 3.5
            cfg.zoomDamping = 0.95
            cfg.zoomMaxVelPerSec = 1.5
            cfg.zoomMaxAccPerSec2 = 3.5
            cfg.targetWidthRange = 0.40...0.45
            cfg.maxZoomInPerSec = 2.0
            cfg.maxZoomOutPerSec = 1.8
            cfg.maxZoomChangePerSec = 2.5
            cfg.zoomChangeThreshold = 0.001
            cfg.zoomSmoothAlpha = 0.18
            cfg.deadZone = CGSize(width: 0.05, height: 0.06)
            cfg.inPlaceDeadZone = CGSize(width: 0.12, height: 0.15)
            cfg.microMovePxOut = 4.0
            cfg.jitterThreshold = 2.5
            cfg.minMovementPx = 0.3
            cfg.zoomDeadband = 0.006
            cfg.natFreqHzX = 3.5
            cfg.natFreqHzY = 3.7
            cfg.damping = 0.90
            cfg.velocityDamping = 0.96
            cfg.positionFilterAlpha = 0.30
            cfg.positionStableThreshold = 0.006
            cfg.aspectChangeThreshold = 0.20
            cfg.inPlaceDetectionFrames = 20
            cfg.preInPlaceDetectionFrames = 4
            cfg.preInPlaceThreshold = 0.004
        }

        setupKalmanFilters()
        setupSprings()
        zoomController.setMaxZoom(cfg.maxZoom)
    }

    // MARK: - 主流程（向后兼容：单帧）
    func process(pixelBuffer: CVPixelBuffer, pts: CMTime) -> FollowResult {
        return process(wideFrame: pixelBuffer, telephotoFrame: nil, pts: pts)
    }

    // MARK: - 主流程（双帧：广角 + 长焦）
    func process(wideFrame: CVPixelBuffer, telephotoFrame: CVPixelBuffer?, pts: CMTime) -> FollowResult {
        frameCount += 1
        sensorW = CGFloat(CVPixelBufferGetWidth(wideFrame))
        sensorH = CGFloat(CVPixelBufferGetHeight(wideFrame))

        let now = Date()
        // 改动4:稳住 dt —— 上下钳 + 短 EMA(不加新滤波层,只平滑这一个值;live/回放共用)
        let rawDt = now.timeIntervalSince(lastTime)
        lastTime = now
        let clampedDt = min(max(rawDt, dtMin), dtMax)
        smoothedDt = smoothedDt * (1 - dtSmoothAlpha) + clampedDt * dtSmoothAlpha
        let dt = smoothedDt
        dbgRawDtMs = rawDt * 1000   // 整合 HUD 用
        if logDtForTuning {
            print(String(format: "⏱dt raw=%.1f clamped=%.1f smoothed=%.1f ms",
                         rawDt * 1000, clampedDt * 1000, smoothedDt * 1000))
        }

        // 阶段计时（ms）：供 HUD 显示
        var msRect = 0.0, msPose = 0.0, msRender = 0.0

        // ========== 1. 人体检测：矩形优先（位置），骨骼辅助（缩放/显示）==========
        if frameCount % max(1, cfg.detectIntervalFrames) == 0 {

            // 检测降采样：Vision 只看长边 720 的小图（坐标归一化，不影响后续与渲染）
            let detPB = downscaledForDetection(wideFrame) ?? wideFrame

            #if DEBUG
            // 检测输入规格诊断:wide 帧尺寸变化时才记一次(便宜)。看 wide 到底变不变、Vision 实吃多大。
            if Int(sensorW) != lastDetW || Int(sensorH) != lastDetH {
                lastDetW = Int(sensorW); lastDetH = Int(sensorH)
                let tw = telephotoFrame.map { CVPixelBufferGetWidth($0) } ?? 0
                let th = telephotoFrame.map { CVPixelBufferGetHeight($0) } ?? 0
                dbgDetSpec = String(format: "wide=%dx%d tele=%dx%d →Vision=%dx%d out=%dx%d",
                                    Int(sensorW), Int(sensorH), tw, th,
                                    CVPixelBufferGetWidth(detPB), CVPixelBufferGetHeight(detPB),
                                    Int(cfg.outputSize.width), Int(cfg.outputSize.height))
                print("🔬 DET " + dbgDetSpec)
            }
            #endif

            // Step A: 人体检测 —— 锁定时走 detectHuman(多人锁定:findTarget→Kalman→颜色校验),
            // 未锁定/没找到则内部回退 detectHumanRectFallback(与卡0一致)。返回类型 (CGRect, conf) 不变 → 下游不动。
            var rectDetected = false
            let _tRect = CACurrentMediaTime()
            // ① pose 去重:帧入口只跑一次 VNDetectHumanBodyPose,缓存 observations 供 Step A(gate/诊断)
            // + Step B(骨骼)共用 → 消除同帧同 detPB 的 3× 重复检测。放在 _tRect 后 → 这唯一一次检测计入 rect。
            PersonIdentifier.shared.beginFramePose(pb: detPB, pts: pts)
            // searchMode:仅 .searching 时开(rect 并源 + 单人降门找回);其余状态用常规严格匹配
            let _searchMode: Bool = { if case .searching = lockState { return true }; return false }()
            let _rectResult = detectHuman(pb: detPB, wide: wideFrame, dt: dt, searchMode: _searchMode)
            msRect = (CACurrentMediaTime() - _tRect) * 1000
            dbgRectConf = -1; dbgRectBoxDelta = 0   // 取证:本帧默认(rect 没返回时即此)
            if let (rect, conf) = _rectResult {
                dbgRectConf = conf   // 取证:即使无门也记 rect 返回框的 conf
                dbgRectBoxDelta = dbgPrevRectBox.map { hypot(rect.midX - $0.midX, rect.midY - $0.midY) / max(sensorW, 1) } ?? 0
                dbgPrevRectBox = rect
                rawBox = rect
                confidence = conf
                missCount = 0
                detFrameCount += 1
                rectDetected = true

                // 缩放始终基于矩形高度（稳定、一致）
                lastHeightRatio = rect.height / sensorH
            }

            // Step B: 骨骼检测 —— 判断"人在干什么"（姿态分析 + 黄框显示）
            // 锁定中:用「最接近锁定框(rawBox=你)的 pose」喂 zoom/锚点,爹的 pose 不污染构图。
            let _tPose = CACurrentMediaTime()
            let _matchBox = PersonIdentifier.shared.isLocked ? rawBox : nil
            let _poseResult = detectPose(pb: detPB, matchingBox: _matchBox)
            msPose = (CACurrentMediaTime() - _tPose) * 1000
            if let pose = _poseResult {
                lastPoseObservation = pose
                lastTightBoxIsFullBody = tightBoxIsFullBody(pose)   // 改动2:本帧框是否完整全身

                // 骨骼紧贴框用于显示（黄框）—— 应用 EMA 平滑
                if let tightBox = getTightBoxFromPose(pose) {
                    lastTightBox = tightBox

                    // EMA 平滑：减少黄框抖动
                    if let prev = smoothedTightBox {
                        let alpha = tightBoxSmoothAlpha
                        smoothedTightBox = CGRect(
                            x: prev.origin.x + alpha * (tightBox.origin.x - prev.origin.x),
                            y: prev.origin.y + alpha * (tightBox.origin.y - prev.origin.y),
                            width: prev.width + alpha * (tightBox.width - prev.width),
                            height: prev.height + alpha * (tightBox.height - prev.height)
                        )
                    } else {
                        smoothedTightBox = tightBox
                    }
                }

                // 缩放主测量：躯干高（肩中点→髋中点投影/画面高）。刚体，抗原地动作、低噪声。
                // 经测量预处理层（门控→突变拒绝→小窗中值）写入 lastTorsoRatio；
                // 缺帧/低置信/离群时保留上一帧值 → ratio 不突变。
                ingestTorsoMeasurement(pose)
            } else {
                lastPoseObservation = nil
                dbgPoseValid = false             // 取证:pose 没检到 → 四点门当然没过
                lastTightBoxIsFullBody = false   // 改动2:无骨骼 → 不启用不出框钳位(避免误钳)
                // 骨骼失败不影响缩放：lastTorsoRatio 保留上一帧值，无骨骼则由调用方回退矩形高
            }

            // Step C: 丢失计数(降级为纯日志计数,不再驱动清空——清空移到 LOST 转移动作 1.4)
            if !rectDetected { missCount += 1 }

            // ===== 三态锁定状态机:唯一权威写入点(下游只读 lockState,别处不许写)=====
            // identityMatched:锁定时 detectHuman 非nil ⟺ findTarget 命中(Part2 已堵 fallback,非nil只可能是身份命中)
            advanceLockState(identityMatched: (_rectResult != nil))

            // ===== 【方案B·刀3】镜头仲裁·影子模式(单一权威下游,只读 lockState)=====
            // 每帧组装输入调 decide,仅产出 决策日志+HUD;command 不驱动设备(a3ba32d 钳死仍拦着,刀4 才放行)。
            // decide 无 app 侧副作用 → build 后行为与刀1 逐帧等同。
            let _lensNow = CACurrentMediaTime()
            let _lensCenter: CGPoint? = _rectResult.map { CGPoint(x: $0.0.midX - 0.5, y: $0.0.midY - 0.5) }  // 归一→wide系(原点=中心)
            if let c = _lensCenter, let p = lensShadowPrevCenter, dt > 0 {
                // 影子速度:锁定中心帧间位移 EMA(影子模式自算;刀4 评估换预测速度估计)
                let v = hypot(c.x - p.x, c.y - p.y) / CGFloat(dt)
                lensShadowVel = 0.7 * lensShadowVel + 0.3 * v
            }
            if _lensCenter != nil { lensShadowPrevCenter = _lensCenter }
            let _lensOut = lensArbiter.decide(LensArbiterInput(
                zoomReq: zoom, lockedCenter: _lensCenter, centerVel: lensShadowVel,
                stateTag: dbgStateTag(), tier1: CameraEngine.currentTier1,
                deviceZoom: CameraEngine.lastSelectedDeviceZoom), at: _lensNow)
            if _lensOut.command != .none {
                // 影子日志(可对答案):帧号/指令/触发线/Z_total/中心/速度/状态/Tier/距上次间隔。print+落盘。
                let gap = lensShadowLastCmdAt < 0 ? "首次" : String(format: "%.1fs", _lensNow - lensShadowLastCmdAt)
                let cstr = _lensCenter.map { String(format: "(%.3f,%.3f)", $0.x, $0.y) } ?? "nil"
                let msg = String(format: "🎯 LENS-SHADOW f%d cmd=%@ 因=[%@] Z=%.2f c=%@ vel=%.3f tag=%@ tier1=%@ 距上次=%@",
                                 frameCount, "\(_lensOut.command)", _lensOut.reason, zoom, cstr,
                                 lensShadowVel, dbgStateTag(), CameraEngine.currentTier1 ? "Y" : "N", gap)
                print(msg); PerfFileLog.shared.line(msg)
                lensShadowLastCmdAt = _lensNow
            }
            dbgLensShadow = String(format: "LENS影子 %@ dz=%@ cd=%.1f Z=%.2f",
                                   _lensOut.lens.rawValue, _lensOut.inDeadzone ? "Y" : "N",
                                   lensArbiter.cooldownRemaining(at: _lensNow), zoom)

            // 日志
            if frameCount % 30 == 0 {
                let hr = lastHeightRatio ?? -1
                let poseOK = lastPoseObservation != nil
                print("🔍 rect=\(rectDetected ? "✓" : "✗") pose=\(poseOK ? "✓" : "✗") miss=\(missCount) conf=\(String(format: "%.0f%%", confidence * 100)) h=\(String(format: "%.0f%%", hr * 100)) zoom=\(String(format: "%.2f", zoom))x")
            }
        }

        // 每帧都衰减 confidence（不只是检测帧）
        if rawBox == nil {
            confidence = max(0, confidence - 0.05)  // 每帧衰减 5%
        }

        // stableBox 维护：有检测时跟踪，无检测时清除
        if let rb = rawBox {
            // 有人：更新 stableBox
            if stableBox == nil {
                let centerBox = CGRect(
                    x: sensorW/2 - rb.width/2,
                    y: sensorH/2 - rb.height/2,
                    width: rb.width,
                    height: rb.height
                )
                stableBox = stabilize(previous: centerBox, target: rb, dt: CGFloat(dt))
            } else {
                stableBox = stabilize(previous: stableBox!, target: rb, dt: CGFloat(dt))
            }
        } else {
            // 无人（rawBox 已被清除）：清除 stableBox，触发缩放回 1x
            stableBox = nil
        }

        /* ───── 注掉:自动 shot 分类器(display-only)。zoomMode 恒 .fixed 时它本就不喂取景,
           注掉只是停掉每帧空转 + 断掉「Talking Head/景别」标签数据源(预期为空)。
           framingOffset 保持 .zero,取景 = fixed 全身,行为不变。可逆:取消本段注释即恢复。
        // ===== 智能构图系统 =====
        // 1. 动作分类
        let actionState = actionClassifier.update(pose: lastPoseObservation)

        // 2. 景别决策
        let instruction = shotDecider.update(action: actionState, dt: CGFloat(dt))

        // 3. 智能模式下应用景别指令
        if zoomMode == .intelligent && stableBox != nil {
            applyInstruction(instruction, dt: CGFloat(dt))
            framingOffset = instruction.framingOffset
        }

        // Debug 日志
        if frameCount % 60 == 0 && zoomMode == .intelligent {
            let (shotType, state, progress) = shotDecider.getCurrentState()
            print("🎬 智能构图: action=\(actionState.rawValue) shot=\(shotType.rawValue) state=\(state.rawValue) progress=\(String(format: "%.0f%%", progress * 100))")
        }
           ───── 注掉结束 ───── */

        // 固定 AR + 变焦（含原地运动检测）
        let crop = computeCropRect(dt: CGFloat(dt))
        lastCropRect = crop

        // 自适应阻尼/频率
        updateAdaptiveDamping(crop: crop)

        // ========== 多摄切换：选择镜头 ==========
        let personCenter = CGPoint(
            x: (stableBox?.midX ?? sensorW/2) / sensorW,
            y: (stableBox?.midY ?? sensorH/2) / sensorH
        )

        let selection = cameraSelector.select(
            equivalentZoom: zoom,
            personCenter: personCenter
        )
        currentCamera = selection.camera
        currentDigitalCrop = selection.digitalCrop

        // 选择帧源 + 计算裁切
        let frameToUse: CVPixelBuffer
        let cropForRender: CGRect

        if selection.camera == .telephoto, let teleFrame = telephotoFrame {
            frameToUse = teleFrame

            // 转换坐标到长焦视角
            let teleCenter = cameraSelector.convertToTelephoto(personCenter)
            let teleSensorW = CGFloat(CVPixelBufferGetWidth(teleFrame))
            let teleSensorH = CGFloat(CVPixelBufferGetHeight(teleFrame))
            let centerRect = CGRect(
                x: teleCenter.x * teleSensorW - (stableBox?.width ?? 100)/2,
                y: teleCenter.y * teleSensorH - (stableBox?.height ?? 200)/2,
                width: stableBox?.width ?? 100,
                height: stableBox?.height ?? 200
            )

            // 用长焦的 sensorSize 重新计算 crop
            let teleCrop = computeFinalCropRect(
                zoom: selection.digitalCrop,
                center: centerRect,
                ar: cfg.outputSize.height / cfg.outputSize.width
            )
            cropForRender = teleCrop

            if frameCount % 30 == 0 {
                print("📷 长焦: digitalCrop=\(String(format: "%.2f", selection.digitalCrop)) teleCenter=(\(String(format: "%.2f", teleCenter.x)), \(String(format: "%.2f", teleCenter.y)))")
            }
        } else {
            frameToUse = wideFrame
            cropForRender = crop
        }

        let _tRender = CACurrentMediaTime()
        let (cg, ciScaled, recPB) = renderCrop(from: frameToUse, crop: cropForRender)
        msRender = (CACurrentMediaTime() - _tRender) * 1000

        let fps = dt > 0 ? 1.0/dt : 0

        return FollowResult(
            fps: fps, zoom: zoom, confidence: confidence,
            rawBox: rawBox,
            stableBox: smoothedTightBox ?? stableBox,
            cropRect: cropForRender, previewCG: cg, ciScaled: ciScaled, previewPB: recPB,
            pts: pts, sensorSize: CGSize(width: sensorW, height: sensorH),
            msRect: msRect, msPose: msPose, msRender: msRender
        )
    }

    // 重置跟踪状态
    // ===== 三态状态机推进(唯一权威写入点)=====
    private func advanceLockState(identityMatched: Bool) {
        let now = CACurrentMediaTime()
        guard PersonIdentifier.shared.isLocked else {
            if lockState != .unlocked { lockState = .unlocked }
            return
        }
        if identityMatched {
            var elapsed: TimeInterval = 0
            if case .searching(let since) = lockState { elapsed = now - since }
            let wasSearching: Bool = { if case .searching = lockState { return true }; return false }()
            let wasUnlocked = (lockState == .unlocked)
            lockState = .locked
            if wasSearching { reacqLockedAt = now }   // ⑤:记找回时刻,开启 2s 找回冷却(旋转门另一半)
            #if DEBUG
            let pi = PersonIdentifier.shared
            if wasSearching {
                let via = pi.dbgSrcMerged ? "P+R" : "pose"   // 并源池标记(chosen 精确源不追,近似)
                let solo = (pi.dbgCurThresh <= pi.soloMatchThreshold + 0.001) ? "Y" : "N"
                print(String(format: "🔍 STATE searching→locked @f%d (reacquired %.1fs, cont=%.2f, via=%@, solo=%@)",
                             frameCount, elapsed, pi.dbgCurCont, via, solo))
                setStateEvent(String(format: "RELOCK %.2f", pi.dbgCurCont), now)
            } else if wasUnlocked {
                print("🔒 STATE unlocked→locked @f\(frameCount)")
                setStateEvent("LOCK", now)
            }
            #endif
        } else {
            switch lockState {
            case .searching(let since):
                #if DEBUG
                dbgSearchCandSeen += PersonIdentifier.shared.lastCandidateCount   // 累计本轮看过的候选
                #endif
                if now - since > searchTimeoutSec {
                    #if DEBUG
                    print(String(format: "👻 STATE searching→lost @f%d (timeout %.1fs, totalCandidatesSeen=%d)",
                                 frameCount, searchTimeoutSec, dbgSearchCandSeen))
                    setStateEvent("LOST", now)
                    #endif
                    performLostTransition()
                } else {
                    // 继续 searching → 不清空 → rawBox 保持旧值 → spring 冻结(1.3)
                    #if DEBUG
                    // Part 4.5 搜索心跳:每 30 帧一行,看已搜多久/候选数/最佳被拒分(不改状态)
                    if frameCount % 30 == 0 {
                        let pi = PersonIdentifier.shared
                        print(String(format: "🔍 SEARCHING %.1fs candidates=%d bestCont=%.2f bestColor=%.2f",
                                     now - since, pi.lastCandidateCount, pi.dbgBestRejectCont, pi.dbgBestRejectColor))
                    }
                    #endif
                }
            case .locked:
                // ⑤ 找回冷却:刚找回 <reacqCooldownSec 内,禁止再进 SEARCHING → 保持 locked 冻结(coast),旋转门关闭
                if now - reacqLockedAt < reacqCooldownSec {
                    #if DEBUG
                    if frameCount % 30 == 0 {
                        print(String(format: "🔒 REACQ-COOLDOWN 保持 locked(距上次找回 %.1fs<%.0fs,不进 searching)", now - reacqLockedAt, reacqCooldownSec))
                    }
                    #endif
                    break
                }
                lockState = .searching(since: now)
                #if DEBUG
                dbgSearchCandSeen = PersonIdentifier.shared.lastCandidateCount   // 新一轮 searching 起点
                print("🔒 STATE locked→searching @f\(frameCount) (findTarget nil, candidates=\(PersonIdentifier.shared.lastCandidateCount))")
                setStateEvent("SEARCH", now)
                #endif
            default:
                break
            }
        }
    }

    /// LOST 一次性转移(1.4):① 清空(=原 :600 组)→ 无人分支接管回全景;② unlock → unlocked → 下帧 auto-lock 重锁(lock() 重建颜色模板)
    private func performLostTransition() {
        rawBox = nil
        lastHeightRatio = nil
        lastTorsoRatio = nil
        lastFedRatio = nil
        torsoMedianBuf.removeAll()
        torsoOutlierStreak = 0
        torsoLostFrames = 0
        lastTightBox = nil
        smoothedTightBox = nil
        lastPoseObservation = nil
        hipHistory.removeAll()
        centerHistory.removeAll()
        hipBasedInPlace = false
        hipStableFrames = 0
        PersonIdentifier.shared.unlock()
        lockState = .unlocked
        #if DEBUG
        print("🔒 STATE lost→unlocked @f\(frameCount) (auto-relock next frame, newTemplate=Y)")
        #endif
    }

    #if DEBUG
    private func setStateEvent(_ s: String, _ now: TimeInterval) {
        dbgStateEvent = s; dbgStateEventUntil = now + 3.0
    }

    /// Part 5 状态机 HUD 行:badge + cont/thr + 候选/源 + 最近事件(下游只读 lockState)
    func dbgStateLine() -> String {
        let pi = PersonIdentifier.shared
        let now = CACurrentMediaTime()
        let badge: String
        switch lockState {
        case .unlocked:             badge = "UNLOCKED"
        case .locked:               badge = "LOCKED"
        case .searching(let since): badge = String(format: "SEARCHING %.1f/%.1fs", now - since, searchTimeoutSec)
        case .lost:                 badge = "LOST"
        }
        let src = pi.dbgSrcMerged ? "P+R" : "P"
        let evt = (now < dbgStateEventUntil && !dbgStateEvent.isEmpty) ? " ⚑\(dbgStateEvent)" : ""
        return String(format: "%@  cont=%.2f/thr=%.2f  cand=%d src=%@%@",
                      badge, pi.dbgCurCont, pi.dbgCurThresh, pi.lastCandidateCount, src, evt)
    }

    /// Part 5 状态色标:L=绿 S=黄 X=红 U=灰(view 映射颜色)
    func dbgStateTag() -> String {
        switch lockState {
        case .unlocked:  return "U"
        case .locked:    return "L"
        case .searching: return "S"
        case .lost:      return "X"
        }
    }
    #endif

    func resetTrackingState() {
        lockState = .unlocked
        centerHistory.removeAll()
        aspectRatioHistory.removeAll()
        isDoingExerciseInPlace = false
        wasInPlace = false
        positionStableFrames = 0
        lockedZoom = 0
        lockedCenter = nil
        // 改B:运行中重置【不】置 prevCropValid=false → 不 snap,由 slewGate 限速回到新目标(只冷启动首帧才瞬移)
        poseAnchorValid = false   // 重置 pose coast,避免用上一段的陈旧 pose 锚
        poseLostFrames = 0
        lastFilteredX = 0
        lastFilteredY = 0
        lastVelX = 0
        lastVelY = 0
        preInPlaceFrames = 0
        zoomFrozen = false
        zoom = 1.0
        motionPredictor.reset()
        kalmanX = nil
        kalmanY = nil
        kalmanW = nil
        kalmanH = nil
        hipHistory.removeAll()
        hipBasedInPlace = false
        hipStableFrames = 0
        lastPoseObservation = nil
        lastTightBox = nil
        smoothedTightBox = nil
        lastHeightRatio = nil
        lastFedRatio = nil

        // 重置变焦控制器 + 位置/尺寸弹簧
        zoomController.reset(toZoom: 1.0)
        positionSpring?.reset(to: .zero)
        sizeSpring?.reset(to: .zero)
        cropSpringValid = false   // 重新检测时 crop 弹簧 reset 到新 target,不从旧位置缓动

        // 重置智能构图系统
        actionClassifier.reset()
        shotDecider.reset()
        framingOffset = .zero
        smoothedFramingOffset = .zero
    }

    // MARK: - 渲染
    // 刀1:录制开关(CameraViewModel 起停录制时置);仅录制中才多渲一份 CVPixelBuffer,非录制零新增。
    var isRecordingActive = false
    // 刀1:录制用像素缓冲池(outputSize 变即重建)。renderCrop 直渲进池 buffer,Recorder 直吃,免 CGContext.draw 软 blit。
    private var recPool: CVPixelBufferPool?
    private var recPoolSize: CGSize = .zero
    private func dequeueRecPixelBuffer() -> CVPixelBuffer? {
        let target = cfg.outputSize
        if recPool == nil || recPoolSize != target {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(target.width),
                kCVPixelBufferHeightKey as String: Int(target.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferCGImageCompatibilityKey as String: true
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
            recPool = pool
            recPoolSize = target
        }
        guard let pool = recPool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        return pb
    }

    func renderCrop(from pixelBuffer: CVPixelBuffer, crop: CGRect) -> (CGImage?, CIImage?, CVPixelBuffer?) {
        let ciSrc = CIImage(cvPixelBuffer: pixelBuffer)
        let ciCrop = CGRect(x: crop.minX,
                            y: sensorH - crop.maxY,
                            width: crop.width,
                            height: crop.height)

        let ciBounds = CGRect(x: 0, y: 0, width: sensorW, height: sensorH)
        let capped = ciCrop.intersection(ciBounds)

        // 统一算出 scaled(两分支),下方公共尾:显示 createCGImage(不变)+ 录制时渲 pixelBuffer。
        let scaled: CIImage
        if capped.isNull || capped.width < 4 || capped.height < 4 {
            let sx = cfg.outputSize.width  / sensorW
            let sy = cfg.outputSize.height / sensorH
            scaled = ciSrc.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        } else {
            let cropped = ciSrc.cropped(to: capped)
            let moved   = cropped.transformed(by: CGAffineTransform(translationX: -capped.origin.x, y: -capped.origin.y))
            let sx = cfg.outputSize.width  / capped.width
            let sy = cfg.outputSize.height / capped.height
            scaled = moved.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        }

        let outRect = CGRect(origin: .zero, size: cfg.outputSize)
        // 刀2:显示 + 录制吃同一个 CVPixelBuffer,砍掉 createCGImage(GPU 渲染 + CPU 回读)。
        // 每帧 ciContext.render(scaled, to: pb)——GPU 直渲进池 buffer,**无 CPU 回读**(非录制也受益)。
        if let pb = dequeueRecPixelBuffer() {
            ciContext.render(scaled, to: pb, bounds: outRect, colorSpace: CGColorSpaceCreateDeviceRGB())
            return (nil, scaled, pb)
        }
        // 兜底(池创建失败等异常):退回 createCGImage 一帧,画面不断。
        let cg = ciContext.createCGImage(scaled, from: outRect)
        return (cg, scaled, nil)
    }

    // MARK: - Helpers
    func clamp<T: Comparable>(_ v: T,_ a: T,_ b: T) -> T { max(a, min(b, v)) }
    func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
    func sensorRect() -> CGRect { CGRect(x: 0, y: 0, width: sensorW, height: sensorH) }

    func smoothStep(_ x: CGFloat, _ edge0: CGFloat, _ edge1: CGFloat) -> CGFloat {
        let t = clamp((x - edge0) / (edge1 - edge0), 0, 1)
        return t * t * (3 - 2 * t)
    }

    func iouRect(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        if inter.isNull { return 0 }
        let i = inter.width * inter.height
        let u = a.width*a.height + b.width*b.height - i
        return u > 0 ? i/u : 0
    }
}

// 别名：让 UI 可以用更直观的命名，不改引擎内部字段
extension TrackingController.Tunables {
    var smoothFactor: CGFloat {
        get { damping }
        set { damping = newValue }
    }
    var maxMoveSpeedPxPerSec: CGFloat {
        get { maxVelPxPerSec }
        set { maxVelPxPerSec = newValue }
    }
    var maxAccelPxPerSec2: CGFloat {
        get { maxAccPxPerSec2 }
        set { maxAccPxPerSec2 = newValue }
    }
}

// MARK: - 向后兼容别名
typealias FollowEngine = TrackingController
