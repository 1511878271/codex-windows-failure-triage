# codex-windows-failure-triage

[中文说明](README.zh-CN.md)

A Codex skill for diagnosing Codex failures **on Windows** from evidence instead of guesswork.

Codex on Windows fails in layers — the CLI, the sandbox, the packaged desktop app, the network path,
and the plugin/runtime trees are all independent, and the visible symptom is usually one or two
layers away from the cause. This skill encodes the order to check them in, the commands that
actually decide each layer, and the mistakes that waste hours.

## What it covers

| Symptom the user reports | What the skill does |
|---|---|
| "login failed" | Separates network-path health from auth state; explains why the login client's system-proxy fallback is dead on a TUN-only proxy and a single hiccup becomes fatal |
| "route-aware request timed out" / MCP or plugin catalog failures | Reframes them as sandbox provisioning state, not networking |
| "sandbox provisioning failed" | Finds the read-ACL blocker (a profile dir owned by Administrators) and repairs it; documents that `codex doctor`'s sandbox verdict is a *recorded* value that can be stale |
| "white / blank window, won't close" | Proves blankness with `PrintWindow` + colour counts, then fixes the wedged compositor via GPU-cache reset |
| "prompts to update, then crashes, still prompts" | Identifies MSIX registration failures (`0x80073CF6`, `0x80073CF9`, `0x80070430` service-marked-for-delete) and the `Servicing` deadlock that only a reboot clears |
| repeated `icon path with '..'` warnings | Distinguishes the two unrelated "icon bugs" and fixes the YAML that declares them |
| several warning dialogs at every boot | Points at the MSIX startup task auto-starting the app before the GPU/desktop is ready |
| "many versions in this folder" | Audits `bin\<hash>` layout and every versioned path in `config.toml` after an update |

## Install

Clone straight into your Codex skills directory so the folder name matches the skill name:

```powershell
git clone <repo-url> "$env:USERPROFILE\.codex\skills\codex-windows-failure-triage"
```

Codex picks it up on next start. Or copy the folder in manually.

## Use

Ask Codex about a Windows Codex failure and the skill routes itself, or run the evidence collector
first — it is read-only and gathers every source in one pass:

```powershell
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile `
  -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-failure-triage\scripts\collect-codex-evidence.ps1"
```

13 sections: versions and the running binary, auth state, log-DB retention window, recent errors,
login rows, route-aware failures, sandbox provisioning, profile-directory permission audit,
the five network checks, `codex doctor`, plugin-icon scan, database space pathology, credential shape.

Blank/white window recovery is one command:

```powershell
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile `
  -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-failure-triage\scripts\fix-blank-window.ps1"
```

## Quick fixes

The three failures people hit most often, with the shortest correct path to each. Full reasoning and
the rejected hypotheses are in `SKILL.md` and `references/desktop-app.md`.

### Blank / white window that will not close

Looks like a crash, is not one. The process tree stays alive and the main process reports
`Responding=True`, but nothing paints. Prove it before acting — enumerate the app's windows (a window
can exist with `visible=False`) and capture the window's **own** content with
`PrintWindow(..., PW_RENDERFULLCONTENT)`, not a screen grab:

| Capture (1094x763) | PNG size | distinct colours |
|---|---|---|
| blank | ~5-12 KB | 1-6 |
| real UI | ~66 KB | 88+ |

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\fix-blank-window.ps1
```

Kills the tree, clears the five GPU/compositor caches (`Default\GPUCache`, `DawnGraphiteCache`,
`DawnWebGPUCache`, `ShaderCache`, `GrShaderCache`) and relaunches. `Local Storage` /
`Session Storage` are preserved.

**Prevention:** it recurs when the app auto-starts at logon through its MSIX startup task, before the
GPU/desktop is ready. Disable that task (Task Manager → Startup apps → ChatGPT). The same autostart
is a likely source of "several warning dialogs at every boot".

### Login failed

Check the network path *before* touching Codex config, and sample it several times — a single probe
can look fine while the node is dropping a third of requests:

```powershell
# is a proxy even running?
Test-NetConnection 127.0.0.1 -Port 7897 -InformationLevel Quiet
# TUN adapter up? (a WinINET-only proxy is invisible to Rust/reqwest)
Get-NetAdapter | Where-Object { $_.InterfaceDescription -match 'TAP|TUN|Wintun|Mihomo' }
# where does the node exit, and does OpenAI accept that IP?
curl.exe -x http://127.0.0.1:7897 https://chatgpt.com/cdn-cgi/trace            # loc= / ip= / colo=
# 400 with OpenAI JSON = reached OpenAI (IP fine). 403/HTML = blocked node.
curl.exe -x http://127.0.0.1:7897 -X POST -H 'Content-Type: application/x-www-form-urlencoded' `
  --data 'grant_type=authorization_code&code=dummy&client_id=dummy' https://auth.openai.com/oauth/token
# does the stored token actually work through this node?
curl.exe -H "Authorization: Bearer <access_token>" -H "chatgpt-account-id: <account_id>" `
  https://chatgpt.com/backend-api/me                                          # 200 = all three OK
```

Why a single hiccup is fatal: the login client tries direct first, then logs
`oauth token connection failed; retrying with system proxy`. That fallback is dead on a TUN-only
setup — the proxy writes `enable_system_proxy: false` (so `ProxyEnable=0`, nothing to retry through)
and Codex's own `respect_system_proxy` defaults to disabled.

Also decode `id_token`'s `exp` first: an expired token still reports "auth is configured", and forces
a re-login unrelated to the fault you are chasing.

### Icon problems — there are two unrelated ones

**A. Log spam:** `ignoring interface.icon_small: icon path with '..' must resolve under plugin assets/`

The declaring fields live in **YAML, not JSON** — `skills\<skill>\agents\openai.yaml`. Any `..` is
rejected even when it resolves correctly, so give the skill its own `assets/` and use a child-relative
path, then patch **every** copy of the tree (`.codex\plugins\cache\...` *and*
`.cache\codex-runtimes\...`):

```yaml
icon_small: "./assets/file-spreadsheet.png"
icon_large: "./assets/file-spreadsheet.png"
```

Every bundle update can revert this and even add new offenders — re-scan after each update.

**B. The desktop launcher shows a blank/generic icon**

The executable simply has no icon resource. Embed the package's own multi-size icon with
`csc /win32icon:` (a copy of `ChatGPT.exe` will not run — it needs MSIX package identity, so use a
launcher that activates `shell:AppsFolder\OpenAI.Codex_<pfn>!App`):

```powershell
$pkg = Get-AppxPackage -Name OpenAI.Codex
$ico = Join-Path $pkg.InstallLocation 'app\resources\icon-chatgpt.ico'   # 8 sizes, 16-256
csc /nologo /target:winexe /optimize+ "/win32icon:$ico" "/out:chatgpt.exe" launcher.cs
```

Expect ~4.6 KB → ~112 KB, and verify by PE resource counts (`RT_ICON` = 8, `RT_GROUP_ICON` = 1).
Do **not** judge with `[System.Drawing.Icon]::new($ico,256,256)` — it returns noise for the
PNG-compressed 256px frame.

## Layout

```
SKILL.md                        the decision tree (steps 0-7) + reporting rules
references/desktop-app.md       MSIX deep dive: update codes, packaged service, blank window, launcher icon
scripts/collect-codex-evidence.ps1   read-only evidence collector (13 sections)
scripts/fix-blank-window.ps1         compositor recovery
agents/openai.yaml              UI metadata
assets/icon.svg                 skill icon
```

## Notes

- Everything here was derived from live incidents on Windows 11 (`10.0.26200`) with Codex CLI
  0.160-0.164 and desktop builds 26.1013 / 26.1021, and each fix was verified on the machine it was
  written for.
- The skill deliberately records **what did not pan out** (a Chromium profile dialog never
  reproduced; a `helper_read_acl_helper_spawn_failed` that was an artifact of a confined shell) so
  the next investigation does not re-walk dead ends.
- Some sections assume a Windows package named `OpenAI.Codex`; the code is general enough for other
  packaged Electron apps but the paths are Codex-specific.

## License

Not specified yet — add one before redistributing.
