import SwiftUI

struct ContentView: View {
    // 父视图持有 VM（只创建一次，避免相机/跟随频繁重建）
    @StateObject private var vm = CameraViewModel()

    var body: some View {
        CameraScreen(vm: vm)
            .preferredColorScheme(.dark)
            .ignoresSafeArea()
    }
}

#Preview {
    ContentView()
}

