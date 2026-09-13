import AppKit
import CodexTurnrailCore
import SwiftUI

@main
struct CodexTurnrailApp: App {
  @NSApplicationDelegateAdaptor(TurnrailApplicationDelegate.self)
  private var applicationDelegate
  @StateObject private var model = TurnrailViewModel()
  @StateObject private var settingsWindowCoordinator = SettingsWindowCoordinator.shared

  var body: some Scene {
    MenuBarExtra {
      TurnrailMenu()
    } label: {
      TurnrailMenuBarLabel(settingsWindowCoordinator: settingsWindowCoordinator)
    }
    .menuBarExtraStyle(.menu)

    Settings {
      TurnrailSettings(model: model)
        .frame(width: 1120, height: 740)
    }
  }
}

@MainActor
private final class TurnrailApplicationDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    SettingsWindowCoordinator.shared.requestOpen()
  }

  func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    SettingsWindowCoordinator.shared.requestOpen()
    return true
  }
}

@MainActor
private final class SettingsWindowCoordinator: ObservableObject {
  static let shared = SettingsWindowCoordinator()

  @Published private(set) var requestID = 0
  private var handledRequestID = 0

  private init() {}

  func requestOpen() {
    requestID += 1
  }

  func consumeRequest(_ requestID: Int) -> Bool {
    guard requestID > handledRequestID else {
      return false
    }
    handledRequestID = requestID
    return true
  }
}

private struct TurnrailMenuBarLabel: View {
  @ObservedObject var settingsWindowCoordinator: SettingsWindowCoordinator
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    Label("Codex Turnrail", systemImage: "arrow.left.arrow.right")
      .onChange(of: settingsWindowCoordinator.requestID, initial: true) {
        _, requestID in
        guard settingsWindowCoordinator.consumeRequest(requestID) else {
          return
        }
        presentSettingsWindow(using: openSettings)
      }
  }
}

@MainActor
private func presentSettingsWindow(using openSettings: OpenSettingsAction) {
  let application = NSApplication.shared
  openSettings()
  application.activate(ignoringOtherApps: true)
  DispatchQueue.main.async {
    application.activate(ignoringOtherApps: true)
    application.windows.first { $0.canBecomeKey }?.makeKeyAndOrderFront(nil)
  }
}

private struct TurnrailMenu: View {
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    Button("Settings") {
      presentSettingsWindow(using: openSettings)
    }
    .keyboardShortcut(",", modifiers: .command)

    Divider()

    Button("Quit") {
      NSApplication.shared.terminate(nil)
    }
  }
}

struct AccountIssueDetailsSheet: View {
  let account: TurnrailAccount
  let issue: TurnrailViewModel.AccountIssue
  let onReauthenticate: () -> Void

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.title2)
          .foregroundStyle(.red)

        VStack(alignment: .leading, spacing: 4) {
          Text(issue.badgeTitle)
            .font(.title3.weight(.semibold))
          Text(account.displayName)
            .foregroundStyle(.secondary)
        }
      }

      Text(issue.summary)

      GroupBox("Error details") {
        ScrollView(.vertical) {
          Text(issue.details)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
        }
        .frame(minHeight: 240)
      }

      HStack {
        Button("Close") {
          dismiss()
        }

        Spacer()

        if issue.canReauthenticate {
          Button("Reauthenticate") {
            onReauthenticate()
          }
          .keyboardShortcut(.defaultAction)
        }
      }
    }
    .padding(20)
    .frame(minWidth: 620, minHeight: 420)
  }
}
