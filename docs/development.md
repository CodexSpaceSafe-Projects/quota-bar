# 开发指南

## 命名与依赖

应用与 Swift 包名称为 `QuotaBar`，仓库目录和命令为 `quota-bar`。应用、CLI 与共享代码分别位于 `Sources/QuotaBar`、`Sources/QuotaBarCLI` 和 `Sources/QuotaBarCore`。

应用和 CLI 仅依赖核心模块；核心模块不依赖 SwiftUI 或 AppKit。新增代码按职责放入现有子目录，避免把界面类型、网络请求和命令行参数放入同一个文件。Swift Package Manager 会递归发现各 target 目录中的 Swift 源文件，无需逐个登记。

`Application/QuotaBarApp.swift` 只负责 SwiftUI 入口；`AppDelegate.swift` 管理菜单栏与窗口生命周期，`UsageStore.swift` 管理可观察状态。独立界面模型放在 `Models/`，每日分析界面放在 `Features/Analytics/`。CLI 入口在 `QuotaBarCommand.swift`，命令逻辑与参数解析分别位于 `Commands/` 和 `Support/`。

## 测试

需要 Swift 6 和 Python 3。在项目根目录运行：

```sh
./scripts/test.sh
```

所有平台都会执行发布脚本和源码归档检查，以及 11 项核心 Swift 检查。macOS 还会执行 app-server 协议样本、Swift Package 构建、界面与图表测试，以及 CLI 冒烟测试。界面测试需要可用的 macOS 图形会话。

默认测试不连接已登录服务。仅在希望验证本机真实服务时使用：

```sh
./scripts/test.sh --live
```

测试清单集中在 `scripts/run-checks.py`。将新的离线检查按职责放入 `Tests/Checks/`，再登记其源文件依赖；macOS XCTest 放入 `Tests/QuotaBarTests/`。构建与发布配置见 [构建与发布](build-and-release.md)。

## 资源与兼容

`Resources/Assets/` 保存原始图标；`Resources/macOS/` 保存 bundle 元数据、安装说明和 `Localizations/*.lproj`。英文与简体中文的应用显示名均为 QuotaBar。`AppLocalization` 管理运行时文本。

现有 bundle identifier、偏好键以及旧账号和历史数据路径保留，用于升级兼容。不要仅因为路径中包含旧名称就直接更改它们；修改持久化位置需要明确的数据迁移方案。

## 导出源码

源码导出只包含当前提交中的文件，不包含未跟踪文件、构建缓存或安装产物：

```sh
python3 scripts/package-source.py
```

生成 `dist/quota-bar-source.zip` 和 `.zip.sha256`。输出目录可指定：

```sh
python3 scripts/package-source.py --output /path/to/quota-bar-source.zip
```

如果要交付一个含唯一初始提交的独立仓库，可在已经清除旧历史的仓库中执行：

```sh
python3 scripts/package-source.py --include-git
```

该模式会检查 Git 对象库中只有一个 commit 对象，再导出恢复仓库所需的数据。它不分发 hooks、远程地址、凭据助手、本地配置或 reflog。压缩包根目录固定为 `quota-bar/`。普通的源码导出不包含 `.git`。

脚本要求已提交所有被跟踪文件的修改。它只打包，不删除历史，也不推送或改写任何远程仓库。
