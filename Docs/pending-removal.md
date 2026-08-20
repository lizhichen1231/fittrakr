# 待撤清单

> 登记规则:每条写明「删什么 / 何时删 / 移除自查命令」。删完把该条一并删掉。

- 【画质探针】(登记 2026-08-19,【画质增强·真机试验入口】卡)
  - 删什么:`FitTrackr.1/UI/Debug/QualityProbeView.swift` 整文件 + `CameraScreen.swift` 三处挂点
    (TunerSheet 的 `showQualityProbe` 状态与入口 Section、`.fullScreenCover`、onAppear 的 FTQ_BENCH 分流)+ 本条;
  - 何时删:新 UI 开工时(现有 UI 整体废案,探针随之无处可挂);
  - 移除自查:`grep -rn "画质探针" FitTrackr.1/` 应零命中。
