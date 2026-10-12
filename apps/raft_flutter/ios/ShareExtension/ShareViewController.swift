import UIKit
import UniformTypeIdentifiers
import Social

/// Native compose sheet shared by the app-row and Action-list extensions.
final class ShareViewController: SLComposeServiceViewController {
  private var writer: ShareInboxWriter?
  private var text: [String] = []
  private var providers: [NSItemProvider] = []
  private var cancelled = false
  private var prepared = false, sending = false
  private var composeClient: ShareComposeClient?
  private var access: ShareAccessSession?
  private var servers: [[String: Any]] = []
  private var serverId: String?
  private var channels: [ShareDestination] = []
  private var destination: ShareDestination?
  private var targetRevision = 0
  private var task: Task<Void, Never>?
  private let serverItem = SLComposeSheetConfigurationItem()!
  private let channelItem = SLComposeSheetConfigurationItem()!
  private let filesItem = SLComposeSheetConfigurationItem()!

  override func viewDidLoad() {
    super.viewDidLoad()
    title = NSLocalizedString("Share to Raft", comment: "Share extension title")
    placeholder = NSLocalizedString("Add a message…", comment: "Share message")
    serverItem.title = NSLocalizedString("Server", comment: "Share target server")
    serverItem.value = NSLocalizedString("Loading…", comment: "Loading share account")
    serverItem.valuePending = true
    serverItem.tapHandler = { [weak self] in self?.chooseServer() }
    channelItem.title = NSLocalizedString("Conversation", comment: "Share target conversation")
    channelItem.value = NSLocalizedString("Choose a conversation", comment: "Share target")
    channelItem.tapHandler = { [weak self] in self?.chooseConversation() }
    filesItem.title = NSLocalizedString("Attachments", comment: "Share files")
    filesItem.value = "0"
    loadAccounts()
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
      prepared = true
      textView.text = text.joined(separator: "\n")
      filesItem.value = String((try? writer?.preparedFiles().count) ?? 0)
      reloadConfigurationItems()
      validateContent()
      return
    }
    let provider = providers[index]
    // URL/text providers are values, whereas media is copied before the
    // NSItemProvider temporary-file callback returns.
    if provider.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier) {
      provider.loadItem(forTypeIdentifier: UTType.propertyList.identifier, options: nil) { [weak self] value, error in
        guard let self else { return }
        let payload = (value as? [String: Any])?[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any]
        DispatchQueue.main.async {
          guard !self.cancelled else { return }
          guard error == nil, let url = payload?["url"] as? String, url.utf16.count <= 65536 else { self.fail(); return }
          if let title = payload?["title"] as? String, title.utf16.count <= 1000, !title.isEmpty { self.text.append(title) }
          if !self.text.contains(url) { self.text.append(url) }
          self.load(index + 1)
        }
      }
    } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
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

  override func configurationItems() -> [Any]! { [serverItem, channelItem, filesItem] }

  override func isContentValid() -> Bool {
    guard prepared, !cancelled, !sending, destination != nil, composeClient != nil,
          let writer, let files = try? writer.preparedFiles() else { return false }
    let value = contentText ?? ""
    return value.utf16.count <= 65536 && !ShareInboxWriter.unsafeText(value) &&
      (!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty)
  }

  private func loadAccounts() {
    task?.cancel(); composeClient?.cancel(); composeClient = nil
    targetRevision += 1
    task = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "RaftShareKeychainGroup") as? String,
              !group.contains("$("), let account = try ShareSessionVault(accessGroup: group).read() else {
          throw ShareComposeFailure.signIn
        }
        let client = ShareComposeClient(access: account, vault: ShareSessionVault(accessGroup: group))
        self.composeClient = client
        let servers = try await client.servers()
        guard !self.cancelled, !Task.isCancelled else { return }
        self.access = account; self.servers = servers
        let preferred = servers.first { ($0["id"] as? String) == account.preferredServerId }
        self.selectServer(preferred ?? servers.first)
      } catch {
        guard !self.cancelled, !Task.isCancelled else { return }
        self.serverItem.valuePending = false
        self.serverItem.value = NSLocalizedString("Open Raft to sign in", comment: "Share needs account")
        self.reloadConfigurationItems()
        self.showError(error, retry: { [weak self] in self?.loadAccounts() })
      }
    }
  }

  private func selectServer(_ row: [String: Any]?) {
    guard !sending else { return }
    targetRevision += 1
    let revision = targetRevision
    serverId = row?["id"] as? String
    serverItem.valuePending = false
    serverItem.value = row?["name"] as? String ?? NSLocalizedString("Choose a server", comment: "Share target")
    destination = nil; channels = []
    channelItem.value = NSLocalizedString("Choose a conversation", comment: "Share target")
    reloadConfigurationItems(); validateContent()
    guard let serverId, let composeClient else { return }
    channelItem.valuePending = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let rows = try await composeClient.channels(server: serverId)
        guard !self.cancelled, self.serverId == serverId, self.targetRevision == revision else { return }
        self.channels = rows; self.channelItem.valuePending = false
        self.reloadConfigurationItems(); self.validateContent()
      } catch {
        guard !self.cancelled, self.serverId == serverId, self.targetRevision == revision else { return }
        self.channelItem.valuePending = false; self.reloadConfigurationItems()
        self.showError(error, retry: { [weak self] in self?.selectServer(row) })
      }
    }
  }
  private func chooseServer() {
    guard !sending else { return }
    guard !servers.isEmpty else { loadAccounts(); return }
    let available = servers
    let names = available.map { $0["name"] as? String ?? "" }
    let picker = ShareTargetList(title: NSLocalizedString("Server", comment: "Share target"), names: names) { [weak self] index in
      guard let self, available.indices.contains(index) else { return }
      self.popConfigurationViewController()
      self.selectServer(available[index])
    }
    pushConfigurationViewController(picker)
  }
  private func chooseConversation() {
    guard !sending, !channelItem.valuePending else { return }
    let available = channels, revision = targetRevision
    let picker = ShareTargetList(title: NSLocalizedString("Conversation", comment: "Share target"), names: available.map { $0.name }) { [weak self] index in
      guard let self, available.indices.contains(index), self.targetRevision == revision else { return }
      self.destination = available[index]
      self.channelItem.value = self.destination?.name
      self.popConfigurationViewController(); self.reloadConfigurationItems(); self.validateContent()
    }
    pushConfigurationViewController(picker)
  }
  override func didSelectPost() {
    guard isContentValid(), let destination, let writer, let composeClient,
          let files = try? writer.preparedFiles() else { return }
    sending = true
    let value = contentText ?? ""
    textView.isEditable = false; validateContent()
    task = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await composeClient.send(to: destination, text: value, files: files)
        guard !self.cancelled else { return }
        self.cancelled = true; composeClient.cancel(); writer.cancel()
        self.extensionContext?.completeRequest(returningItems: nil)
      } catch {
        guard !self.cancelled else { return }
        self.sending = false; self.textView.isEditable = true; self.validateContent()
        self.showError(error, retry: nil)
      }
    }
  }
  private func showError(_ error: Error, retry: (() -> Void)?) {
    let message: String
    switch error {
    case ShareComposeFailure.signIn:
      message = NSLocalizedString("Open Raft and sign in again, then share. Your login is needed to choose a destination.", comment: "Share account expired")
    case ShareComposeFailure.upload:
      message = NSLocalizedString("An attachment exceeds this server's upload limit or could not be uploaded.", comment: "Share upload failed")
    default:
      message = NSLocalizedString("Could not share. Check your connection and destination, then try again.", comment: "Share failed")
    }
    let alert = UIAlertController(title: NSLocalizedString("Share to Raft", comment: "Share title"), message: message, preferredStyle: .alert)
    if let retry { alert.addAction(UIAlertAction(title: NSLocalizedString("Retry", comment: "Retry sharing"), style: .default) { _ in retry() }) }
    alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "Dismiss error"), style: .cancel))
    present(alert, animated: true)
  }
  private func fail() {
    prepared = false; writer?.cancel(); validateContent()
    showError(ShareComposeFailure.invalidContent, retry: nil)
  }
  override func didSelectCancel() {
    cancelled = true; task?.cancel(); composeClient?.cancel(); writer?.cancel()
    extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
  }
  deinit { task?.cancel(); composeClient?.cancel(); writer?.cancel() }
}

private final class ShareTargetList: UITableViewController, UISearchResultsUpdating {
  let names: [String]
  let selected: (Int) -> Void
  private var indices: [Int] = []
  private let search = UISearchController(searchResultsController: nil)
  init(title: String, names: [String], selected: @escaping (Int) -> Void) {
    self.names = names; self.selected = selected; self.indices = Array(names.indices)
    super.init(style: .insetGrouped); self.title = title
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
  override func viewDidLoad() {
    super.viewDidLoad()
    tableView.rowHeight = 52
    search.searchResultsUpdater = self; search.obscuresBackgroundDuringPresentation = false
    navigationItem.searchController = search
    definesPresentationContext = true
    if names.isEmpty {
      let empty = UILabel(); empty.text = NSLocalizedString("No conversations available", comment: "Share empty targets")
      empty.textAlignment = .center; empty.numberOfLines = 0; tableView.backgroundView = empty
    }
  }
  func updateSearchResults(for searchController: UISearchController) {
    let query = searchController.searchBar.text ?? ""
    indices = names.indices.filter { query.isEmpty || names[$0].localizedCaseInsensitiveContains(query) }
    tableView.reloadData()
  }
  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { indices.count }
  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
    var content = cell.defaultContentConfiguration(); content.text = names[indices[indexPath.row]]
    cell.contentConfiguration = content; return cell
  }
  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) { selected(indices[indexPath.row]) }
}
