# Codex Remote Mobile

[![CI](https://github.com/jiac78390-alt/codex-remote-mobile/actions/workflows/ci.yml/badge.svg)](https://github.com/jiac78390-alt/codex-remote-mobile/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

在 iPhone 或 iPad 上连接你自己的 Mac，查看和控制 Mac 上的 Codex 任务。

Codex Remote Mobile is an unofficial iPhone/iPad companion for Codex on your
own Mac.

> 当前版本为实验性预发布版。它不是 OpenAI 官方产品，也不是把 API Key
> 填进手机后直接请求模型的独立 API 客户端。

## 它适合谁

这个项目适合已经在 Mac 上使用 Codex App，并希望从手机或平板继续操作的用户。
无论 Mac Codex 使用 ChatGPT 登录，还是使用你配置的 API provider，登录、API
凭据、模型请求、工具和项目文件都留在 Mac 上；手机只保存配对密钥。

```text
iPhone / iPad
     |  authenticated WebSocket (LAN or Tailscale)
     v
CodexRemoteMac on your Mac
     |  local app-server / desktop IPC
     v
Codex App + your local projects
```

## 主要功能

- 浏览项目、任务和完整对话，查看实时输出、活动块、计划与文件变更。
- 新建任务、发送提示词、添加照片或文件、选择 Codex 已启用的插件技能。
- 选择模型和推理强度，处理中断、重连、授权请求与任务状态同步。
- 每个任务独立保存草稿；断网、切后台或重启后可靠补发未确认操作。
- 查看并管理 Mac Codex 中的自动化任务。
- iPhone 和 iPad 通用，最低 iOS/iPadOS 16。
- Mac companion 不需要屏幕录制、辅助功能或远程桌面权限。

## 系统要求

- macOS 13 或更高版本。
- 已安装、登录并能正常运行的 Codex App。
- 构建源码需要 Xcode 15 或更高版本。
- 运行完整离线测试需要 Node.js 20 或更高版本。
- 真机安装需要自己的 Apple ID/Apple Development Team 和唯一 Bundle ID。
- 远程使用推荐 Mac 与移动设备加入同一个 Tailscale 网络。

## 快速开始

### 1. 安装 Mac companion

从 [Releases](https://github.com/jiac78390-alt/codex-remote-mobile/releases)
下载 `CodexRemoteMac-v0.12.0.zip`，或从源码构建并安装：

```sh
git clone https://github.com/jiac78390-alt/codex-remote-mobile.git
cd codex-remote-mobile
/bin/zsh Scripts/install-mac.sh
```

源码安装会把 companion 放在 `~/Applications/CodexRemoteMac.app`，并创建当前
用户的 LaunchAgent。发布 ZIP 使用 ad-hoc 签名且未经 Apple 公证；更稳妥的方式
是检查源码后在自己的 Mac 上构建。

### 2. 在 iPhone/iPad 上构建

1. 用 Xcode 打开 `CodexRemoteIOS.xcodeproj`。
2. 选择 `CodexRemote` target 的 Signing & Capabilities。
3. 选择自己的 Team，并将 Bundle Identifier 改成你自己的唯一标识。
4. 连接 iPhone/iPad，选择设备后点击 Run。

仓库不会提供已签名 IPA。开发者签名和描述文件与 Apple Team、设备 UDID
绑定，上传作者自己的 IPA 既不能让其他设备直接安装，也会泄露设备信息。
使用免费 Apple ID 签名的真机 App 通常需要定期重新签名。

### 3. 配对

1. 保持 Mac 开机并启动 Codex Remote 菜单栏 companion。
2. 在菜单栏复制配对密钥。
3. 在 iOS App 中填写 Mac 的局域网或 Tailscale IP、端口 `8765` 和配对密钥。
4. 连接后选择项目和任务即可使用。

Mac 锁屏时 companion 可以继续运行；Mac 深度睡眠、手动睡眠或普通合盖休眠
时，本机程序和网络会暂停。

## 安全说明

- 只在可信局域网或自己的 Tailscale 网络中使用。
- 不要把 `8765` 端口直接映射到公网。
- 配对密钥等同于远程控制凭据，不要截图、提交到 Git 或发给他人。
- 普通局域网连接本身不是端到端加密通道；跨网络使用时依赖 Tailscale 加密。
- 单个预览文件上限 24 MB；只有当前任务中出现过的文件可以被下载预览。
- Codex 执行命令和修改文件时，权限仍由 Mac 上的 Codex 安全策略控制。

更完整的边界和漏洞报告方式见 [SECURITY.md](SECURITY.md)。

## 构建与测试

```sh
# Swift Package 的 Mac companion
swift build -c release

# Xcode Mac App（不需要开发者签名）
/bin/zsh Scripts/build-mac.sh

# iOS Simulator
/bin/zsh Scripts/build-ios-simulator.sh

# 全部离线回归测试
/bin/zsh Scripts/ci-check.sh

# 生成 ad-hoc 签名的 Mac 发布 ZIP
/bin/zsh Scripts/package-mac.sh
```

测试不会读取真实 Codex 对话、API Key、配对密钥或设备信息。需要运行中的 Codex
App、真实任务或真机的集成测试未包含在公开仓库的 CI 中。

## 当前限制

- 这是预发布版本，尚未经过独立安全审计。
- Mac 必须保持在线，手机不能脱离 Mac 独立运行 Codex。
- 没有 App Store/TestFlight 分发；iOS 真机需要用户自行签名。
- Mac 发布包未经 Apple 公证，适合愿意检查源码和自行构建的测试用户。
- 当前界面以中文为主。

## 开源许可

[MIT License](LICENSE)

## 免责声明

Codex Remote Mobile 是社区维护的非官方项目，与 OpenAI 无隶属、赞助或认可关系。
Codex、OpenAI 和相关商标归其各自权利人所有。
