import UIKit
import UniformTypeIdentifiers

/// Public Share Extension APIs only; saving never opens or sends from Runner.
final class ShareViewController: UIViewController {
  private var writer: ShareInboxWriter?
  private var text: [String] = []
  private var providers: [NSItemProvider] = []
  private var cancelled = false
  private let details = UILabel()
  private let save = UIButton(type: .system)

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    let title = UILabel()
    title.text = NSLocalizedString("Save to Raft", comment: "Share extension title")
    title.font = .preferredFont(forTextStyle: .title2)
    details.numberOfLines = 0
    details.text = NSLocalizedString("Preparing shared content…", comment: "Loading share")
    details.font = .preferredFont(forTextStyle: .body)
    save.setTitle(NSLocalizedString("Save", comment: "Save a share"), for: .normal)
    save.isEnabled = false
    save.addTarget(self, action: #selector(commit), for: .touchUpInside)
    let cancel = UIButton(type: .system)
    cancel.setTitle(NSLocalizedString("Cancel", comment: "Cancel a share"), for: .normal)
    cancel.addTarget(self, action: #selector(close), for: .touchUpInside)
    let stack = UIStackView(arrangedSubviews: [title, details, save, cancel])
    stack.axis = .vertical
    stack.spacing = 24
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
      stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
      save.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
      cancel.heightAnchor.constraint(greaterThanOrEqualToConstant: 48)
    ])
    guard let items = extensionContext?.inputItems as? [NSExtensionItem],
          let group = Bundle.main.object(forInfoDictionaryKey: "RaftAppGroup") as? String else {
      fail(); return
    }
    providers = items.flatMap { $0.attachments ?? [] }
    guard providers.count <= 10 else { fail(); return }
    if providers.isEmpty {
      text = items.compactMap { $0.attributedContentText?.string }
    }
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let prepared = try ShareInboxWriter(root: ShareInboxWriter.directory(group: group))
        DispatchQueue.main.async {
          guard !self.cancelled else { prepared.cancel(); return }
          self.writer = prepared
          self.load(0)
        }
      } catch { DispatchQueue.main.async { if !self.cancelled { self.fail() } } }
    }
  }

  private func load(_ index: Int) {
    guard !cancelled else { return }
    guard index < providers.count else {
      details.text = NSLocalizedString("Saved content will be ready to add to a conversation when you return to Raft. It will not be sent automatically.", comment: "Share confirmation")
      save.isEnabled = true
      return
    }
    let provider = providers[index]
    // URL/text providers are values, whereas media is copied before the
    // NSItemProvider temporary-file callback returns.
    if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
       !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
      provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] value, error in
        guard let self else { return }
        let value = (value as? URL)?.absoluteString ?? (value as? String)
        DispatchQueue.main.async {
          guard !self.cancelled else { return }
          guard error == nil, let value, value.utf16.count <= 65536 else { self.fail(); return }
          self.text.append(value); self.load(index + 1)
        }
      }
    } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
      let writer = self.writer
      provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] value, error in
        guard let self else { return }
        guard error == nil, let url = value as? URL, let writer else {
          DispatchQueue.main.async { if !self.cancelled { self.fail() } }; return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        do {
          let input = try ShareInboxWriter.Input(url)
          self.copy(input, writer: writer, filename: provider.suggestedName ?? url.lastPathComponent,
            mimeType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream",
            index: index, after: { if scoped { url.stopAccessingSecurityScopedResource() } })
        } catch {
          if scoped { url.stopAccessingSecurityScopedResource() }
          DispatchQueue.main.async { if !self.cancelled { self.fail() } }
        }
      }
    } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
      provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { [weak self] value, error in
        guard let self else { return }
        let value = value as? String ?? (value as? NSAttributedString)?.string ??
          ((value as? Data).flatMap { $0.count <= 256 * 1024 ? String(data: $0, encoding: .utf8) : nil })
        DispatchQueue.main.async {
          guard !self.cancelled else { return }
          guard error == nil, let value, value.utf16.count <= 65536 else { self.fail(); return }
          self.text.append(value); self.load(index + 1)
        }
      }
    } else if let identifier = provider.registeredTypeIdentifiers.first(where: {
      guard let type = UTType($0) else { return false }
      return type.conforms(to: .data) && !type.conforms(to: .text) && type != .fileURL
    }) {
      let writer = self.writer
      provider.loadFileRepresentation(forTypeIdentifier: identifier) { [weak self] url, error in
        guard let self else { return }
        guard error == nil, let url, let writer else {
          DispatchQueue.main.async { if !self.cancelled { self.fail() } }; return
        }
        do {
          let input = try ShareInboxWriter.Input(url)
          self.copy(input, writer: writer, filename: self.filename(provider: provider, url: url, type: UTType(identifier)),
            mimeType: UTType(identifier)?.preferredMIMEType ?? UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream", index: index)
        } catch {
          DispatchQueue.main.async { if !self.cancelled { self.fail() } }
        }
      }
    } else { fail() }
  }

  private func filename(provider: NSItemProvider, url: URL, type: UTType?) -> String {
    var name = provider.suggestedName ?? url.lastPathComponent
    if (name as NSString).pathExtension.isEmpty,
       let suffix = type?.preferredFilenameExtension ?? (url.pathExtension.isEmpty ? nil : url.pathExtension) {
      name += "." + suffix
    }
    return name
  }

  private func copy(_ input: ShareInboxWriter.Input, writer: ShareInboxWriter,
                    filename: String, mimeType: String, index: Int, after: @escaping () -> Void = {}) {
    DispatchQueue.global(qos: .userInitiated).async {
      defer { after() }
      var success = false
      do { try writer.addFile(input, filename: filename, mimeType: mimeType); success = true }
      catch { }
      DispatchQueue.main.async {
        guard !self.cancelled else { return }
        if success { self.load(index + 1) } else { self.fail() }
      }
    }
  }

  private func fail() {
    writer?.cancel()
    details.text = NSLocalizedString("This share could not be prepared. Use up to 9 files, each no larger than 25 MB, and try again.", comment: "Share error")
    save.isEnabled = false
  }
  @objc private func commit() {
    guard !cancelled, let writer else { return }
    save.isEnabled = false
    do {
      _ = try writer.commit(text: text.isEmpty ? nil : text.joined(separator: "\n"))
      cancelled = true
      extensionContext?.completeRequest(returningItems: nil)
    } catch { fail() }
  }
  @objc private func close() {
    cancelled = true
    writer?.cancel()
    extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
  }
}
