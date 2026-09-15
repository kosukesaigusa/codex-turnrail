import CodexTurnrailCore
import SwiftUI

enum UsageTimestampFormat: String {
  case date = "MMM d"
  case time = "HH:mm"
  case dateTime = "MMM d, HH:mm"

  func string(from date: Date, timeZone: TimeZone) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = timeZone
    formatter.dateFormat = rawValue
    return formatter.string(from: date)
  }
}

struct AccountUsageWindow: Identifiable {
  let id: String
  let title: String
  let window: AccountRateLimitWindow

  static func windows(in limits: AccountRateLimits) -> [Self] {
    limits.buckets.filter { $0.limitID == "codex" || $0.limitID == nil }.flatMap { bucket in
      [("Primary", bucket.primary), ("Secondary", bucket.secondary)].compactMap { name, window in
        guard let window else { return nil }
        let title: String
        switch window.windowDurationMinutes {
        case 10_080: title = "Weekly limit"
        case 300: title = "5-hour limit"
        case .some(let minutes) where minutes.isMultiple(of: 1440):
          title = "\(minutes / 1440)-day limit"
        case .some(let minutes) where minutes.isMultiple(of: 60):
          title = "\(minutes / 60)-hour limit"
        case .some(let minutes): title = "\(minutes)-minute limit"
        case nil: title = "\(name) limit"
        }
        return Self(id: "\(bucket.id):\(name)", title: title, window: window)
      }
    }
  }
}

struct AccountUsageSummary: View {
  let limits: AccountRateLimits
  let showResets: () -> Void
  @Environment(\.timeZone) private var timeZone

  var body: some View {
    let windows = AccountUsageWindow.windows(in: limits)
    VStack(alignment: .leading, spacing: 12) {
      if windows.isEmpty {
        Text("Usage unavailable").foregroundStyle(.secondary)
      }
      ForEach(windows) { quota in
        VStack(alignment: .leading, spacing: 6) {
          Text(quota.title).font(.system(size: 12, weight: .medium))
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
              if let date = quota.window.resetsAt {
                Text(
                  "Resets \(UsageTimestampFormat.dateTime.string(from: date, timeZone: timeZone))")
              } else {
                Text("Reset time unavailable")
              }
            }
            .foregroundStyle(.secondary)
            .font(.system(size: 11).monospacedDigit())
            Spacer(minLength: 0)
            Text("\(quota.window.remainingPercent)% left")
              .font(.system(size: 12).monospacedDigit())
              .foregroundStyle(quota.window.remainingPercent == 0 ? Color.orange : Color.primary)
          }
          GeometryReader { geometry in
            Capsule().fill(Color.primary.opacity(0.16))
              .overlay(alignment: .leading) {
                Capsule().fill(Color.primary)
                  .frame(width: geometry.size.width * Double(quota.window.remainingPercent) / 100)
              }
          }
          .frame(height: 4)
          .accessibilityElement()
          .accessibilityLabel("\(quota.title) remaining")
          .accessibilityValue("\(quota.window.remainingPercent) percent")
        }
      }
      if let resets = limits.resetCredits, resets.availableCount > 0 {
        Button(action: showResets) {
          HStack(spacing: 5) {
            Text(
              "\(resets.availableCount) available \(resets.availableCount == 1 ? "reset" : "resets")"
            )
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .medium))
          }
        }
        .buttonStyle(.link)
        .font(.system(size: 11))
      }
    }
  }
}

struct AccountResetCreditsSheet: View {
  let account: TurnrailAccount
  @ObservedObject var model: TurnrailViewModel
  @Environment(\.dismiss) private var dismiss
  @State private var isRefreshing = false

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Available resets").font(.title2.weight(.semibold))
        Text(account.email).foregroundStyle(.secondary).textSelection(.enabled)
      }
      Group {
        if case .available(let limits) = model.usageStatusByAccountID[account.id],
          let resets = limits.resetCredits
        {
          ResetCreditDetails(resets: resets)
        } else {
          Text("Reset details unavailable").foregroundStyle(.secondary)
        }
      }
      HStack {
        Button("Refresh Usage") {
          isRefreshing = true
          Task {
            defer { isRefreshing = false }
            await model.refreshAuthStatus(for: account)
          }
        }
        .disabled(isRefreshing || model.isRefreshingAccounts || model.isSigningIn)
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 460)
  }
}

struct ResetCreditDetails: View {
  let resets: AccountResetCredits
  @Environment(\.timeZone) private var timeZone

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("\(resets.availableCount) available").font(.headline)
      if resets.availableCount == 0 {
        Text("No available resets").foregroundStyle(.secondary)
      } else if let credits = resets.availableCredits {
        if credits.count < resets.availableCount {
          Text("\(credits.count) of \(resets.availableCount) reset details available")
            .foregroundStyle(.secondary)
        }
        if !credits.isEmpty {
          ScrollView {
            VStack(alignment: .leading, spacing: 0) {
              ForEach(credits) { credit in
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                  Text(credit.displayTitle).font(.headline)
                  if let expiry = credit.expiresAt {
                    Text(
                      "Expires \(UsageTimestampFormat.dateTime.string(from: expiry, timeZone: timeZone))"
                    )
                    .foregroundStyle(.secondary)
                  } else {
                    Text("No expiration").foregroundStyle(.secondary)
                  }
                }
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
              }
            }
          }
          .frame(height: min(CGFloat(credits.count) * 80, 320))
        }
      } else {
        Text("Reset details unavailable").foregroundStyle(.secondary)
      }
    }
  }
}
