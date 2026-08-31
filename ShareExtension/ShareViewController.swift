import UIKit
import UniformTypeIdentifiers
import Foundation

final class ShareViewController: UIViewController {
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let appGroupID = "group.com.weihsiangliao.VideoCompressor"

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        processSharedItem()
    }

    private func setupUI() {
        view.backgroundColor = .systemBackground

        statusLabel.text = "正在儲存影片…"
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0

        spinner.startAnimating()

        let stack = UIStackView(arrangedSubviews: [spinner, statusLabel])
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32)
        ])
    }

    private func processSharedItem() {
        guard
            let item = extensionContext?.inputItems.first as? NSExtensionItem,
            let provider = item.attachments?.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.movie.identifier) })
        else {
            finish(error: "找不到可壓縮的影片")
            return
        }

        provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { [weak self] url, error in
            guard let self else { return }
            guard let url, error == nil else {
                self.finish(error: "讀取影片失敗")
                return
            }

            guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: self.appGroupID) else {
                self.finish(error: "無法存取共享儲存空間")
                return
            }

            let inboxURL = containerURL.appendingPathComponent("Inbox", isDirectory: true)
            let fileExtension = url.pathExtension.isEmpty ? "mov" : url.pathExtension
            let fileName = UUID().uuidString + "." + fileExtension
            let destinationURL = inboxURL.appendingPathComponent(fileName)

            do {
                try FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.copyItem(at: url, to: destinationURL)
            } catch {
                self.finish(error: "無法儲存影片")
                return
            }

            var components = URLComponents()
            components.scheme = "videocompressor"
            components.host = "import"
            components.queryItems = [URLQueryItem(name: "file", value: fileName)]

            DispatchQueue.main.async {
                self.openHostApp(components.url)
            }
        }
    }

    private func openHostApp(_ url: URL?) {
        // iOS often refuses to switch to another app from a system share sheet (Photos'
        // share sheet in particular), so this is best-effort only. Either way, the video
        // is already saved to the shared container — VideoCompressor picks it up itself
        // the next time it becomes active, so completion here isn't required for success.
        guard let url else {
            finish(success: true)
            return
        }
        extensionContext?.open(url) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self?.finish(success: true)
            }
        }
    }

    private func finish(success: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.spinner.stopAnimating()
            self?.statusLabel.text = "已儲存！請切換到「影片壓縮」查看"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                self?.extensionContext?.completeRequest(returningItems: nil)
            }
        }
    }

    private func finish(error message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.spinner.stopAnimating()
            self?.statusLabel.text = message
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self?.extensionContext?.completeRequest(returningItems: nil)
            }
        }
    }
}
