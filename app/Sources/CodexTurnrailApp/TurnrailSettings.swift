import AppKit
import CodexTurnrailCore
import SwiftUI

private enum SettingsPage: String, CaseIterable, Identifiable {
  case switchAccount = "Switch"
  case folders = "Folders"
  case accounts = "Accounts"

  var id: Self { self }

  var symbol: String {
    switch self {
    case .switchAccount: "arrow.left.arrow.right"
    case .folders: "folder"
    case .accounts: "person.crop.circle"
    }
  }

  var title: String {
    self == .switchAccount ? "Switch Account" : rawValue
  }
}

private struct PresentedAccountIssue: Identifiable {
  let account: TurnrailAccount
  let issue: TurnrailViewModel.AccountIssue
  var id: String { issue.id }
}

struct TurnrailSettings: View {
  @ObservedObject var model: TurnrailViewModel
  @State private var page: SettingsPage = .switchAccount
  @State private var expandedFolders: Set<AccountRoutingScope> = [.defaultRule]
  @State private var accountPendingRemoval: TurnrailAccount?
  @State private var folderPendingRemoval: DirectoryAccountRule?
  @State private var presentedAccountIssue: PresentedAccountIssue?
  @State private var showsStatusDetails = false

  var body: some View {
    HStack(spacing: 0) {
      sidebar
      Divider()
      VStack(alignment: .leading, spacing: 24) {
        HStack {
          Text(page.title)
            .font(.system(size: 30, weight: .semibold))
          Spacer()
          pageAction
        }

        switch page {
        case .switchAccount: switchPage
        case .folders: foldersPage
        case .accounts: accountsPage
        }
        Spacer(minLength: 0)
      }
      .padding(28)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(Color(nsColor: .windowBackgroundColor))
    }
    .tint(.blue)
    .task { await model.monitorAccounts() }
    .task { await model.monitorLastUsed() }
    .onAppear { model.refreshApplicationState() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    {
      _ in Task { await model.refreshAllAuthStatuses() }
    }
    .onReceive(
      NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
    ) { _ in Task { await model.refreshAllAuthStatuses() } }
    .onReceive(
      NSWorkspace.shared.notificationCenter.publisher(
        for: NSWorkspace.didLaunchApplicationNotification)
    ) { _ in model.refreshApplicationState() }
    .onReceive(
      NSWorkspace.shared.notificationCenter.publisher(
        for: NSWorkspace.didTerminateApplicationNotification)
    ) { _ in model.refreshApplicationState() }
    .alert("Compatibility", isPresented: $showsStatusDetails) {
      Button("OK", role: .cancel) {}
    } message: {
      if let details = model.statusDetails { Text(details) }
    }
    .alert(
      "Account Error",
      isPresented: Binding(
        get: { model.accountError != nil },
        set: { if !$0 { model.clearAccountError() } }
      )
    ) {
      Button("OK", role: .cancel) { model.clearAccountError() }
    } message: {
      if let message = model.accountError { Text(message) }
    }
    .confirmationDialog(
      "Remove Account?",
      isPresented: Binding(
        get: { accountPendingRemoval != nil },
        set: { if !$0 { accountPendingRemoval = nil } }
      ),
      titleVisibility: .visible,
      presenting: accountPendingRemoval
    ) { account in
      Button("Remove \(account.email)", role: .destructive) {
        model.remove(account: account)
        accountPendingRemoval = nil
      }
      Button("Cancel", role: .cancel) { accountPendingRemoval = nil }
    }
    .confirmationDialog(
      "Remove Folder?",
      isPresented: Binding(
        get: { folderPendingRemoval != nil },
        set: { if !$0 { folderPendingRemoval = nil } }
      ),
      titleVisibility: .visible,
      presenting: folderPendingRemoval
    ) { rule in
      Button("Remove \(folderLabel(rule.directory))", role: .destructive) {
        model.removeRoutingDirectory(id: rule.id)
        expandedFolders.remove(.directory(rule.id))
        folderPendingRemoval = nil
      }
      Button("Cancel", role: .cancel) { folderPendingRemoval = nil }
    }
    .sheet(item: $presentedAccountIssue) { presented in
      AccountIssueDetailsSheet(
        account: presented.account,
        issue: presented.issue,
        onReauthenticate: {
          presentedAccountIssue = nil
          model.reauthenticate(accountID: presented.account.id)
        }
      )
    }
  }

  private var sidebar: some View {
    VStack(spacing: 6) {
      ForEach(SettingsPage.allCases) { item in
        Button {
          page = item
        } label: {
          HStack(spacing: 12) {
            Image(systemName: item.symbol)
              .font(.system(size: 18))
              .frame(width: 24)
            Text(item.rawValue)
              .font(.system(size: 15, weight: page == item ? .semibold : .regular))
            Spacer()
          }
          .padding(.horizontal, 12)
          .frame(height: 42)
          .contentShape(Rectangle())
          .background(
            page == item ? Color.blue.opacity(0.2) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
          )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(page == item ? .isSelected : [])
      }
      Spacer()

    }
    .padding(.horizontal, 12)
    .padding(.top, 24)
    .padding(.bottom, 20)
    .frame(width: 204, height: 740)
    .background(Color(nsColor: .controlBackgroundColor))
    .overlay(alignment: .bottom) {
      TurnrailStatusControls(model: model, showsStatusDetails: $showsStatusDetails)
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
    }
  }

  @ViewBuilder
  private var pageAction: some View {
    switch page {
    case .switchAccount:
      Button {
        Task { await model.refreshAllAuthStatuses() }
      } label: {
        Label("Refresh Usage", systemImage: "arrow.clockwise")
      }
      .disabled(model.isRefreshingAccounts)
    case .folders:
      Button {
        if let id = model.chooseRoutingDirectory(replacing: nil) {
          expandedFolders.insert(.directory(id))
        }
      } label: {
        Label("Add Folder", systemImage: "plus")
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(model.registryLoadError != nil)
    case .accounts:
      Button {
        model.addAccount()
      } label: {
        Label(model.isAddingAccount ? "Signing In" : "Add Account", systemImage: "plus")
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(model.isAddingAccount || model.registryLoadError != nil)
    }
  }

  private var switchPage: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(spacing: 12) {
        Text("Folder")
        Picker("Folder", selection: $model.routingScope) {
          ForEach(model.registryState.routing.directoryRules) { rule in
            Text(folderLabel(rule.directory)).tag(AccountRoutingScope.directory(rule.id))
          }
          Text("Other Folders").tag(AccountRoutingScope.defaultRule)
        }
        .labelsHidden()
        .controlSize(.large)
        .frame(maxWidth: 400, alignment: .leading)
        Spacer()
      }
      .disabled(model.registryLoadError != nil)

      if model.displayedAccounts.isEmpty {
        emptyState("No Assigned Accounts", symbol: "person.crop.circle.badge.plus")
      } else {
        ScrollView {
          VStack(spacing: 0) {
            HStack(spacing: 14) {
              Text("Account").frame(maxWidth: .infinity, alignment: .leading)
              Text("Remaining").frame(width: 240, alignment: .leading)
              Text("Resets").frame(width: 127, alignment: .leading)
              Color.clear.frame(width: 94, height: 1)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .background(Color.primary.opacity(0.035))
            ForEach(model.displayedAccounts) { account in
              Divider()
              switchAccountRow(account)
            }
          }
          .settingsPanel()
        }
      }
    }
  }

  private func switchAccountRow(_ account: TurnrailAccount) -> some View {
    let windows = quotaWindows(account)
    let index = model.ruleAccountIDs.firstIndex(of: account.id)
    return HStack(spacing: 14) {
      VStack(alignment: .leading, spacing: 5) {
        AccountIdentityLabel(account: account)
        if let lastUsed = model.lastUsedByAccountID[account.id] {
          Group {
            if case .failed(let details) = lastUsed {
              Button(lastUsed.label(timeZone: .current)) {
                model.showAccountError(details)
              }
              .buttonStyle(.plain)
              .foregroundStyle(.red)
            } else {
              Text(lastUsed.label(timeZone: .current))
                .foregroundStyle(.secondary)
            }
          }
          .font(.system(size: 12).monospacedDigit())
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .layoutPriority(1)
      Group {
        if let issue = model.accountIssue(for: account) {
          issueButton(account, issue)
        } else if windows.isEmpty {
          Text(usageStatus(account)).foregroundStyle(.secondary)
        } else {
          VStack(spacing: 10) {
            ForEach(windows) { quota in
              HStack(spacing: 8) {
                Text("\(quota.window.remainingPercent)%")
                  .monospacedDigit()
                  .frame(width: 48, alignment: .trailing)
                ProgressView(value: Double(quota.window.remainingPercent), total: 100)
                  .tint(quota.window.remainingPercent <= 10 ? .orange : .blue)
                  .accessibilityLabel("\(quota.label) remaining")
              }
              .frame(height: 18)
            }
          }
        }
      }
      .font(.system(size: 13))
      .frame(width: 240, alignment: .leading)

      VStack(alignment: .leading, spacing: 10) {
        ForEach(windows) { quota in
          Group {
            if let date = quota.window.resetsAt {
              Text(
                date,
                format: .dateTime.month(.abbreviated).day().hour().minute()
                  .locale(Locale(identifier: "en_US")))
            } else {
              Text("Unavailable").foregroundStyle(.secondary)
            }
          }
          .frame(height: 18)
        }
      }
      .font(.system(size: 13).monospacedDigit())
      .frame(width: 127, alignment: .leading)

      Group {
        if index == 0 {
          Text("Preferred").foregroundStyle(.secondary)
        } else {
          Button("Prioritize") {
            model.selectAccount(id: account.id, scope: model.routingScope)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .disabled(model.registryLoadError != nil)
          .accessibilityLabel("Prioritize \(account.email)")
        }
      }
      .frame(width: 94)
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 18)
    .contentShape(Rectangle())
    .contextMenu {
      Button("Move Up") { model.moveAccount(id: account.id, direction: .up) }
        .disabled(index == nil || index == 0)
      Button("Move Down") { model.moveAccount(id: account.id, direction: .down) }
        .disabled(index == nil || index == model.ruleAccountIDs.count - 1)
    }
  }

  private var foldersPage: some View {
    ScrollView {
      VStack(spacing: 14) {
        ForEach(model.registryState.routing.directoryRules) { rule in
          folderCard(
            title: folderLabel(rule.directory), scope: .directory(rule.id),
            ids: rule.accountIDs, rule: rule)
        }
        folderCard(
          title: "Other Folders", scope: .defaultRule,
          ids: model.registryState.routing.defaultAccountIDs, rule: nil)
      }
    }
    .disabled(model.registryLoadError != nil)
  }

  private func folderCard(
    title: String, scope: AccountRoutingScope, ids: [UUID], rule: DirectoryAccountRule?
  ) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Button {
          if expandedFolders.contains(scope) {
            expandedFolders.remove(scope)
          } else {
            expandedFolders.insert(scope)
          }
        } label: {
          HStack(spacing: 12) {
            Image(systemName: expandedFolders.contains(scope) ? "chevron.down" : "chevron.right")
              .font(.system(size: 10, weight: .semibold)).frame(width: 12)
            Image(systemName: "folder.fill").foregroundStyle(.blue).font(.title3)
            Text(title).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text("\(ids.count) \(ids.count == 1 ? "account" : "accounts")")
              .foregroundStyle(.secondary)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(ids.count) accounts")
        if let rule {
          Menu {
            Button("Change Folder") {
              _ = model.chooseRoutingDirectory(replacing: rule.id)
            }
            Button("Remove Folder", role: .destructive) { folderPendingRemoval = rule }
          } label: {
            Image(systemName: "ellipsis")
          }
          .menuStyle(.borderlessButton)
          .menuIndicator(.hidden)
          .fixedSize()
          .accessibilityLabel("Folder actions for \(title)")
        }
      }
      .padding(18)

      if expandedFolders.contains(scope) {
        ForEach(ids, id: \.self) { id in
          if let account = model.registryState.accounts.first(where: { $0.id == id }) {
            Divider()
            HStack(spacing: 12) {
              AccountIdentityLabel(account: account)
              Spacer()
              Button("Unassign") {
                model.setAccountAllowed(id: id, allowed: false, scope: scope)
              }
              .accessibilityLabel("Unassign \(account.email) from \(title)")
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 14)
          }
        }
        Divider()
        HStack {
          Menu {
            ForEach(model.registryState.accounts.filter { !ids.contains($0.id) }) { account in
              Button(account.displayName) {
                model.setAccountAllowed(id: account.id, allowed: true, scope: scope)
              }
            }
          } label: {
            Label("Assign Account", systemImage: "plus")
          }
          .fixedSize()
          .disabled(model.registryState.accounts.allSatisfy { ids.contains($0.id) })
          Spacer()
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 14)
      }
    }
    .settingsPanel()
  }

  private var accountsPage: some View {
    Group {
      if model.registryState.accounts.isEmpty {
        emptyState("No Connected Accounts", symbol: "person.crop.circle")
      } else {
        ScrollView {
          VStack(spacing: 0) {
            HStack(spacing: 14) {
              Text("Account").frame(maxWidth: .infinity, alignment: .leading)
              Text("Plan").frame(width: 120, alignment: .leading)
              Text("Status").frame(width: 180, alignment: .leading)
              Color.clear.frame(width: 112, height: 1)
              Color.clear.frame(width: 24, height: 1)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .background(Color.primary.opacity(0.035))
            ForEach(model.registryState.accounts) { account in
              Divider()
              HStack(spacing: 14) {
                Text(account.email)
                  .font(.system(size: 14))
                  .lineLimit(1)
                  .truncationMode(.middle)
                  .textSelection(.enabled)
                  .frame(maxWidth: .infinity, alignment: .leading)
                Text(account.planType.displayName)
                  .frame(width: 120, alignment: .leading)
                Group {
                  if let issue = model.accountIssue(for: account) {
                    issueButton(account, issue)
                  } else {
                    HStack(spacing: 7) {
                      Circle()
                        .fill(
                          model.authStatusByAccountID[account.id] == .loggedIn ? .green : .orange
                        )
                        .frame(width: 7, height: 7)
                      Text(connectionStatus(account))
                    }
                    .foregroundStyle(.secondary)
                  }
                }
                .frame(width: 180, alignment: .leading)
                Button("Sign In Again") {
                  model.reauthenticate(accountID: account.id)
                }
                .controlSize(.large)
                .disabled(accountIsBusy(account))
                .frame(width: 112)
                .accessibilityLabel("Sign in again to \(account.email)")
                Menu {
                  Button("Remove Account", role: .destructive) { accountPendingRemoval = account }
                    .disabled(accountIsBusy(account))
                } label: {
                  Image(systemName: "ellipsis")
                    .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Account actions for \(account.email)")
              }
              .font(.system(size: 13))
              .padding(.horizontal, 18)
              .padding(.vertical, 16)
            }
          }
          .settingsPanel()
        }
      }
    }
  }

  private func issueButton(_ account: TurnrailAccount, _ issue: TurnrailViewModel.AccountIssue)
    -> some View
  {
    Button {
      presentedAccountIssue = PresentedAccountIssue(account: account, issue: issue)
    } label: {
      Label(issue.badgeTitle, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)
    }
    .buttonStyle(.plain)
  }

  private func accountIsBusy(_ account: TurnrailAccount) -> Bool {
    model.removingAccountIDs.contains(account.id)
      || model.authStatusByAccountID[account.id] == .loginInProgress
      || model.authStatusByAccountID[account.id] == .checking
      || model.registryLoadError != nil
  }

  private func connectionStatus(_ account: TurnrailAccount) -> String {
    switch model.authStatusByAccountID[account.id] {
    case .loggedIn: "Connected"
    case .loggedOut: "Signed Out"
    case .loginInProgress: "Signing In"
    case .checking, nil: "Checking"
    case .failed: "Account Error"
    }
  }

  private func usageStatus(_ account: TurnrailAccount) -> String {
    if model.authStatusByAccountID[account.id] == .loggedOut { return "Sign-in Required" }
    if model.authStatusByAccountID[account.id] == .loginInProgress { return "Signing In" }
    switch model.usageStatusByAccountID[account.id] {
    case .checking, nil: return "Checking"
    case .available: return "Unavailable"
    case .failed: return "Usage Error"
    }
  }

  private struct QuotaWindow: Identifiable {
    let id: String
    let label: String
    let window: AccountRateLimitWindow
  }

  private func quotaWindows(_ account: TurnrailAccount) -> [QuotaWindow] {
    guard case .available(let limits) = model.usageStatusByAccountID[account.id] else { return [] }
    return limits.buckets.filter { $0.limitID == "codex" || $0.limitID == nil }.flatMap { bucket in
      [("Primary", bucket.primary), ("Secondary", bucket.secondary)].compactMap { name, window in
        guard let window else { return nil }
        let label: String
        if let minutes = window.windowDurationMinutes {
          if minutes.isMultiple(of: 1440) {
            label = "\(minutes / 1440)d"
          } else if minutes.isMultiple(of: 60) {
            label = "\(minutes / 60)h"
          } else {
            label = "\(minutes)m"
          }
        } else {
          label = name
        }
        return QuotaWindow(id: "\(bucket.id):\(name)", label: label, window: window)
      }
    }
  }

  private func folderLabel(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
  }

  private func emptyState(_ title: String, symbol: String) -> some View {
    VStack(spacing: 14) {
      Image(systemName: symbol).font(.system(size: 32))
      Text(title).font(.headline)
    }
    .foregroundStyle(.secondary)
    .frame(maxWidth: .infinity)
    .padding(.vertical, 64)
  }
}

private struct AccountIdentityLabel: View {
  let account: TurnrailAccount

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(account.email)
        .font(.system(size: 14))
        .lineLimit(1)
        .truncationMode(.middle)
        .textSelection(.enabled)
      Text(account.planType.displayName)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }
  }
}

private struct SettingsPanel: ViewModifier {
  func body(content: Content) -> some View {
    content
      .background(Color.primary.opacity(0.025))
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
      }
  }
}

extension View {
  fileprivate func settingsPanel() -> some View {
    modifier(SettingsPanel())
  }
}

private struct TurnrailStatusControls: View {
  @ObservedObject var model: TurnrailViewModel
  @Binding var showsStatusDetails: Bool

  var body: some View {
    VStack(spacing: 10) {
      Divider().padding(.bottom, 6)
      HStack(spacing: 8) {
        Circle().fill(statusColor).frame(width: 9, height: 9)
        Text(model.statusText)
        Spacer()
        if model.statusDetails != nil {
          Button("Details") { showsStatusDetails = true }
            .buttonStyle(.link)
        }
      }
      .padding(.bottom, 4)
      Button {
        model.launchCodex()
      } label: {
        Text("Open Codex").frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(!model.canLaunch)
      Button {
        model.refreshCompatibility()
        if model.statusDetails != nil { showsStatusDetails = true }
      } label: {
        Text("Check Compatibility").frame(maxWidth: .infinity)
      }
      .controlSize(.large)
    }
    .font(.system(size: 12))

  }

  private var statusColor: Color {
    if model.statusDetails != nil { return .orange }
    if model.isCodexRunning || model.canLaunch { return .green }
    if case .checking = model.state { return .secondary }
    return .orange
  }
}
