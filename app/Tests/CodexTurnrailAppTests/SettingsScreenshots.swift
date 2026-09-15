import AppKit
import CodexTurnrailCore
import Foundation
import SwiftUI
import Testing

@testable import CodexTurnrailApp

/// Opt-in rendering of the production views using isolated, credential-free demo accounts.
@MainActor
struct SettingsScreenshots {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["TURNRAIL_SCREENSHOT_DIRECTORY"] != nil))
  func exportSettingsScreenshots() async throws {
    let outputPath = try #require(
      ProcessInfo.processInfo.environment["TURNRAIL_SCREENSHOT_DIRECTORY"])
    try #require(outputPath.hasPrefix("/"))
    let output = URL(filePath: outputPath)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AccountRegistryStore(rootURL: root)
    var state = try store.loadOrInitialize()
    for (email, plan) in [
      ("work@example.com", ChatGPTPlan.team),
      ("personal@example.com", .pro),
      ("side-project@example.com", .pro),
    ] {
      state = try store.registerAccount(
        identity: ChatGPTAccountIdentity(email: email, planType: plan), to: state)
    }
    let rule = DirectoryAccountRule(
      id: UUID(), directory: "/Projects/work", accountIDs: state.accounts.map(\.id))
    state = try store.updateRouting(
      AccountRoutingConfiguration(defaultAccountIDs: [], directoryRules: [rule]), in: state)
    let accounts = state.accounts
    let resetData = Data(
      #"{"availableCount":2,"credits":[{"id":"oct-5","resetType":"codexRateLimits","status":"available","grantedAt":1788883200,"expiresAt":1791214500,"title":"Full reset"},{"id":"oct-4","resetType":"codexRateLimits","status":"available","grantedAt":1788796800,"expiresAt":1791133320,"title":"Full reset"}]}"#
        .utf8)
    let resets = try JSONDecoder().decode(AccountResetCredits.self, from: resetData)
    for (index, account) in accounts.enumerated() {
      let home = try store.ensureAuthHome(forAccountID: account.id)
      let data = try JSONSerialization.data(withJSONObject: [
        "schemaVersion": 1, "accountId": account.id.uuidString,
        "startedAtUnixSeconds": 1_789_502_880 + index * 1800,
      ])
      try data.write(to: home.deletingLastPathComponent().appending(path: "last-used.json"))
    }
    let model = TurnrailViewModel(
      engineURLResult: .success(URL(filePath: "/unused-screenshot-engine")),
      registryStoreResult: .success(store),
      commandExecutor: CommandExecutor { _, _, _ in
        throw ScreenshotError.unexpectedOperation
      },
      loginExecutor: AccountLoginExecutor { _ in throw ScreenshotError.unexpectedOperation },
      compatibilityProbe: { _, _ in supportedCompatibilityReport() },
      isApplicationRunning: { false },
      identityReader: AccountIdentityReader { _, home in
        let account = try #require(
          accounts.first {
            $0.id.uuidString.lowercased() == home.deletingLastPathComponent().lastPathComponent
          })
        return try ChatGPTAccountIdentity(email: account.email, planType: account.planType)
      },
      usageReader: AccountUsageReader { _, home in
        let index = try #require(
          accounts.firstIndex {
            $0.id.uuidString.lowercased() == home.deletingLastPathComponent().lastPathComponent
          })
        return AccountRateLimits(
          buckets: [
            AccountRateLimitBucket(
              limitID: "codex", name: nil,
              primary: try AccountRateLimitWindow(
                usedPercent: [100, 66, 30][index], windowDurationMinutes: 10_080,
                resetsAt: Date(
                  timeIntervalSince1970: [1_790_002_500, 1_789_814_340, 1_789_833_780][index])),
              secondary: nil)
          ],
          resetCredits: index == 1
            ? resets : try AccountResetCredits(availableCount: 0, credits: []))
      }
    )
    model.refreshCompatibility()
    model.routingScope = .directory(rule.id)
    await model.refreshAllAuthStatuses()
    for page in [SettingsPage.switchAccount, .accounts] {
      let name = page == .switchAccount ? "switch" : "accounts"
      try render(
        TurnrailSettings(model: model, page: page),
        size: NSSize(width: 1120, height: 740), to: output.appending(path: "\(name).png"))
    }
    try render(
      AccountResetCreditsSheet(account: accounts[1], model: model),
      size: NSSize(width: 460, height: 340), to: output.appending(path: "available-resets.png"))
  }

  private func render(_ content: some View, size: NSSize, to url: URL) throws {
    let application = NSApplication.shared
    let hosting = NSHostingView(
      rootView:
        content
        .environment(\.locale, Locale(identifier: "en_US"))
        .environment(\.timeZone, TimeZone.gmt)
        .environment(\.colorScheme, .dark)
        .environment(\.controlActiveState, .active)
        .frame(width: size.width, height: size.height)
        .background(Color(nsColor: .windowBackgroundColor)))
    hosting.appearance = NSAppearance(named: .darkAqua)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
      backing: .buffered, defer: false)
    window.contentView = hosting
    defer { window.contentView = nil }
    hosting.frame = NSRect(origin: .zero, size: size)
    hosting.layoutSubtreeIfNeeded()
    application.updateWindows()
    let bitmap = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    bitmap.size = size
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: url)
    #expect(png.count > 10_000)
  }

  private enum ScreenshotError: Error { case unexpectedOperation }
}
