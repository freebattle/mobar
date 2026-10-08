# MoBar

极简、美观的 macOS 原生任务栏状态监控 app。

菜单栏上两行两列，CPU 占用、内存占用、上下行网速一眼看完。没有窗口，没有设置页，没有 Dock 图标，零第三方依赖。

![版式预览](docs/preview.png)

上图是内置的版式自检渲染（`MoBar --render`），左列模拟深色菜单栏、右列模拟浅色菜单栏，五行分别是：和 Mole for Mac 同值、上下排位数不同、最宽取值加单位切换、精简模式、数据断流占位。

```
CPU  14%  ↑ 3.0 KB/s
MEM  61%  ↓  13 KB/s
```

## 特点

**看得清。** 整块内容画成 template image 交给系统着色，而不是自己挑颜色。自绘颜色在多屏幕环境下会翻车：同一时刻标签在一块屏上是纯白、在另一块屏上亮度只有 0.443 而背景是 0.399，几乎看不见。交给系统之后深色、浅色、菜单展开时的高亮反色都一并处理掉。

**不抖不错位。** 等宽数字字体，各列位置由固定锚点反算：百分比右对齐、速率数字右对齐向左伸缩、单位列左缘锚死。数值从 `13 KB/s` 跳到 `3.0 KB/s`、从 `999 KB/s` 跳到 `12.3 MB/s`，单位都待在原地不动。

**不依赖任何外部进程。** 直接读内核采样（`host_statistics` / `host_statistics64` / `getifaddrs`），2 秒一帧，没有子进程、没有 shell。

**小。** 约 1600 行 Swift，纯 AppKit，无第三方依赖，常驻内存约 48 MB、CPU 接近 0。

## 下载

[Releases](https://github.com/freebattle/mobar/releases) 里有编译好的通用二进制（arm64 + x86_64），160 KB，解压拖进「应用程序」就能用。

因为是本地签名（ad-hoc 或自签证书）、没走 Apple 公证，从浏览器下载的包带 quarantine 标记，首次打开会被 Gatekeeper 拦下。两种放行方式：

- 右键点 `MoBar.app` 选「打开」，在弹窗里再点一次「打开」
- 或者直接去掉标记：`xattr -dr com.apple.quarantine /Applications/MoBar.app`

不想跑来路不明的二进制，就照下面自己编，代码一共 1600 行出头。

## 自己编译

需要 macOS 13 或更新版本，以及 Xcode 命令行工具（`xcode-select --install`）。

```bash
git clone https://github.com/freebattle/mobar.git
cd mobar
./build-app.sh              # 只编当前架构，快
./build-app.sh --universal  # arm64 + x86_64 通用二进制
cp -R dist/MoBar.app /Applications/
open /Applications/MoBar.app
```

开机自启：系统设置 → 通用 → 登录项，添加 `/Applications/MoBar.app`。

打包用的是本机自签证书签名（首次跑一次 `./create-signing-identity.sh` 生成）。自签证书的 designated requirement 是证书指纹，固定不变，所以重新编译不会让辅助功能授权和登录项失效；没装证书的机器会自动退回 ad-hoc 签名，照样能用，只是每次重建都要重新授权一遍。

## 用法

点菜单栏上的读数弹出菜单：

| 菜单项 | 快捷键 | 说明 |
| --- | --- | --- |
| 显示 CPU / MEM 标签 | `L` | 关掉就只剩百分比和网速，宽度从 113pt 收到 87pt |
| 剪贴板历史 | | 默认开，记录复制的文字和图片 |
| 剪贴板历史 → 呼出快捷键 | | `⌘⇧V`（默认）/ `⌃⌥V` / `⌥V` / `⌥Space` |
| 剪贴板历史 → 清空历史记录 | | 二次确认 |
| 重启数据源 | `R` | 数据卡住时用 |
| 退出 MoBar | `Q` | |

两个开关存在 UserDefaults 里，重启后保留。鼠标悬停有 tooltip，显示完整读数。超过 7 秒没有新样本会显示 `--` 占位，不会停在最后一帧骗人。

## 剪贴板历史

按呼出快捷键，在鼠标位置弹出最近 200 条记录：`↑` `↓` 选择，`↩` 粘贴到当前输入位置，`⌘1`–`⌘9` 直接粘贴对应条目，`⌘⌫` 删除选中条目，直接打字就是搜索，`esc` 或点别处关闭。

自动粘贴靠模拟 `⌘V`，需要在「系统设置 → 隐私与安全性 → 辅助功能」里给 MoBar 授权；没授权时回车只把内容写回剪贴板。密码管理器标记为 concealed / transient 的内容和 Finder 复制的文件不会记录。历史存在 `~/Library/Application Support/MoBar/Clipboard/`。

## 数据源

全部原生，没有子进程也没有外部依赖：

- **CPU**：`host_statistics(HOST_CPU_LOAD_INFO)` 取 tick 差值。
- **内存**：`host_statistics64(HOST_VM_INFO64)` 取内存页统计，口径是 `used = total - free - inactive`。这不是活动监视器的口径，实测同一时刻活动监视器口径是 57.75%、这个口径是 60.43%。
- **网速**：`getifaddrs` 的 `AF_LINK` `if_data` 字节计数器差值。只统计名字是 `en* / eth* / bridge*` 且拿到了 IP 的接口；`utun` 系列 VPN 隧道会被排除，因为隧道流量同时也会走物理网卡，一起算就是双倍。

## 开发

```bash
swift build -c release                      # 只编译
.build/release/MoBar --render /tmp/p.png     # 渲染版式自检图，不进事件循环
MOBAR_DEBUG=1 .build/release/MoBar           # 前台跑，每帧样本打到 stderr
```

版式自检图覆盖了几种会挤动布局的取值组合，改动渲染代码之后先看它。项目里几次错位问题都是靠这张图加逐像素测量抓出来的。

源码结构：

| 文件 | 职责 |
| --- | --- |
| `MenuBarRenderer.swift` | 两行内容画成 template image，版式锚点都在这里 |
| `NativeMetricsSource.swift` | 内核采样 |
| `Metrics.swift` | `Sample` 结构、数值格式化 |
| `AppDelegate.swift` | NSStatusItem、菜单、断流判定 |
| `ClipboardStore.swift` | 剪贴板轮询、去重、持久化 |
| `ClipboardPanel.swift` | 剪贴板历史浮层与键盘交互 |
| `HotKey.swift` | Carbon 全局快捷键 |
| `Settings.swift` | 开关的 UserDefaults 读写 |
| `Preview.swift` | 离屏版式自检 |

版式是拿 Mole for Mac 的菜单栏 HUD 截图逐像素量出来的：8.5pt 等宽数字（字重用 medium，比原版 regular 略粗），行距 9pt，百分比列右缘 48.1pt、速率数字列右缘 79.5pt、单位列左缘 83.5pt。垂直居中不是写死的补偿值，而是 init 时离屏画一帧量 ink 包围盒算出来的，换字号字重会自动跟上。

## 已知限制

- **不走 App Store。** 本地签名（ad-hoc 或自签证书），不是开发者证书、也没有公证，所以下载后要手动放行一次。
- **x86_64 切片没在真 Intel 机器上跑过。** 通用二进制是在 Apple Silicon 上交叉编译的，x86_64 切片只经 Rosetta 验证过能启动、渲染输出和 arm64 一致。
- **单机口径。** 只报本机 CPU、内存、物理网卡速率，没有 GPU、温度、磁盘、进程列表。要这些用 `mo status`。

## 致谢

版式和内存口径参考了 [Mole](https://github.com/tw93/Mole)。菜单栏 HUD 是 Mole for Mac 的付费功能，MoBar 只是把这个两行版式在原生 AppKit 里复刻了一遍，数据默认自己采。

## License

MIT
