<p align="center">
  <img src="Assets/AppIcon.png" width="112" alt="GuziPaste 谷穗剪贴板图标" />
</p>

<h1 align="center">GuziPaste</h1>
<p align="center">为 macOS 打造的剪贴板历史、收藏与快速翻译工具。</p>
<p align="center">macOS 原生应用 · 本机存储 · 个人及公司使用免费</p>

<p align="center">
<a href="https://www.producthunt.com/products/openpaste?embed=true&amp;utm_source=badge-featured&amp;utm_medium=badge&amp;utm_campaign=badge-openpaste" target="_blank" rel="noopener noreferrer"><img alt="上游 OpenPaste 的 Product Hunt 页面" width="250" height="54" src="https://api.producthunt.com/widgets/embed-image/v1/featured.svg?post_id=1287315&amp;theme=light&amp;t=1792549923566"></a>
</p>

<p align="center">
  <a href="https://github.com/Drangon-Li/OpenPaste/releases/latest">下载安装包</a> ·
  <a href="#使用">使用指南</a> ·
  <a href="https://github.com/SwallOwDili/OpenPaste">上游项目</a>
</p>

GuziPaste 将复制过的文字、链接、图片和文件引用放进贴近屏幕底部的横向卡片列表。通过键盘搜索、预览和取用，也可整理收藏分组、导入 Paste 历史，或连接自己的 OpenAI 兼容翻译服务。

## 维护分支与上游

本仓库由 Drangon-Li 独立维护，以 SwallOwDili 创建的 OpenPaste 提交 `c9a3bca` 为基线。维护分支保留原项目署名、版权与许可证。Copyright (C) 2026 SwallOwDili. [上游项目](https://github.com/SwallOwDili/OpenPaste)

这一版源码已集成三个提交给上游审阅的改动。

- 将更新残留目录的清理移到后台，避免目录访问拖慢启动。 [上游 PR #19](https://github.com/SwallOwDili/OpenPaste/pull/19)
- 改善卡片点击与多选双击取用，新增回车直接粘贴开关和开发版提示。 [上游 PR #20](https://github.com/SwallOwDili/OpenPaste/pull/20)
- 减少面板重复绘制，加入预览关闭动画，并保留动画期间的空格切换。 [上游 PR #21](https://github.com/SwallOwDili/OpenPaste/pull/21)

从 v0.2.0 起，本分支以 GuziPaste 名称和谷穗剪贴板图标发布，采用固定自签名身份。v0.1.0 使用 OpenPaste 名称和临时签名。 [维护分支 Releases](https://github.com/Drangon-Li/OpenPaste/releases)

## 界面预览

**贴近桌面的剪贴板卡片**：一屏浏览颜色、网页链接预览、代码语法高亮和图片，通过历史与收藏分组快速取用。

![OpenPaste 桌面功能示意：颜色、链接预览、代码高亮、图片及收藏分组](docs/images/feature-overview.png)

## 功能

| 功能 | 说明 |
| --- | --- |
| 剪贴板历史 | 保存文字、链接、图片、文件引用及可读取的原始格式，自动去重 |
| 搜索与筛选 | 搜索文字、链接、来源和已识别的图片文字，按类型、来源、日期和收藏筛选 |
| 收藏分组 | 自定义分组名称与颜色，收藏不受历史条数和保留时间清理影响 |
| 预览与编辑 | 空格查看完整内容，新建或编辑文字、重命名条目、旋转图片、提取图片文字 |
| 颜色 | 识别颜色值、显示色块，支持编辑颜色 |
| 代码 | 常见语言启发式识别、等宽字体和语法高亮；支持富文本取用与纯文本取用 |
| 链接与地图 | 网页标题和缩略图、Apple 地图位置预览；成功预览在本机缓存 7 天，缓存最多 100 MB；联网加载可关闭 |
| 批量操作 | 多选、批量粘贴、删除与撤销；图片和文件可拖出，接受能力取决于目标应用 |
| 粘贴队列 | 将所选条目加入队列，按顺序逐条取用，显示剩余数量 |
| 快速翻译 | 呼出时翻译选中文字，译文置顶，取用后替换原选区 |
| Paste 导入 | 本机导入历史、来源、收藏和原始格式，去重、备份并显示进度 |
| 数据目录 | 自定义保存目录、迁移历史与附件，支持选择 iCloud Drive 文件夹 |
| 关于与更新 | 查看许可，启动时检查本仓库新版本，可选择更新、稍后或跳过 |
| 登录启动 | 登录 Mac 时自动运行，可在通用设置中开启 |
| 记录控制 | 暂停记录、排除应用、历史条数和保留时间设置；清空历史时保留收藏 |

## 安装

需要 **macOS 14 或更新版本**。下载 `GuziPaste-0.2.1-macos-universal.zip`，解压后将 `GuziPaste.app` 放入「应用程序」。通用包包含 Apple Silicon 和 Intel 架构。 [下载 v0.2.1](https://github.com/Drangon-Li/OpenPaste/releases/tag/v0.2.1)

从 v0.1.0 或上游 OpenPaste 换装时，先退出旧版并备份当前数据目录，保留旧应用副本以便回退，再将应用程序目录中的旧版移出、放入 GuziPaste。两者使用相同的应用标识和默认数据目录，GuziPaste 会继续读取现有历史、收藏及设置。

安装包使用固定自签名证书，尚未经过 Apple Developer ID 签名和公证。首次打开若被 macOS 阻止，确认来源和校验值后，可在「系统设置 → 隐私与安全性」选择「仍要打开」。从临时签名版首次换装后，直接粘贴可能需要在「辅助功能」中重新授权 GuziPaste。 [Apple 打开说明](https://support.apple.com/zh-cn/102445)

ZIP 同页提供 SHA-256 文件。下载两个文件到同一目录后，可运行 `shasum -a 256 -c GuziPaste-0.2.1-macos-universal.sha256` 核对。

如需从源码构建，安装 **Xcode Command Line Tools** 后执行以下命令，首次构建会联网下载 Swift 依赖。

```sh
xcode-select --install  # 已安装时可跳过
git clone https://github.com/Drangon-Li/OpenPaste.git
cd OpenPaste
./build.sh
open build/GuziPaste.app
```

源码构建默认使用临时签名。使用固定签名构建的方法见开发文档，重新构建后如需恢复直接粘贴，可在 **系统设置 → 隐私与安全性 → 辅助功能** 中为当前应用重新授权。 [开发文档](docs/DEVELOPMENT.md)

上游提供自己的通用安装包，安装说明与签名情况见上游发行页。 [上游 Releases](https://github.com/SwallOwDili/OpenPaste/releases)

## 检查更新

「设置 → 关于 → 软件更新」中的自动检查开启后，每次启动会异步查询本仓库，持续运行时每天检查一次。新安装默认开启，已有明确开关设置会保留。发现新版时可选择更新、稍后或跳过，手动检查可重新查看被跳过的版本。 [维护分支 Releases](https://github.com/Drangon-Li/OpenPaste/releases)

应用内更新校验 SHA-256、应用标识、版本和签名。固定证书签名的版本可更新到同一身份的新版。从临时签名的 v0.1.0 换到首个固定签名版，需要手动替换，并可能重新授予辅助功能权限。后续版本应持续使用同一证书，macOS 仍可能因系统或安装状态要求重新授权。

源码副本可执行 `git pull --ff-only` 并重新运行 `./build.sh`。在「设置 → 通用 → 启动」可开启登录 Mac 时启动 GuziPaste，系统要求批准时会提供登录项设置入口。

## 使用

首次运行时启用记录，按 **⌘⇧V** 呼出历史。快捷键可以在设置中录制，支持 **Command + 按键**，也支持 Control、Option 及组合修饰键；已有用户保留自己的配置。

从 v0.2.1 起，可在「设置 → 通用 → 外观」选择是否显示菜单栏图标、切换跟随系统／浅色／深色外观，以及开启或关闭预览动画。隐藏菜单栏图标后，可用呼出快捷键进入面板，再从更多菜单打开设置。

在「设置 → 隐私与权限」点击「授权指引」，可将浮窗里的 GuziPaste 图标拖到系统辅助功能列表，并开启权限。浮窗会显示当前运行的应用位置和授权状态，也可在访达中定位应用。如果 macOS 从系统临时转移路径（App Translocation）运行 GuziPaste，指引会提示先将应用放入「应用程序」，再从那里重新打开。

「设置 → 隐私与权限 → 按回车直接粘贴」默认开启。系统已授权时，回车会粘贴回原输入框。关闭开关或系统尚未授权时，回车只复制，之后可手动按 ⌘V。

| 快捷键 | 操作 |
| --- | --- |
| ← / → | 选择条目 |
| Return | 按「按回车直接粘贴」设置取用。开关关闭或未授权时只复制 |
| ⇧Return | 纯文本取用（⇧ 可在设置中更改，快速粘贴同样适用） |
| ⌘1–9 | 快速取用对应条目（修饰键可在设置中更改） |
| ⌘F | 搜索 |
| ⌘N | 新建文字 |
| ⌘Return | 取用粘贴队列下一条 |
| ⌘← / ⌘→ | 切换上一个 / 下一个收藏分组（含“历史”，循环；可在设置中更改） |
| Space | 打开或关闭完整预览，连续按三次会打开、关闭、再打开。预览中 ← / → 切换条目，Esc 关闭 |
| ⌘E / ⌘R / ⌘O | 编辑 / 重命名（卡片标题就地修改，不改内容）/ 打开 |
| 鼠标滚轮 | 在卡片列表中直接横向滚动 |
| ⌘⌫ | 删除选中条目 |
| 按住 ⌘⇧ | 临时反转列表，释放后恢复 |
| ⌘⇧⌫ | 从反转列表中删除，可连续删除较早条目 |
| ⌘Z | 撤销最近的条目操作 |
| ⌘, | 设置 |
| Esc | 关闭当前面板或设置窗口 |

退出程序可在设置左下角点击 **退出 GuziPaste**，或从菜单栏菜单选择退出；关闭设置窗口不会退出程序。

多选支持 ⌘ 点击切换条目、Shift 点击或方向键选择范围。双击所选卡片之一会取用整组，双击未选卡片会取用该条。也可以从面板右上角选择 **所选加入粘贴队列**，再按 ⌘Return 逐条取用。点击“结束”可清空队列。代码样式是否保留，取决于目标应用是否接受 RTF / HTML。普通文本输入框会收到原文。

## 快速翻译

在「设置 → 快速翻译」开启功能，填写 **Base URL、API Key、模型和目标语言**，然后保存。

下面的地址和模型是演示占位值，使用时需填写自己的服务配置。

```text
Base URL: https://your-service.example/v1
模型:     服务支持的模型名称
目标语言: 英文
```

选中文字后呼出剪贴板，译文会出现在第一张卡片。开启回车直接粘贴且系统已授权时，按回车可在原输入框替换选区。关闭开关时可以复制译文后手动粘贴。生成失败或未取用时不会覆盖原文。

- 支持 HTTP 和 HTTPS。HTTP 会明文传输 API Key 与选中文字。
- API Key 与其他设置一同保存在本机应用配置中（`~/Library/Preferences/io.github.SwallOwDili.OpenPaste.plist`），不随剪贴板历史同步；选中文字发送到你配置的服务。
- 不接受 URL 内账号、查询参数或片段；不跟随重定向。
- 选中文字上限 60 KB。辅助功能选区读取不被目标应用支持时，会尝试复制选区并恢复剪贴板。

<details>
<summary>查看通用设置：快捷键、历史保留与内容预览</summary>

<p align="center">
  <img src="docs/images/settings-general.jpg" width="760" alt="通用设置：呼出快捷键、历史条数、保留时间、网页地图预览与图片文字识别" />
</p>

</details>

## 数据存储与 iCloud Drive

历史默认保存在 `~/Library/Application Support/OpenPaste/`。

在「设置 → 数据管理 → 更改目录」选择专用文件夹。历史、收藏和附件一起迁移，目标已有历史会合并；迁移显示进度，校验成功后切换，源目录保留。

在「设置 → 数据管理 → iCloud Drive 同步」选择 **启用 iCloud Drive 同步**，选择 iCloud Drive 中的专用文件夹。另一台 Mac 使用同一 Apple 账户并选择同一文件夹，可读取和合并历史。界面显示本机缓存、等待同步及读写结果，并提供检查或重试入口。云端暂不可用时，成功写入本机缓存的新增内容可继续记录；缓存也无法保存时会暂停记录并提示处理。

首次选择云端目录时，如果清单或附件尚未下载，GuziPaste 会在后台请求下载并自动重试，等待期间继续使用原目录记录。可以随时取消切换；下载完成后会合并等待期间新增的历史，校验后再切换。真正损坏或无法访问的数据仍会提示错误并保留原目录。

同步速度取决于 iCloud 和网络，可能存在延迟。为保护离线设备仍可能引用的内容，共享目录中的附件不会自动回收；本地历史与本机离线缓存会回收无引用附件，撤销记录和备份仍需使用的附件会保留。请勿单独移动或删除数据目录内的文件。

本机离线缓存位于 `~/Library/Application Support/OpenPaste-sync-cache`。API Key、快捷键、权限和其他偏好不随历史同步。文件条目只保存原路径引用，另一台 Mac 不一定能访问该文件。

## 隐私与限制

GuziPaste 无需账号，剪贴板历史默认保存在本机。以下功能会使用网络：

| 功能 | 联网用途 |
| --- | --- |
| 网页与地图预览 | 访问对应网页及 Apple 地图，可在通用设置中关闭新预览请求；内网地址和疑似验证链接需点击加载 |
| 快速翻译 | 将选中文字发送给你配置的翻译服务 |
| 检查更新 | 向 GitHub 查询公开 Release 信息 |
| iCloud Drive | 选择 iCloud 目录后，由 macOS 同步历史与附件 |
| 使用统计 | 上游 Release 默认开启 Google Firebase Analytics，可在隐私设置中关闭。此 fork 的源码构建未配置 Firebase 时不启用统计 |

OpenPaste 主动记录的统计仅包含三项，不附带内容参数：

| 统计 | 含义 |
| --- | --- |
| 首次启动 | 用于估算安装量；安装但从未打开的 App 不会计入 |
| 自动粘贴 | 成功发送自动粘贴快捷键的次数；仅复制不计入，不代表目标应用已接收内容 |
| 翻译成功 | 成功完成翻译的次数 |

Firebase SDK 还会处理应用实例标识、设备与应用版本等基础信息，并可能产生自动事件；统计不是严格的下载安装计数。OpenPaste 不向统计服务发送剪贴板内容、所选文字、网址、文件路径或翻译 API Key。

可在 **设置 → 隐私与权限** 关闭统计，关闭后停止收集并清除本机统计标识。**关于** 页面提供当前统计状态及数据说明。自行构建且未提供 Firebase 配置时不启用统计。

预览地址检查属于保守规则，不能识别所有一次性链接，也不保证阻止 DNS 解析或重定向后的内网访问。不希望复制链接时联网，可关闭网页与地图预览。

历史未单独加密。默认排除常见密码管理器及带敏感标记的剪贴板内容，但不能可靠识别普通文字中的密码。可按需要排除应用或暂停记录。

暂停状态在退出和重启后保留。恢复后只记录新的复制，不补录暂停期间留在剪贴板中的内容。“直到手动恢复”需要主动继续记录；定时暂停按原到期时间恢复，重启不会延长暂停时间。

- 极短时间内连续复制的中间内容可能漏记。
- 条数可设为不限制，但总容量仍有上限；单条超过 20 MB 时跳过。
- 来源根据捕获时的前台应用推断，不保证完全准确。
- 代码语言识别为启发式；地图链接、网页预览和拖放不能覆盖所有格式与应用。
- 实体多 Mac 的 iCloud 同步、长期运行及多显示器场景尚未完整验证。

## 反馈与贡献

维护分支的代码改动可以向本仓库提交 PR。反馈上游版本的问题时，请在上游说明 macOS 版本和操作步骤，并遮挡截图中的私人内容。 [本仓库 PR](https://github.com/Drangon-Li/OpenPaste/pulls) · [上游 Issues](https://github.com/SwallOwDili/OpenPaste/issues)

向上游提交贡献时，请阅读上游的 [CLA 英文原文](CLA.md)或[中文译文](CLA.zh-CN.md)，并按上游 PR 中的提示用自己的 GitHub 账号回复：

> I have read and agree to the OpenPaste CLA v1.0.

同一版本只需签署一次；多位贡献者需逐人签署，维护者也适用。CLA 保留贡献者著作权，并允许项目商业再授权。报告问题无需签署。

上游贡献和发布流程保留在 [贡献指南](CONTRIBUTING.md) 与 [开发文档](docs/DEVELOPMENT.md) 中。开发文档中的本地构建和检查命令也可用于维护分支。

## 许可证

采用 [GNU GPL v3（仅第 3 版）](LICENSE)，并附有依据第 7(b) 条制定的[署名保留条款](NOTICE)。

个人及公司内部使用免费，可自行修改；内部使用无需对外公开修改源码。

对外发行（包括收费售卖）须提供对应源码，保留署名、版权声明和许可证，注明修改，并保留接收者的 GPL 权利。有交互界面的发行版本须在「关于」或法律声明中清晰展示 [原项目地址](https://github.com/SwallOwDili/OpenPaste)、版权声明和许可证入口。

闭源发行、免除 GPL 义务或移除规定的项目声明，需联系作者获取单独的付费书面授权。符合 GPL 的收费发行无需另付授权费；单独授权不免除第三方声明义务。详细规则见 [许可说明](docs/LICENSING.md)。

App 内置中英文许可与署名文件，可在「关于」中查看；中文为参考译文，法律条款以英文原文为准。
