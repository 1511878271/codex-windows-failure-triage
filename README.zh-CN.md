# codex-windows-failure-triage

[English](README.md)

一个用于**在 Windows 上**排查 Codex 故障的 Codex skill：靠证据定位，而不是靠猜。

Windows 上 Codex 的故障是**分层**的 —— CLI、沙箱、打包的桌面端、网络路径、插件/运行时目录彼此独立，
而用户看到的症状通常离真正的原因还隔着一两层。这个 skill 固化了"该按什么顺序查"、每一层"用哪条命令
才能定性"，以及那些最浪费时间的坑。

## 覆盖的问题

| 用户描述 | 这个 skill 做什么 |
|---|---|
| "登录失败" | 把网络路径健康和账号状态分开；解释为什么在 TUN-only 代理下登录客户端的系统代理回退是死的，一次瞬时抖动就会硬失败 |
| `route-aware request timed out` / MCP、插件目录失败 | 判定为**沙箱 provisioning 状态**问题，而不是网络问题 |
| "沙箱初始化失败" | 定位读权限 ACL 阻塞（某个用户目录属主是 Administrators 且不给写权限）并修复；并说明 `codex doctor` 的沙箱判词是**历史记录**，可能是陈旧的 |
| "白框 / 白屏，关不掉" | 用 `PrintWindow` + 颜色数**证明**是不是空白，再通过重置 GPU/合成器缓存修复 |
| "提示更新 → 更新后闪退 → 又提示更新" | 识别 MSIX 注册失败（`0x80073CF6`、`0x80073CF9`、`0x80070430` 服务已标记为删除）以及只有重启才能解开的 `Servicing` 死锁 |
| 反复出现 `icon path with '..'` 告警 | 区分**两个不同的**图标 bug，并修正声明它们的 YAML |
| 每次开机弹好几个警告窗 | 指向 MSIX 启动任务在 GPU/桌面就绪前就把应用拉起来 |
| "这个文件夹里好多版本" | 审计 `bin\<hash>` 目录结构，以及更新后 `config.toml` 里每一处带版本号的路径 |

## 安装

直接 clone 到 Codex 的 skills 目录，让文件夹名与 skill 名一致：

```powershell
git clone https://github.com/1511878271/codex-windows-failure-triage `
  "$env:USERPROFILE\.codex\skills\codex-windows-failure-triage"
```

Codex 下次启动即加载。也可以手动复制文件夹进去。

## 使用

直接向 Codex 描述 Windows 上的 Codex 故障，skill 会自己被路由；或者先跑一次只读的证据收集器：

```powershell
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile `
  -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-failure-triage\scripts\collect-codex-evidence.ps1"
```

共 13 段：版本与真正在跑的二进制、账号状态、日志库保留窗口、近期错误、登录记录、route-aware 失败、
沙箱 provisioning、用户目录权限体检、网络五检、`codex doctor`、插件图标扫描、数据库空间病理、凭据结构。

## 快速修复

### 一、白框 / 白屏，关不掉

看起来像崩溃，实际不是。进程树是活的、主进程 `Responding=True`，但**画面不渲染**。

先证明，别猜：枚举应用的顶层窗口（窗口可能存在但 `visible=False`），并用
`PrintWindow(..., PW_RENDERFULLCONTENT)` 抓窗口**自身**内容 —— **不要用截屏**，被遮挡时会抓到后面的桌面。

| 抓取结果（1094×763） | PNG 大小 | 颜色数 |
|---|---|---|
| 空白 | ~5–12 KB | 1–6 |
| 正常 UI | ~66 KB | 88+ |

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\fix-blank-window.ps1
```

杀进程 → 清 5 个 GPU/合成器缓存（`Default\GPUCache`、`DawnGraphiteCache`、`DawnWebGPUCache`、
`ShaderCache`、`GrShaderCache`）→ 重启。`Local Storage` / `Session Storage` 会保留。

**预防**：它的复发场景是应用通过 MSIX 启动任务在**登录时自动启动**，此时 GPU/桌面还没就绪。
关掉那个启动任务（任务管理器 → 启动应用 → ChatGPT）即可。同一个自启也很可能是"每次开机弹一堆警告窗"的来源。

### 二、登录失败

**先查网络路径，再动 Codex 配置**，而且要多采样几次 —— 单次探测看着正常、实际节点在丢三分之一请求的情况很常见。

```powershell
# 1) 代理进程到底有没有开
Test-NetConnection 127.0.0.1 -Port 7897 -InformationLevel Quiet
# 2) TUN 适配器在不在（只开 WinINET 系统代理时，Rust/reqwest 是看不见的）
Get-NetAdapter | Where-Object { $_.InterfaceDescription -match 'TAP|TUN|Wintun|Mihomo' }
# 3) 节点出口在哪，OpenAI 认不认这个 IP
curl.exe -x http://127.0.0.1:7897 https://chatgpt.com/cdn-cgi/trace          # loc= / ip= / colo=
#    400 且带 OpenAI JSON = 请求真的到达了 OpenAI（IP 没问题）；403 / HTML = 节点被封
curl.exe -x http://127.0.0.1:7897 -X POST -H 'Content-Type: application/x-www-form-urlencoded' `
  --data 'grant_type=authorization_code&code=dummy&client_id=dummy' https://auth.openai.com/oauth/token
# 4) 存下来的 token 走这个节点到底能不能用
curl.exe -H "Authorization: Bearer <access_token>" -H "chatgpt-account-id: <account_id>" `
  https://chatgpt.com/backend-api/me                                        # 200 = 三者都通
```

**为什么一次抖动就致命**：登录客户端先直连，失败后记录
`oauth token connection failed; retrying with system proxy`。而在 TUN-only 方案下这条回退是**死的**：

- 代理侧写的是 `enable_system_proxy: false` → `ProxyEnable=0`，没有系统代理可供重试
- Codex 侧 `respect_system_proxy` 默认关闭（doctor 里显示 `respect system proxy  disabled`）

另外**先解 `id_token` 的 `exp`**：过期 token 仍会显示 "auth is configured"，逼你重新登录，而这跟你在查的故障无关。

### 三、图标问题（其实是两个互不相干的 bug）

**A. 日志刷 `ignoring interface.icon_small: icon path with '..' must resolve under plugin assets/`**

声明字段在 **YAML 而不是 JSON** 里 —— `skills\<skill>\agents\openai.yaml`。含 `..` 的路径即使能正确解析也会被拒绝，
所以要给该 skill 自己的 `assets/` 并用子级相对路径，且**两棵树都要改**（`.codex\plugins\cache\...` 与
`.cache\codex-runtimes\...`）：

```yaml
icon_small: "./assets/file-spreadsheet.png"
icon_large: "./assets/file-spreadsheet.png"
```

每次运行时更新都可能把它冲掉，甚至**新增**违规文件 —— 更新后要重扫。

**B. 桌面启动器图标是空白/通用图标**

原因就是那个 exe **没有图标资源**。用 `csc /win32icon:` 把应用包里的多尺寸图标嵌进去。
注意：**不能直接把 `ChatGPT.exe` 复制到桌面** —— 它是 MSIX 打包应用，需要包身份；要做一个激活
`shell:AppsFolder\OpenAI.Codex_<pfn>!App` 的启动器：

```powershell
$pkg = Get-AppxPackage -Name OpenAI.Codex
$ico = Join-Path $pkg.InstallLocation 'app\resources\icon-chatgpt.ico'   # 8 个尺寸，16–256
csc /nologo /target:winexe /optimize+ "/win32icon:$ico" "/out:chatgpt.exe" launcher.cs
```

体积应从 ~4.6 KB 变为 ~112 KB，并可用 PE 资源数验证（`RT_ICON` = 8，`RT_GROUP_ICON` = 1）。
**不要**用 `[System.Drawing.Icon]::new($ico,256,256)` 判断 —— 它对 PNG 压缩的 256px 帧会渲染成噪点。

## 目录结构

```
SKILL.md                            决策树（Step 0-7）+ 汇报规范
references/desktop-app.md           MSIX 深入：更新错误码、打包服务、白框、启动器图标
scripts/collect-codex-evidence.ps1  只读证据收集器（13 段）
scripts/fix-blank-window.ps1        合成器恢复
agents/openai.yaml                  UI 元数据
assets/icon.svg                     skill 图标
LICENSE / NOTICE                    Apache License 2.0 + 署名
```

## 说明

- 内容全部来自 Windows 11（`10.0.26200`）+ Codex CLI 0.160–0.164、桌面端 26.1013 / 26.1021 的真实故障，
  每一条修复都在对应机器上验证过。
- skill 里**刻意记录了没走通的路径**（一个从未复现的 Chromium profile 弹窗；一个其实是受限 shell 造成的
  `helper_read_acl_helper_spawn_failed`），避免下次重复踩坑。
- 部分段落假定包名为 `OpenAI.Codex`；代码对其他打包的 Electron 应用也适用，但路径是 Codex 专属的。

## License

[Apache License 2.0](LICENSE) —— 宽松许可，并且**包含明确的专利授权条款**，这也是它在企业场景下比 MIT 更稳妥的原因。

Copyright 2026 1511878271，署名信息见 [NOTICE](NOTICE)。

贡献代码默认按同一许可授权。
