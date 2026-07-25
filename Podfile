platform :ios, '16.0'
use_frameworks!

target 'FitTrackr.1' do
  # 清A(2026-07-26):删 MediaPipeTasksVision——运行时已死(GestureFactory 恒造 VisionHandGesture,
  # MediaPipe 分支被注释),依赖是 123MB 二进制/卡 push/test-host 链接失败的元凶。
  # 源码零改动:import 包在 #if canImport 内,pod 移除后自动短路。清B(删死类/死模型)缓期挂单。

  target 'FitTrackr.1Tests' do
    inherit! :search_paths
  end

  target 'FitTrackr.1UITests' do
  end
end
