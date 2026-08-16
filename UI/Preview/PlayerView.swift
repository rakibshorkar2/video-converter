import SwiftUI
import AVKit

struct PlayerView: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
            } else {
                ProgressView()
            }
        }
        .task {
            player = AVPlayer(url: url)
        }
        .onAppear {
            player?.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}

struct DocumentOptionsPresenter: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIViewController {
        let host = UIViewController()
        DispatchQueue.main.async {
            let controller = UIDocumentInteractionController(url: url)
            controller.presentOptionsMenu(from: host.view.bounds, in: host.view, animated: true)
        }
        return host
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}