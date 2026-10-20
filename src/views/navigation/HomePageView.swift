//
//  HomePageView.swift
//  Helium UI
//
//  Created by lemin on 10/19/23.
//

import Foundation
import SwiftUI

// MARK: Home Page View
struct HomePageView: View {
  @State private var isNowEnabled: Bool = false
  @State private var buttonDisabled: Bool = false
  @State private var inProgress = false

  var body: some View {
    NavigationView {
      VStack(spacing: 10) {
        Spacer()

        // Activate HUD Button
        Button(
          action: {
            #if targetEnvironment(simulator)
              isNowEnabled.toggle()
            #else
              toggleHUD(!isNowEnabled)
            #endif
          },
          label: {
            HStack(spacing: 10) {
              if inProgress {
                if #available(iOS 16.0, *) {
                  ProgressView()
                    .tint(isNowEnabled ? .red : .blue)
                } else {
                  ProgressView()
                    .foregroundColor(isNowEnabled ? .red : .blue)
                }
              }
              Text(
                isNowEnabled
                  ? NSLocalizedString("Disable HUD", comment: "")
                  : NSLocalizedString("Enable HUD", comment: ""))
            }
          }
        )
        .buttonStyle(TintedButton(color: isNowEnabled ? .red : .blue))
        .padding(5)
        .offset(y: isNowEnabled ? -10 : 0)
        Text(
          NSLocalizedString(
            "You can quit the app now.\nThe HUD will persist on your screen.", comment: "")
        )
        .multilineTextAlignment(.center)
        .offset(y: isNowEnabled ? 5 : 15)
        .foregroundColor(.blue)
        .opacity(isNowEnabled ? 1 : 0)

        Spacer()
        // HUD Info Text
        Text(
          isNowEnabled
            ? NSLocalizedString("Status: Running", comment: "")
            : NSLocalizedString("Status: Stopped", comment: "")
        )
        .font(.caption)
        .foregroundColor(isNowEnabled ? .blue : .red)
        .padding(.bottom, 10)
        .multilineTextAlignment(.center)

        // MARK: CPU 保频（0.34 测试功能）
        CPUGovernorCard()
          .padding(.horizontal, 20)
          .padding(.bottom, 16)
      }
      .disabled(buttonDisabled)
      .onAppear {
        #if !targetEnvironment(simulator)
          isNowEnabled = IsHUDEnabledBridger()
        #endif
      }
      .onOpenURL(perform: { url in
        let _ = FileManager.default
        // MARK: URL Schemes
        if url.absoluteString == "helium://toggle" {
          #if !targetEnvironment(simulator)
            toggleHUD(!isNowEnabled)
          #endif
        } else if url.absoluteString == "helium://on" {
          #if !targetEnvironment(simulator)
            toggleHUD(true)
          #endif
        } else if url.absoluteString == "helium://off" {
          #if !targetEnvironment(simulator)
            toggleHUD(false)
          #endif
        }
      })
      .navigationTitle(Text(NSLocalizedString("Statusbar", comment: "")))
      .toolbar {
        // 右上角原来是一个齿轮，点开是「关于」页。整页「关于」已移除，
        // 这里改为直接显示版本号 —— 位置不变，但不再是一个可点的入口。
        ToolbarItem(placement: .navigationBarTrailing) {
          Text(Bundle.main.releaseVersionNumber ?? "—")
            .font(.footnote)
            .foregroundColor(.secondary)
        }
      }
    }
    .navigationViewStyle(StackNavigationViewStyle())
    .animation(.timingCurve(0.25, 0.1, 0.35, 1.75).speed(1.2), value: isNowEnabled)
    .animation(.timingCurve(0.25, 0.1, 0.35, 1.75).speed(1.2), value: inProgress)
  }

  func toggleHUD(_ isActive: Bool) {
    inProgress.toggle()
    Haptic.shared.play(.medium)
    if isNowEnabled == isActive { return }
    print(
      !isActive
        ? NSLocalizedString("Closing HUD", comment: "")
        : NSLocalizedString("Opening HUD", comment: ""))
    SetHUDEnabledBridger(isActive)

    buttonDisabled = true
    waitForNotificationBridger(
      {
        isNowEnabled = isActive
        buttonDisabled = false
        inProgress.toggle()
      }, !isNowEnabled)
  }
}

// MARK: - CPU 保频卡片（0.34 测试）

/// 一个全局开关加两档强度，写进 HUD 与 App 共用的 plist（键 `cpuGovernorMode`），
/// 再发 `NOTIFY_RELOAD_HUD` 让 HUD 立刻重新应用。
///
/// 界面上刻意把代价写清楚：这个功能的本质是**用 CPU 时间换频率**。iOS 没有可以
/// 直接设频率的接口（见 CPUFrequencyGovernor.h），所以占用率上升不是缺陷，是它
/// 的工作原理。
struct CPUGovernorCard: View {
  @State private var mode: Int = 0

  /// 与 hud-prefix.pch 里 USER_DEFAULTS_PATH 指向同一个文件。这里写死字面量而不是
  /// 引用宏：宏在 Swift 侧是否可见取决于 Theos 的编译参数，字面量没有这个不确定性。
  private let prefsPath = "/var/mobile/Library/Preferences/com.corin.Statusbar.plist"

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Toggle(
        isOn: Binding(
          get: { mode != 0 },
          set: { on in
            mode = on ? 1 : 0
            save()
          }
        )
      ) {
        Text(NSLocalizedString("CPU 保频（测试）", comment: ""))
          .font(.subheadline)
      }

      if mode != 0 {
        Picker(
          "",
          selection: Binding(
            get: { mode },
            set: { value in
              mode = value
              save()
            })
        ) {
          Text(NSLocalizedString("轻档", comment: "")).tag(1)
          Text(NSLocalizedString("强档", comment: "")).tag(2)
        }
        .pickerStyle(.segmented)
      }

      Text(
        mode == 0
          ? NSLocalizedString("关闭。不会额外占用 CPU。", comment: "")
          : NSLocalizedString(
            "以短脉冲让性能核保持在高频档：解锁时预热一次，运行中按占空比补脉冲。CPU 占用率会随之上升——这是原理，不是缺陷。温度过高或开启低电量模式时自动停止。",
            comment: "")
      )
      .font(.caption2)
      .foregroundColor(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.12))
    )
    .onAppear {
      mode = UserDefaults.standard.integer(forKey: "cpuGovernorMode", forPath: prefsPath)
    }
  }

  private func save() {
    UserDefaults.standard.setValue(mode, forKey: "cpuGovernorMode", forPath: prefsPath)
    DarwinNotificationCenter.default.post(name: "com.corin.Statusbar.notification.hud.reload")
  }
}
