import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return AppLocalization.text("Follow System")
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }

    public var locale: Locale {
        switch self {
        case .system: return AppLocalization.resolve(.system).locale
        case .english: return Locale(identifier: "en_US")
        case .simplifiedChinese: return Locale(identifier: "zh_Hans_CN")
        }
    }
}

public enum AppLocalization {
    // A single lock protects the app's preference when actor-isolated clients
    // produce errors or display models on background tasks.
    private final class LanguageStorage: @unchecked Sendable {
        private let lock = NSLock()
        private var value: AppLanguage = .system

        func read() -> AppLanguage {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func write(_ language: AppLanguage) {
            lock.lock()
            defer { lock.unlock() }
            value = language
        }
    }

    private static let storage = LanguageStorage()

    public static var language: AppLanguage {
        get { storage.read() }
        set { storage.write(newValue) }
    }

    /// Resolve the first supported system language, falling back to English.
    /// The app offers Simplified Chinese for every Chinese locale.
    public static func resolve(
        _ language: AppLanguage,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> AppLanguage {
        guard language == .system else { return language }
        for identifier in preferredLanguages {
            let base = identifier.lowercased().replacingOccurrences(of: "_", with: "-").split(separator: "-").first
            if base == "zh" { return .simplifiedChinese }
            if base == "en" { return .english }
        }
        return .english
    }

    public static var locale: Locale { resolve(language).locale }
    public static var isChinese: Bool { resolve(language) == .simplifiedChinese }

    public static func text(_ english: String) -> String {
        translated(english, language: resolve(language))
    }

    public static func format(_ englishFormat: String, _ arguments: CVarArg...) -> String {
        let resolved = resolve(language)
        return String(
            format: translated(englishFormat, language: resolved),
            locale: resolved.locale,
            arguments: arguments
        )
    }

    private static func translated(_ english: String, language: AppLanguage) -> String {
        language == .simplifiedChinese ? (simplifiedChinese[english] ?? english) : english
    }

    private static let simplifiedChinese: [String: String] = [
        "Tokens (M / B)": "用量（M / B）",
        "Point to or click a day to see usage.": "悬停或点击日期可查看每日用量。",
        "Clear day selection": "清除日期选择",
        "Account usage history": "账号用量历史",
        "Usage history": "用量历史",
        "Daily details and account totals": "每日明细与累计统计",
        "Recent quota changes": "近期配额变化",
        "No daily usage was reported for this period.": "所选时间范围内未提供每日用量。",
        "Account history is out of date. Refresh to update.": "账号用量历史已过期，请刷新。",
        "Awaiting quota update": "等待配额更新",
        "Last reported": "上次读取",
        "Last reported: %d%% remaining": "上次读取的余量：%d%%",
        "Out of date": "数据已过期",
        "Scheduled reset passed; awaiting updated account quota.": "已到计划重置时间，等待账号配额更新。",
        "View": "视图",
        "Overview": "概览",
        "Analytics": "分析",
        "Account usage": "账号使用情况",
        "Period": "时间范围",
        "%d days": "%d 天",
        "Newest first": "日期从新到旧",
        "Oldest first": "日期从旧到新",
        "Most tokens first": "用量从高到低",
        "Fewest tokens first": "用量从低到高",
        "Period total": "期间合计",
        "Reported total": "已提供记录合计",
        "Daily peak": "期间单日峰值",
        "Daily details": "每日明细",
        "Sort daily usage": "每日用量排序",
        "Find date: YYYY-MM-DD": "查找日期：YYYY-MM-DD",
        "Find usage by date": "按日期查找用量",
        "Active only": "仅看有用量",
        "Not reported": "未提供",
        "No matching daily records.": "没有符合条件的每日记录。",
        "%d of %d days reported · %d active days": "已提供 %d / %d 天记录 · %d 天有用量",
        "Missing days are not counted as zero. Totals include reported days only.": "缺失日期不按零计算，合计仅包含已提供的记录。",
        "Filters apply to daily details; the chart and totals show the selected period.": "筛选仅影响每日明细，图表与合计仍显示所选时间范围。",
        "Account totals": "账号累计统计",
        "Lifetime tokens": "累计 token",
        "All-time daily peak": "历史单日峰值",
        "Current streak (days)": "当前连续使用天数",
        "Longest streak (days)": "最长连续使用天数",
        "Loading account history…": "正在读取账号历史用量…",
        "Read daily usage from your Codex account.": "从 Codex 账号读取每日使用量。",
        "Account analytics unavailable": "账号用量分析不可用",
        "Daily account token usage": "账号每日 token 用量",
        "Codex did not provide daily detail for this account. Account totals are shown below.": "Codex 未提供此账号的每日明细，下方显示可用的账号累计统计。",
        "Account token history from Codex · dates follow Codex's daily buckets · refreshes every ten minutes": "用量历史来自 Codex 账号 · 日期沿用 Codex 统计口径 · 每十分钟刷新",
        "Daily tokens: ChatGPT usage analytics (Work and Codex). Account totals: Codex. Today may be incomplete or delayed. Refreshes every ten minutes.": "每日 token 来自 ChatGPT 用量分析（Work 和 Codex），账号累计统计来自 Codex。当日数据可能尚不完整或存在延迟，每十分钟刷新。",
        "ChatGPT usage (Work and Codex) · today may be incomplete": "ChatGPT 用量（Work 和 Codex）· 当日数据可能尚不完整",
        "Codex account totals": "Codex 账号累计统计",
        "Open Codex settings": "打开 Codex 设置",
        "Retry": "重试",
        "Expanded": "已展开",
        "Collapsed": "已收起",
        "%@: %@ tokens": "%@：%@ 个 token",
        "This Codex version does not provide account analytics. Update Codex and retry, or open Usage and billing → Analytics in Codex settings.": "此 Codex 版本未提供账号分析接口。请更新 Codex 后重试，或前往 Codex 设置中的“使用情况和计费 → 分析”查看。",
        "Codex returned account analytics in an unknown or inconsistent format.": "Codex 返回的账号分析格式未知或数据不一致。",
        "The signed-in account could not be verified. Retry after signing in to Codex.": "无法确认当前登录账号，请登录 Codex 后重试。",
        "waiting for account/usage/read": "等待账号用量分析回复",
        "account usage received": "已收到账号用量分析",
        "Quota history": "余量历史",
        "The account was removed, but its local quota history could not be deleted.": "账号已移除，但未能删除其本地余量历史。",
        "Percentage quota was not provided for this account.": "此账号未提供百分比配额。",
        "Available reset counts can change through grants, use or expiry; a count change does not prove a reset.": "可用次数可能因发放、使用或到期而变化，次数变化不能证明发生了重置。",
        "History: last observed %@ remaining each day. Blank days were not observed.": "历史：每天最后一次读取的%@余量，空白日期未采样。",
        "Account quota history": "账号余量历史",
        "All devices": "所有设备",
        "History starts with the first successful account quota read.": "首次成功读取账号配额后开始记录历史。",
        "Seven days · checks every two minutes": "最近七天 · 每两分钟读取一次",
        "Time": "时间",
        "Remaining quota": "剩余配额",
        "Account remaining quota history": "账号剩余配额历史",
        "First snapshot saved. Changes will appear after the next read.": "已保存首次快照，下次读取后显示变化。",
        "Credits balance": "账号积分余额",
        "Credits: %@ → %@": "积分余额：%@ → %@",
        "Banked resets: %d → %d": "可用重置次数：%d → %d",
        "Unlimited": "无限额",
        "Unavailable": "未提供",
        "No credits": "无积分",
        "Account credits returned by Codex, separate from included quota. No currency conversion is applied.": "Codex 返回的账号积分余额，与订阅配额分开显示，不换算为货币。",
        "Includes an unobserved interval; device and exact usage times are unknown.": "包含停机或断连期间的变化，无法判断使用设备及具体时间。",
        "Account snapshots include cloud and other devices. Gaps and resets break the line; usage across resets cannot be recovered.": "包含云端及其他设备的账号变化。未采样或重置处断开曲线，跨重置区间的消耗无法还原。",
        "Seven-day account remaining quota; blank days were not observed": "七天账号余量；空白日期未采样",
        "Quota history could not be saved. Current account quota is still available; changes may be lost after quitting.": "无法保存余量历史，当前账号配额仍正常显示；退出后可能丢失这段变化。",
        "Codex did not return a verifiable account identity. Current quota is shown without combining account history.": "Codex 未返回可验证的账号身份，当前仅显示配额，不合并历史记录。",
        "%@: first snapshot": "%@：首次快照",
        "%@: unchanged": "%@：余量未变",
        "%@: down %d points (%d%% → %d%%)": "%@：余量净减少 %d 个百分点（%d%% → %d%%）",
        "%@: new quota cycle, %d%% used; earlier interval usage unknown": "%@：已进入新配额周期，当前周期已用 %d%%；此前区间消耗未知",
        "%@: scheduled reset passed; waiting for updated quota": "%@：已到计划重置时间，等待配额更新",
        "Scheduled reset: %@ · Next reset: %@": "上次计划重置：%@ · 下次重置：%@",
        "Scheduled reset: %@": "计划重置：%@",
        "%@: quota increased; reset or adjustment": "%@：余量回升，可能发生重置或调整",
        "%@: window changed or unverified; interval usage unknown": "%@：配额窗口变更或无法确认，区间消耗未知",
        "%@: unavailable": "%@：未提供配额",
        "%lld-minute limit": "%lld 分钟限额",
        "Operation failed": "操作失败",
        "initialize rejected": "初始化被拒绝",
        "Process exit status: %d": "进程退出码：%d",
        "Codex process errors:\n%@": "Codex 进程错误：\n%@",
        " Resets %@.": " 于 %@ 重置。",
        " Weekly pace: %@.": " 每周用量进度：%@。",
        "%@ %lld saved": "已节省 %@ %lld",
        "%@ tokens": "%@ 个 token",
        "%@. %d percent used; %d percent expected by now.": "%@。已用百分之 %d；当前预计应使用百分之 %d。",
        "%@: %d%% remaining. %@.%@%@": "%@：剩余 %d%%。%@。%@%@",
        "%@: %lld tokens": "%@：%lld 个 token",
        "%d %@, %d %@ until reset": "%d%@%d%@后重置",
        "%lld available for this account": "此账号可用次数：%lld",
        "%d percent remaining": "剩余百分之 %d",
        "%d percent remaining, %@%@": "剩余百分之 %d，%@%@",
        "%d percent remaining.": "剩余百分之 %d。",
        "%d%% remains in the tightest window": "最紧张的用量周期还剩 %d%%",
        "%d%% remains. %@": "剩余 %d%%。%@",
        "%d%% used · %d%% expected by now": "已用 %d%% · 当前预计应使用 %d%%",
        "%lld-hour limit": "%lld 小时限额",
        "%dd": "%d天",
        "%dd %dh": "%d天%d小时",
        "%dh": "%d小时",
        ", weekly pace %@": "，每周用量进度 %@",
        "5-hour limit": "5 小时限额",
        "API prices checked 15 Jul 2026 · estimate only": "API 价格核对于 2026 年 7 月 15 日 · 仅供估算",
        "API-equivalent ≈ %@": "等效 API 费用 ≈ %@",
        "Account ready": "账号已就绪",
        "Account removed": "账号已移除",
        "Active account": "当前账号",
        "Active profile: %@ (%@)": "当前账号：%@（%@）",
        "Activity chart": "活动图表",
        "Add Codex account": "添加 Codex 账号",
        "Add account…": "添加账号…",
        "Add…": "添加…",
        "Banked resets": "已累积重置次数",
        "CODEX_HOME: %@": "CODEX_HOME：%@",
        "Cached input": "缓存输入",
        "Cancel": "取消",
        "Checking %@…": "正在检查 %@…",
        "Checking Codex usage": "正在检查 Codex 用量",
        "Checking Codex usage…": "正在检查 Codex 用量…",
        "Choose the installed Codex or ChatGPT app. QuotaBar will use its bundled Codex command-line tool.": "请选择已安装的 Codex 或 ChatGPT 应用。QuotaBar 将使用应用内置的用量服务，无需额外安装命令行工具。",
        "Choose a label. QuotaBar will open OpenAI's secure browser sign-in for a private profile on this Mac. Passwords and verification codes stay on OpenAI's page.": "输入账号名称。QuotaBar 将打开 OpenAI 的安全登录页面，并在此 Mac 上使用独立账号目录。密码和验证码仅在 OpenAI 页面输入。",
        "Choose whether to switch only QuotaBar, or also sign the Codex desktop app out and open OpenAI's secure browser login for this account.": "选择仅切换 QuotaBar，或同时退出 Codex 桌面应用，并通过 OpenAI 的安全浏览器登录此账号。",
        "QuotaBar diagnostics": "QuotaBar 诊断信息",
        "Codex account switch failed: %@": "Codex 账号切换失败：%@",
        "Codex account switched": "Codex 账号已切换",
        "Codex activity": "Codex 活动",
        "Codex could not be closed before signing out. Quit Codex and try again.": "退出登录前无法关闭 Codex。请先退出 Codex，再重试。",
        "Codex could not be opened: %@": "无法打开 Codex：%@",
        "Codex did not report a signed-in account after login.": "登录完成后，Codex 未返回已登录账号。",
        "Codex did not return usage data in time.": "Codex 未能及时返回用量数据。",
        "Codex is not installed in /Applications.": "未在 /Applications 中找到 Codex。",
        "Codex is not installed in a supported location.": "未在支持的位置找到 Codex 用量服务。",
        "Codex returned an unknown error.": "Codex 返回了未知错误。",
        "Codex returned an unsupported local usage record format.": "Codex 返回的本地用量记录格式不受支持。",
        "Codex returned usage data in an unknown format.": "Codex 返回的用量数据格式无法识别。",
        "Codex signed in as %@, not %@. Sign in again and choose the intended account.": "Codex 当前登录的是 %@，而非 %@。请重新登录并选择目标账号。",
        "Codex usage": "Codex 用量",
        "Codex usage is out of date. Last updated %@.": "Codex 用量已过期。上次更新于 %@。",
        "Codex usage is running low": "Codex 剩余用量不足",
        "Codex usage unavailable": "Codex 用量不可用",
        "Codex usage unavailable: %@": "Codex 用量不可用：%@",
        "Continue": "继续",
        "Copy Diagnostics": "复制诊断信息",
        "Could not find the usage service inside Codex. Select your installed Codex app.": "无法找到 Codex 桌面应用内的用量服务。请选择已安装的 Codex 应用。",
        "Could not start Codex: %@": "无法启动 Codex：%@",
        "Currency": "货币",
        "Current account: %@. Open account switcher": "当前账号：%@。打开账号切换菜单",
        "Daily limit": "每日限额",
        "Day": "日期",
        "Default": "默认",
        "Delete %@?": "删除 %@？",
        "Delete Account": "删除账号",
        "Delete account": "删除账号",
        "Delete…": "删除…",
        "Desktop switching uses OpenAI's secure sign-in.": "切换桌面账号使用 OpenAI 安全登录。",
        "Desktop app candidates:\n%@": "Codex 桌面应用候选路径：\n%@",
        "Display, alerts and accounts": "显示、提醒和账号",
        "Estimated savings versus GPT-5.6 Sol": "与 GPT-5.6 Sol 相比的估算节省",
        "Estimated savings vs GPT-5.6 Sol: %@": "相较 GPT-5.6 Sol 的预计节省：%@",
        "Executable: %@": "可执行文件：%@",
        "Executable search paths:\n%@": "可执行文件查找路径：\n%@",
        "Fallback USD price for unknown models": "未知模型的备用美元价格",
        "Follow System": "跟随系统",
        "Icon + percentage": "图标 + 百分比",
        "Icon only": "仅图标",
        "Input": "输入",
        "It resets %@.": "将于 %@ 重置。",
        "Language": "语言",
        "Last successful refresh: %@": "上次成功刷新：%@",
        "Last update is stale": "上次更新已过期",
        "Launch at login": "登录时启动",
        "Launch at login could not be changed: %@": "无法更改登录时启动设置：%@",
        "Less than 1 hour until reset": "距离重置不足 1 小时",
        "Local Codex session history could not be filtered.": "无法筛选本地 Codex 会话历史。",
        "Local Codex session history is not readable.": "无法读取本地 Codex 会话历史。",
        "Local activity": "本地活动",
        "Local activity unavailable": "本地活动不可用",
        "Local credentials were deleted": "本地登录凭据已删除",
        "Low-usage alert": "低配额提醒",
        "Menu bar": "菜单栏",
        "Menu bar display": "菜单栏显示",
        "QuotaBar + Codex": "QuotaBar + Codex",
        "QuotaBar Only": "仅 QuotaBar",
        "Nearly exhausted": "即将耗尽",
        "No Codex rate-limit windows were returned for this account.": "Codex 未返回此账号的用量限额。",
        "On pace": "进度正常",
        "Only used when a model has no bundled official price. USD per million tokens.": "仅用于尚未收录官方价格的模型，单位为美元 / 百万个 token。",
        "Open Codex": "打开 Codex",
        "Open Codex…": "打开 Codex…",
        "OpenAI did not return a banked reset count for this account": "OpenAI 未返回此账号的已累积重置次数",
        "OpenAI sign-in did not complete.": "OpenAI 登录未完成。",
        "OpenAI sign-in failed: %@": "OpenAI 登录失败：%@",
        "Output": "输出",
        "Percentage only": "仅百分比",
        "Process running: %@": "进程运行中：%@",
        "Protocol diagnostics: unavailable": "协议诊断信息不可用",
        "Protocol stage: %@": "协议阶段：%@",
        "Quit": "退出",
        "Quit QuotaBar": "退出 QuotaBar",
        "Refresh": "刷新",
        "Refresh Codex usage": "刷新 Codex 用量",
        "Refresh usage": "刷新用量",
        "Reset + percentage": "重置 + 百分比",
        "Reset banked": "已获得重置次数",
        "Reset credits currently available for this account": "此账号当前可用的重置次数",
        "Reset time unavailable": "重置时间不可用",
        "Resets %@": "%@重置",
        "Resetting now": "正在重置",
        "Running low": "配额不足",
        "Secure sign-in completed": "安全登录已完成",
        "Select Codex App…": "选择 Codex 应用…",
        "Settings": "设置",
        "Seven days · read from local session logs": "最近七天 · 读取本地会话日志",
        "Seven-day Codex activity": "最近七天的 Codex 活动",
        "Seven-day local token activity": "最近七天的本地 token 用量",
        "Signed in through the Codex app": "通过 Codex 应用登录",
        "Signing Codex out…": "正在退出 Codex…",
        "Switch Codex account": "切换 Codex 账号",
        "Switch QuotaBar": "切换 QuotaBar",
        "Switch to %@?": "切换到 %@？",
        "The Codex usage service stopped unexpectedly.": "Codex 用量服务意外停止。",
        "The OpenAI sign-in page could not be opened in your browser.": "无法在浏览器中打开 OpenAI 登录页面。",
        "The account profile could not be created: %@": "无法创建账号目录：%@",
        "The local account could not be deleted: %@": "无法删除本地账号：%@",
        "The local history filter could not be started.": "无法启动本地历史记录筛选器。",
        "The selected app is not a supported Codex desktop app with a bundled Codex command-line tool.": "所选应用不是受支持的 Codex 桌面应用，或其中缺少用量服务。",
        "The reset time is unavailable.": "重置时间不可用。",
        "This is the Codex desktop profile. QuotaBar will switch its usage view to the account currently signed in there.": "这是 Codex 桌面应用的账号。QuotaBar 将显示该应用当前登录账号的用量。",
        "This removes the locally saved Codex credentials and usage profile from this Mac. It does not delete the OpenAI account.": "这会删除此 Mac 上保存的 Codex 登录凭据和用量账号目录，不会删除 OpenAI 账号。",
        "Time: %@": "时间：%@",
        "Today %@": "今日 %@",
        "Token milestone": "Token 用量里程碑",
        "Tokens": "Token 数",
        "Try again": "重试",
        "Unpriced": "暂无价格",
        "Updated %@": "更新于 %@",
        "Usage data is unavailable.": "无法获取用量数据。",
        "Usage error: %@": "用量错误：%@",
        "Usage running low": "剩余用量不足",
        "Usage unavailable": "用量不可用",
        "Usage window": "用量周期",
        "Usage windows": "配额窗口",
        "Use account": "使用账号",
        "Version: %@": "版本：%@",
        "Waiting for secure OpenAI sign-in…": "正在等待 OpenAI 安全登录…",
        "Weekly limit": "每周限额",
        "Weekly pace": "每周用量进度",
        "Work": "工作",
        "You have used %lldM local tokens": "本地 Token 用量已达 %lld 百万",
        "app-server disconnected": "app-server 已断开连接",
        "day": "天",
        "days": "天",
        "default": "默认",
        "default CODEX_HOME": "默认 CODEX_HOME",
        "hour": "小时",
        "hours": "小时",
        "initialized": "已初始化",
        "isolated CODEX_HOME": "独立 CODEX_HOME",
        "isolated profile": "独立账号目录",
        "no": "否",
        "none": "无",
        "not resolved": "未找到",
        "not started": "尚未启动",
        "rate limits received": "已收到限额数据",
        "remaining": "剩余",
        "starting app-server": "正在启动 app-server",
        "tokens": "token",
        "usage is %@ ahead": "用量超前 %@",
        "usage is %@ under pace": "用量落后 %@",
        "waiting for account/rateLimits/read": "正在等待 account/rateLimits/read",
        "waiting for initialize response": "正在等待初始化响应",
        "yes": "是"
    ]
}
