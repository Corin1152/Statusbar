//
//  WidgetPreferencesView.swift
//  Helium UI
//
//  Created by lemin on 10/18/23.
//

import Foundation
import SwiftUI

struct WidgetPreferencesView: View {
    @StateObject var widgetManager: WidgetManager
    @State var widgetSet: WidgetSetStruct
    @Binding var widgetID: WidgetIDStruct
    
    @State var text: String = ""
    @State var intSelection: Int = 0
    @State var intSelection2: Int = 0
    @State var intSelection3: Int = 1
    @State var boolSelection: Bool = false
    
    @State var modified: Bool = false
    @State private var isPresented = false

    /// 日期部件的「星期语言」。写全局键 `dateLocale`，与 HUD 共用一个值。
    @State private var dateLocaleRaw: String = DateLocaleOption.system.rawValue

    /// 格式简码表的展开状态。默认收起 —— 展开后是二十多行，会把手动输入框顶出屏幕。
    @State private var showFormatTokens: Bool = false

    /// 蜂窝信号探针的状态（"pending" / "ok" / "unavailable"），见 SwiftObjCPPBridger.h。
    @State private var cellularStatus: String = ""

    /// 信号小部件当前显示的是哪一路（"wifi:<dBm>" / "wifi-failed:<原因>" /
    /// "cellular:<dBm>" / "unavailable"）。
    @State private var signalSource: String = "unavailable"

    /// 信号小部件是否跟随网络在 Wi-Fi 与蜂窝之间切换。
    @State private var followNetwork: Bool = false

    /// 状态行的文案。`unavailable` 的说明刻意把「权限」写进去 —— 那是它最常见的原因。
    private var cellularStatusText: String {
        switch cellularStatus {
        case "ok":
            return NSLocalizedString("Available", comment:"")
        case "unavailable":
            return NSLocalizedString("Unavailable - check the CommCenter entitlement", comment:"")
        default:
            return NSLocalizedString("Checking…", comment:"")
        }
    }

    private var cellularStatusIsOK: Bool {
        return cellularStatus == "ok"
    }

    /// 当前信号来源。
    ///
    /// 带上数值一起显示，是因为**来源错了比读不到更难发现**：两个网络都在 -70 附近时，
    /// 数字本身看不出问题。
    private var signalSourceText: String {
        let parts = signalSource.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return NSLocalizedString("Unavailable", comment:"")
        }
        let payload = parts[1]
        switch parts[0] {
        case "wifi":
            guard let dbm = Int(payload) else { return NSLocalizedString("Unavailable", comment:"") }
            return String(format: NSLocalizedString("Wi-Fi %d dBm", comment:""), dbm)
        case "cellular":
            guard let dbm = Int(payload) else { return NSLocalizedString("Unavailable", comment:"") }
            return String(format: NSLocalizedString("Cellular %d dBm", comment:""), dbm)
        case "wifi-failed":
            // 连着 Wi-Fi 但读不到 RSSI。把断在哪一步带出来 —— 这是唯一能区分
            // 「框架没加载」「符号改名」「wifid 拒绝连接」的地方。
            return String(format: NSLocalizedString("Wi-Fi connected, RSSI unavailable (%@)", comment:""), payload)
        case "pending":
            // Wi-Fi 那次采样还没落地。如实说「还没好」——
            // 回落成「蜂窝」会让用户以为读的是蜂窝。
            return NSLocalizedString("Checking…", comment:"")
        default:
            return NSLocalizedString("Unavailable", comment:"")
        }
    }

    /// 只有真的读到数值才算「已知」。`wifi-failed` 与 `pending` 都要显示成需要留意的颜色。
    private var signalSourceIsKnown: Bool {
        let parts = signalSource.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return false }
        if parts[0] == "wifi-failed" || parts[0] == "pending" { return false }
        return Int(parts[1]) != nil
    }

    /// 每秒刷一次「来源」与「状态」。
    ///
    /// **必须刷，不能只在 `onAppear` 读一次。** Wi-Fi 那边是异步采样的（而且只有 HUD
    /// 在画的时候才会被安排），设置页打开的那一瞬间大概率还没采到 —— 读一次的话
    /// 会永远停在「蜂窝」，而部件本身显示的其实是 Wi-Fi 数值。
    private let statusRefresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    let timeFormats: [String] = [
        "hh:mm",
        "hh:mm a",
        "hh:mm:ss",
        "hh",
        
        "HH:mm",
        "HH:mm:ss",
        "HH",
        
        "mm",
        "ss"
    ]
    
    let dateFormatter = DateFormatter()
    let currentDate = Date()

    /// 日期格式简码表。
    ///
    /// 只列真正有用的子集：`y`/`M`/`d`/`E`/`H`/`h`/`m`/`s`/`a` 已经覆盖日常所有写法；
    /// 末尾三条 `CN*` 是 Helium 自己加的农历占位符（见 LunarDate.mm），Foundation
    /// 不认识它们，由 `getChineseCalendarWithDate:format:` 在格式化前替换成中文。
    ///
    /// 示例值全部由当前日期实时渲染 —— 表里看到的，就是切回桌面后部件上显示的。
    let dateFormatTokens: [DateFormatToken] = [
        .init(token: "yyyy", desc: NSLocalizedString("Four-digit year", comment: "")),
        .init(token: "yy", desc: NSLocalizedString("Two-digit year", comment: "")),

        .init(token: "MMMM", desc: NSLocalizedString("Full month name", comment: "")),
        .init(token: "MMM", desc: NSLocalizedString("Short month name", comment: "")),
        .init(token: "MM", desc: NSLocalizedString("Two-digit month", comment: "")),
        .init(token: "M", desc: NSLocalizedString("Month", comment: "")),

        .init(token: "dd", desc: NSLocalizedString("Two-digit day", comment: "")),
        .init(token: "d", desc: NSLocalizedString("Day", comment: "")),

        .init(token: "EEEE", desc: NSLocalizedString("Full weekday name", comment: "")),
        .init(token: "EEE", desc: NSLocalizedString("Short weekday name", comment: "")),
        .init(token: "E", desc: NSLocalizedString("Short weekday name (same as EEE)", comment: "")),

        .init(token: "HH", desc: NSLocalizedString("24-hour, two digits", comment: "")),
        .init(token: "H", desc: NSLocalizedString("24-hour", comment: "")),
        .init(token: "hh", desc: NSLocalizedString("12-hour, two digits", comment: "")),
        .init(token: "h", desc: NSLocalizedString("12-hour", comment: "")),
        .init(token: "a", desc: NSLocalizedString("AM / PM marker", comment: "")),

        .init(token: "mm", desc: NSLocalizedString("Two-digit minute", comment: "")),
        .init(token: "m", desc: NSLocalizedString("Minute", comment: "")),
        .init(token: "ss", desc: NSLocalizedString("Two-digit second", comment: "")),
        .init(token: "s", desc: NSLocalizedString("Second", comment: "")),

        .init(token: "CNYY", desc: NSLocalizedString("Lunar year (stems and branches)", comment: "")),
        .init(token: "CNMM", desc: NSLocalizedString("Lunar month", comment: "")),
        .init(token: "CNDD", desc: NSLocalizedString("Lunar day", comment: "")),
    ]
    
    var body: some View {
        VStack {
            // MARK: Preview
            WidgetPreviewsView(widget: $widgetID, previewColor: .white)
            
            switch (widgetID.module) {
            case .dateWidget:
                // MARK: Date Format / Locale
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(NSLocalizedString("Date Format", comment:""))
                            .foregroundColor(.primary)
                            .bold()
                        Spacer()
                        TextField(NSLocalizedString("E MMM dd", comment:""), text: $text)
                            .frame(maxWidth: 130)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled(true)
                            .onAppear {
                                if let format = widgetID.config["dateFormat"] as? String {
                                    text = format
                                } else {
                                    text = NSLocalizedString("E MMM dd", comment:"")
                                }
                            }
                    }

                    // 实时预览：格式串是手写的，改一个字母就得能立刻看到结果，
                    // 否则用户只能回桌面确认。
                    HStack {
                        Text(NSLocalizedString("Preview", comment:""))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(getFormattedDate(text.isEmpty ? NSLocalizedString("E MMM dd", comment:"") : text))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                    }

                    // MARK: Weekday Language
                    HStack {
                        Text(NSLocalizedString("Weekday Language", comment:""))
                            .foregroundColor(.primary)
                            .bold()
                        Spacer()
                        Picker(selection: $dateLocaleRaw) {
                            ForEach(DateLocaleOption.allCases) { option in
                                Text(option.displayName).tag(option.rawValue)
                            }
                        } label: {}
                        .pickerStyle(.menu)
                    }

                    // MARK: Format Codes
                    DisclosureGroup(isExpanded: $showFormatTokens) {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(dateFormatTokens) { item in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(item.token)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.blue)
                                        .frame(width: 54, alignment: .leading)
                                    Text(item.desc)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text(getFormattedDate(item.token))
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.primary)
                                }
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        Text(NSLocalizedString("Supported Format Codes", comment:""))
                            .font(.subheadline)
                            .foregroundColor(.primary)
                    }
                }
                .onAppear {
                    dateLocaleRaw = UserDefaults.standard.string(forKey: "dateLocale", forPath: USER_DEFAULTS_PATH)
                        ?? DateLocaleOption.system.rawValue
                }
            case .network:
                // MARK: Network Type Choice
                VStack {
                    HStack {
                        Text(NSLocalizedString("Network Type", comment:"")).foregroundColor(.primary).bold()
                        Spacer()
                        Picker(selection: $intSelection) {
                            Text(NSLocalizedString("Download", comment:"")).tag(0)
                            Text(NSLocalizedString("Upload", comment:"")).tag(1)
                        } label: {}
                        .pickerStyle(.menu)
                        .onAppear {
                            if let netUp = widgetID.config["isUp"] as? Bool {
                                intSelection = netUp ? 1 : 0
                            } else {
                                intSelection = 0
                            }
                        }
                    }
                    // MARK: Speed Icon Choice
                    HStack {
                        Text(NSLocalizedString("Speed Icon", comment:"")).foregroundColor(.primary).bold()
                        Spacer()
                        Picker(selection: $intSelection2) {
                            Text(intSelection == 0 ? "▼" : "▲").tag(0)
                            Text(intSelection == 0 ? "↓" : "↑").tag(1)
                        } label: {}
                        .pickerStyle(.menu)
                        .onAppear {
                            if let speedIcon = widgetID.config["speedIcon"] as? Int {
                                intSelection2 = speedIcon
                            } else {
                                intSelection2 = 0
                            }
                        }
                    }
                    // MARK: Minimum Unit Choice
                    HStack {
                        Text(NSLocalizedString("Minimum Unit", comment:"")).foregroundColor(.primary).bold()
                        Spacer()
                        Picker(selection: $intSelection3) {
                            Text("b").tag(0)
                            Text("Kb").tag(1)
                            Text("Mb").tag(2)
                            Text("Gb").tag(3)
                        } label: {}
                        .pickerStyle(.menu)
                        .onAppear {
                            if let minUnit = widgetID.config["minUnit"] as? Int {
                                intSelection3 = minUnit
                            } else {
                                intSelection3 = 1
                            }
                        }
                    }
                    // MARK: Hide Speed When Zero
                    Toggle(isOn: $boolSelection) {
                        Text(NSLocalizedString("Hide Speed When 0", comment:""))
                            .foregroundColor(.primary)
                            .bold()
                    }
                    .onAppear {
                        boolSelection = widgetID.config["hideSpeedWhenZero"] as? Bool ?? false
                    }
                }
            case .temperature:
                // MARK: Battery Temperature Value
                HStack {
                    Text(NSLocalizedString("Temperature Unit", comment:"")).foregroundColor(.primary).bold()
                    Spacer()
                    Picker(selection: $intSelection) {
                        Text(NSLocalizedString("Celcius", comment:"")).tag(0)
                        Text(NSLocalizedString("Fahrenheit", comment:"")).tag(1)
                    } label: {}
                        .pickerStyle(.menu)
                        .onAppear {
                            if widgetID.config["useFahrenheit"] as? Bool ?? false == true {
                                intSelection = 1
                            } else {
                                intSelection = 0
                            }
                        }
                }
            case .cpuTemperature:
                // MARK: CPU Temperature Value
                HStack {
                    Text(NSLocalizedString("Temperature Unit", comment:"")).foregroundColor(.primary).bold()
                    Spacer()
                    Picker(selection: $intSelection) {
                        Text(NSLocalizedString("Celcius", comment:"")).tag(0)
                        Text(NSLocalizedString("Fahrenheit", comment:"")).tag(1)
                    } label: {}
                        .pickerStyle(.menu)
                        .onAppear {
                            if widgetID.config["useFahrenheit"] as? Bool ?? false == true {
                                intSelection = 1
                            } else {
                                intSelection = 0
                            }
                        }
                }
            case .cpuUsage:
                // MARK: CPU Usage Options
                VStack {
                    HStack {
                        Text(NSLocalizedString("Usage Mode", comment:"")).foregroundColor(.primary).bold()
                        Spacer()
                        Picker(selection: $intSelection) {
                            Text(NSLocalizedString("Average", comment:"")).tag(0)
                            Text(NSLocalizedString("Busiest Core", comment:"")).tag(1)
                        } label: {}
                        .pickerStyle(.menu)
                        .onAppear {
                            intSelection = widgetID.config["usageMode"] as? Int ?? 0
                        }
                    }
                    HStack {
                        Text(NSLocalizedString("Decimal Places", comment:"")).foregroundColor(.primary).bold()
                        Spacer()
                        Picker(selection: $intSelection2) {
                            Text("0").tag(0)
                            Text("1").tag(1)
                        } label: {}
                        .pickerStyle(.menu)
                        .onAppear {
                            intSelection2 = widgetID.config["decimals"] as? Int ?? 0
                        }
                    }
                    Toggle(isOn: $boolSelection) {
                        // Same key as the battery-capacity widget's switch, and the
                        // same string, so it stays one entry in the tables.
                        Text(NSLocalizedString("Show Percent (%) Symbol", comment:""))
                            .foregroundColor(.primary)
                            .bold()
                    }
                    .onAppear {
                        boolSelection = widgetID.config["showPercentage"] as? Bool ?? true
                    }
                }
            case .cpuFrequency:
                // MARK: CPU Frequency Unit
                HStack {
                    Text(NSLocalizedString("Frequency Unit", comment:"")).foregroundColor(.primary).bold()
                    Spacer()
                    Picker(selection: $intSelection) {
                        Text("GHz").tag(0)
                        Text("MHz").tag(1)
                    } label: {}
                    .pickerStyle(.menu)
                    .onAppear {
                        intSelection = widgetID.config["freqUnit"] as? Int ?? 0
                    }
                }
            case .cellularSignal:
                // MARK: Signal Options
                VStack {
                    // 当前显示的是哪一路。
                    //
                    // 这一行不是装饰：Wi-Fi 与蜂窝的读数范围重叠（都在 -40…-100 之间），
                    // 光看数字分不出是哪一路。而且 MobileWiFi 那条路一旦读不到，部件会
                    // **静默地**退回蜂窝 —— 用户看到的是「信号一直不变」，看不出原因。
                    HStack {
                        Text(NSLocalizedString("Source", comment:"")).foregroundColor(.primary).bold()
                        Spacer()
                        Text(signalSourceText)
                            .foregroundColor(signalSourceIsKnown ? .secondary : .orange)
                    }
                    // 权限/可用性状态行。
                    //
                    // 没有 CommCenter 权限时，取数调用不抛异常、不打日志，只是永远拿不到
                    // 值 —— 小部件会一直显示 `--`。那一行 `--` 到底是「无服务」还是
                    // 「没权限」，只有这里能区分。
                    HStack {
                        Text(NSLocalizedString("Status", comment:"")).foregroundColor(.primary).bold()
                        Spacer()
                        Text(cellularStatusText)
                            .foregroundColor(cellularStatusIsOK ? .secondary : .orange)
                    }
                    Toggle(isOn: $followNetwork) {
                        Text(NSLocalizedString("Show Wi-Fi signal when connected", comment:""))
                            .foregroundColor(.primary)
                            .bold()
                    }
                    .onAppear {
                        // **默认关**：这条私有路还没在真机验证过。默认开启等于把
                        // 未验证的私有框架调用塞进每个人的 HUD。
                        followNetwork = widgetID.config["followNetwork"] as? Bool ?? false
                    }
                    Text(NSLocalizedString("Experimental. Reads Wi-Fi RSSI through a private framework. If the status bar stops updating, turn this off.", comment:""))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack {
                        Text(NSLocalizedString("SIM Slot", comment:"")).foregroundColor(.primary).bold()
                        Spacer()
                        Picker(selection: $intSelection) {
                            Text(NSLocalizedString("Auto", comment:"")).tag(0)
                            Text(NSLocalizedString("Slot 1", comment:"")).tag(1)
                            Text(NSLocalizedString("Slot 2", comment:"")).tag(2)
                        } label: {}
                        .pickerStyle(.menu)
                        .onAppear {
                            intSelection = widgetID.config["signalSlot"] as? Int ?? 0
                        }
                    }
                    Toggle(isOn: $boolSelection) {
                        Text(NSLocalizedString("Show Unit (dBm)", comment:""))
                            .foregroundColor(.primary)
                            .bold()
                    }
                    .onAppear {
                        boolSelection = widgetID.config["showUnit"] as? Bool ?? true
                    }
                }
                .onAppear {
                    // 先读一次缓存状态（读的时候会顺带安排一次采样）。
                    cellularStatus = HeliumCellularSignalStatusBridger() ?? ""
                    signalSource = HeliumSignalSourceBridger() ?? "pending"
                }
                // 然后每秒刷 —— 采样是异步的，只读一次会停在「还没采到」。
                .onReceive(statusRefresh) { _ in
                    cellularStatus = HeliumCellularSignalStatusBridger() ?? ""
                    signalSource = HeliumSignalSourceBridger() ?? "pending"
                }
            case .timeWidget:
                // MARK: Time Format Selector
                HStack {
                    Picker(selection: $intSelection, label: Text(NSLocalizedString("Time Format", comment:"")).foregroundColor(.primary).bold()) {
                        ForEach(0..<timeFormats.count, id: \.self) { index in
                            Text("\(getFormattedDate(timeFormats[index]))\n(\(timeFormats[index]))").tag(index)
                        }
                    }
                    .onAppear {
                        if let timeFormat = widgetID.config["dateFormat"] as? String {
                            intSelection = timeFormats.firstIndex(of: timeFormat) ?? 0
                        } else {
                            intSelection = 0
                        }
                    }
                }
            case .textWidget:
                // MARK: Custom Text Label Textbox
                HStack {
                    Text(NSLocalizedString("Label Text", comment:""))
                        .foregroundColor(.primary)
                        .bold()
                    Spacer()
                    TextField(NSLocalizedString("Example", comment:""), text: $text)
                        .frame(maxWidth: 120)
                        .multilineTextAlignment(.trailing)
                        .onAppear {
                            if let format = widgetID.config["text"] as? String {
                                text = format
                            } else {
                                text = NSLocalizedString("Example", comment:"")
                            }
                        }
                }
            // default:
            //     Text(NSLocalizedString("No Configurable Aspects", comment:""))
            }
        }
        .padding(.horizontal, 15)
        .toolbar {
            HStack {
                // MARK: Save Button
                // only shows up if something is changed
                if (modified) {
                    Button(action: {
                        saveChanges()
                    }) {
                        Image(systemName: "checkmark.circle")
                    }
                }
            }
        }
        .onDisappear {
            if modified {
                UIApplication.shared.confirmAlert(title: NSLocalizedString("Save Changes", comment:""), body: NSLocalizedString("Would you like to save changes to the widget?", comment:""), onOK: {
                    saveChanges()
                }, noCancel: false)
            }
        }
        .onChange(of: text) { _ in
            modified = true
        }
        .onChange(of: dateLocaleRaw) { _ in
            modified = true
        }
                .onChange(of: intSelection) { _ in
            modified = true
        }
        .onChange(of: intSelection2) { _ in
            modified = true
        }
        .onChange(of: intSelection3) { _ in
            modified = true
        }
        .onChange(of: boolSelection) { _ in
            modified = true
        }
    }
    
    func getFormattedDate(_ format: String) -> String {
        let raw = UserDefaults.standard.string(forKey: "dateLocale", forPath: USER_DEFAULTS_PATH)
        dateFormatter.locale = DateLocaleOption.resolved(raw)
        // 农历占位符要先替换掉，否则 Foundation 会把 CNYY 当成三个普通字符输出。
        dateFormatter.dateFormat = LunarDate.getChineseCalendar(with: currentDate, format: format)
        return dateFormatter.string(from: currentDate)
    }
    
    func saveChanges() {
        var widgetStruct: WidgetIDStruct = .init(module: widgetID.module, config: widgetID.config)
        
        switch(widgetStruct.module) {
        // MARK: Changing Text
        case .dateWidget:
            // MARK: Date Format Handling
            if text == "" {
                widgetStruct.config["dateFormat"] = nil
            } else {
                widgetStruct.config["dateFormat"] = text
            }
            // 星期语言是**全局**设置：HUD 从 plist 顶层键 `dateLocale` 读它，而不是
            // 从单个部件的 config 里读。所有日期部件共用同一个语言，这正是想要的
            // 语义 —— 没道理让同一块 HUD 上的两个日期显示不同语言的星期。
            UserDefaults.standard.setValue(dateLocaleRaw, forKey: "dateLocale", forPath: USER_DEFAULTS_PATH)
        case .textWidget:
            // MARK: Custom Text Handling
            if text == "" {
                widgetStruct.config["text"] = nil
            } else {
                widgetStruct.config["text"] = text
            }
        
        // MARK: Changing Integer
        case .network:
            // MARK: Network Choices Handling
            widgetStruct.config["isUp"] = intSelection == 1 ? true : false
            widgetStruct.config["speedIcon"] = intSelection2
            widgetStruct.config["minUnit"] = intSelection3
            widgetStruct.config["hideSpeedWhenZero"] = boolSelection
        case .temperature:
            // MARK: Temperature Unit Handling
            widgetStruct.config["useFahrenheit"] = intSelection == 1 ? true : false
        case .cpuTemperature:
            // MARK: CPU Temperature Unit Handling
            widgetStruct.config["useFahrenheit"] = intSelection == 1 ? true : false
        case .cpuUsage:
            // MARK: CPU Usage Handling
            widgetStruct.config["usageMode"] = intSelection
            widgetStruct.config["decimals"] = intSelection2
            widgetStruct.config["showPercentage"] = boolSelection
        case .cpuFrequency:
            // MARK: CPU Frequency Unit Handling
            widgetStruct.config["freqUnit"] = intSelection
        case .cellularSignal:
            // MARK: Signal Handling
            widgetStruct.config["signalSlot"] = intSelection
            widgetStruct.config["showUnit"] = boolSelection
            widgetStruct.config["followNetwork"] = followNetwork
        case .timeWidget:
            // MARK: Time Format Handling
            widgetStruct.config["dateFormat"] = timeFormats[intSelection]
        // default:
        //     return;
        }
        
        widgetManager.updateWidgetConfig(widgetSet: widgetSet, id: widgetID, newID: widgetStruct)
        widgetID.config = widgetStruct.config
        modified = false
    }
}

struct SearchBarUIView: UIViewRepresentable {
    @Binding var text: String
    let placeHolder: String?
    var search: () -> Void
    init(text: Binding<String>, search: @escaping () -> Void, placeHolder: String? = nil) {
        self._text = text
        self.placeHolder = placeHolder
        self.search = search
    }
    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, searchAction: search)
    }
    
    func makeUIView(context: Context) -> UISearchBar {
        let searchBar = UISearchBar()
        searchBar.searchBarStyle = .minimal
        searchBar.delegate = context.coordinator
        if let placeHolder = self.placeHolder {
            searchBar.placeholder = placeHolder
        }
        return searchBar
    }
    func updateUIView(_ uiView: UISearchBar, context: Context) {
        
    }
    class Coordinator: NSObject, UISearchBarDelegate {
        @Binding var text: String
        var search: () -> Void
        public init(text: Binding<String>, searchAction: @escaping () -> Void) {
            self._text = text
            search = searchAction
        }
        func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
            self.text = searchText
        }
        func searchBarTextDidEndEditing(_ searchBar: UISearchBar) {
            searchBar.showsCancelButton = false
        }
        func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
            searchBar.showsCancelButton = true
        }
        func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
            searchBar.showsCancelButton = false
            searchBar.searchTextField.endEditing(true)
            self.text = ""
            searchBar.searchTextField.text = ""
        }
        func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
            search()
            UIApplication.shared.endEditing(true)
        }
    }
}

struct ListCell: View {
    var item: Location
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(item.id),\(item.name)")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.primary)
                Spacer()
            }
            HStack {
                Text("\(item.adm1),\(item.adm2)")
                    .lineLimit(1)
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
    }
}

// Update for iOS 15
// MARK: - UIApplication extension for resgning keyboard on pressing the cancel buttion of the search bar
extension UIApplication {
    /// Resigns the keyboard.
    ///
    /// Used for resigning the keyboard when pressing the cancel button in a searchbar based on [this](https://stackoverflow.com/a/58473985/3687284) solution.
    /// - Parameter force: set true to resign the keyboard.
    func endEditing(_ force: Bool) {
        let scenes = UIApplication.shared.connectedScenes
        let windowScene = scenes.first as? UIWindowScene
        let window = windowScene?.windows.first
        window?.endEditing(force)
    }
}

struct ResignKeyboardOnDragGesture: ViewModifier {
    var gesture = DragGesture().onChanged{_ in
        UIApplication.shared.endEditing(true)
    }
    func body(content: Content) -> some View {
        content.gesture(gesture)
    }
}

extension View {
    func resignKeyboardOnDragGesture() -> some View {
        return modifier(ResignKeyboardOnDragGesture())
    }
}

struct Location: Identifiable {
    var id: String
    var name: String
    var country: String
    var adm1: String
    var adm2: String
    var lat: String
    var lon: String
}