# Desktop app layer (MSIX): blank window, update loop, packaged service, launcher icon

Everything here is about the **packaged desktop app** (`OpenAI.Codex`), not the CLI. The CLI can be
healthy while the app is unusable, and vice versa — always establish which layer you are in first.

Identity you will need:

```
package name      : OpenAI.Codex
package family    : OpenAI.Codex_2p2nqsd0c76g0        (no version inside — stable across updates)
AUMID             : OpenAI.Codex_2p2nqsd0c76g0!App
profile (real)    : %LOCALAPPDATA%\Packages\<PFN>\LocalCache\Roaming\Codex\web\Codex
app logs          : %LOCALAPPDATA%\Packages\<PFN>\LocalCache\Local\Codex\Logs\<yyyy>\<MM>\<dd>\
```

---

## 1. Blank / white window (renderer not painting)

### Symptom

The window is blank, usually will not close, and Task Manager looks fine — many renderer/GPU
processes alive, main process `Responding=True`. That combination is the tell: the process is up,
the **compositor is wedged**.

### Diagnose: prove it instead of describing it

Two cheap facts separate "blank" from "I can't see it because it is behind something":

```powershell
# 1) does the window exist at all, and is it visible?
Get-Process -Name ChatGPT | Select-Object Id, Responding, MainWindowHandle, MainWindowTitle
```

`MainWindowHandle = 0` means no visible top-level window — but the window may still exist while
**hidden**. Enumerate every top-level window owned by the app's PIDs (`EnumWindows` +
`GetWindowThreadProcessId` + `IsWindowVisible`). A line like

```
hwnd=131514 pid=24528 title='ChatGPT'   visible=False
```

means "running but hidden". Call `ShowWindow(hwnd, 9)` (SW_RESTORE) then `ShowWindow(hwnd, 5)`
(SW_SHOW) and `SetForegroundWindow` — if the window becomes visible, the app was only hidden.

```powershell
# 2) is the window painting? capture the window's OWN content, even if occluded
#    PrintWindow(hwnd, hdc, 2)  # 2 = PW_RENDERFULLCONTENT
```

Then quantify the capture. A real UI and a blank one differ by orders of magnitude:

| Capture | PNG bytes (1094x763) | distinct colours (sampled grid) |
|---|---|---|
| blank white | ~4,700 | **1** |
| blank theme background | ~12,000 | **6** |
| healthy UI | ~66,000 | **88-89** |

Do **not** use `SCREEN` capture for this: a covered or off-screen window yields the desktop behind
it and you will wrongly conclude the app is fine.

### Fix

Kill the tree, clear the GPU/compositor caches (they regenerate), relaunch:

```powershell
# use scripts/fix-blank-window.ps1 in this skill
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile `
  -ExecutionPolicy Bypass -File '<skill-dir>\scripts\fix-blank-window.ps1'
```

Clearing these five is what actually matters — `Default\GPUCache`, `Default\DawnGraphiteCache`,
`Default\DawnWebGPUCache`, `ShaderCache`, `GrShaderCache`. Leave `Local Storage` and
`Session Storage` alone; those hold the user's UI state and sessions.

### What it is NOT

Check and rule out before blaming the app: no `Application Error` (1000) events, no Crashpad dump
(`...\Crashpad\reports` empty), no display-driver TDR (`System` log ids 4101/4099). If all three are
clean it is a wedged compositor, not a crash and not a driver fault.

### Why it recurs

Observed twice on the same machine, both times after the app **auto-started at logon** via the MSIX
startup task (`windows.startupTask` in the manifest, `Enabled="true"`). The app is up before the
desktop/GPU is ready, creates a hidden window and never paints. The same logon autostart is a
plausible source of "several warning dialogs at every boot".

Durable mitigation: disable the startup task (Task Manager → Startup apps → ChatGPT) and start the
app from a shortcut instead. Then the compositor gets a ready desktop.

---

## 2. Update loop: "prompts to update, updates, crashes, still prompts"

The app downloads successfully, then **fails to register**, so the old build stays active and the
prompt returns; the visible "crash" is the planned restart that swaps builds and finds nothing new.

Confirm it is the store agent, not a download problem:

```
# app log, every launch
[sparkle] Production Sparkle update event action=download_completed
          currentBuildNumber=20770 result=succeeded          <- download always succeeds
[windows-offers] Windows update eligibility canSilentlyDownload=true hasUpdate=true source=store
```

Then read the **Windows Error Reporting** events (`Application`, id 1001). The signature names the
exact failure:

```
Event: StoreAgentInstallFailure1
P1: Update;ChatGPT-SearchForUpdatesWithPausedAddAsync
P2: 80073cf6        <- or 80073cf9
```

| Code | Meaning |
|---|---|
| `0x80073CF6` | Package could not be registered |
| `0x80073CF9` | Install failed, package needs remediation |
| `0x80073D02` | Resources it modifies are in use |
| `0x80070430` | **ERROR_SERVICE_MARKED_FOR_DELETE** — "指定的服务已标记为删除" |
| `0x8007139F` | rollback failed: "组或资源的状态不是执行请求操作的正确状态" |

Note these failures may appear **only** in WER and `Get-AppPackageLog`, not in
`AppXDeploymentServer/Operational` — an empty deployment log does not mean the deployment is healthy.

### The `0x80070430` deadlock (the one that looks unfixable)

Get the real reason by forcing a registration and reading the error:

```powershell
$p = Get-AppxPackage -Name OpenAI.Codex
Add-AppxPackage -Register "$($p.InstallLocation)\AppxManifest.xml" -DisableDevelopmentMode
$log = Get-AppPackageLog -ActivityID <ActivityID printed by the failure>
$log | Select-Object -Last 20 | ForEach-Object { $_.Message }
```

Observed sequence, which explains every symptom at once:

```
servicing OLD package 26.1013 ... state set to disabled
PackagedServiceDEH analysed the manifest for DELETING 26.1013
error 0x80070430: cannot register windows.service extension: service marked for deletion
error 0x8007139F: rollback failed, resource not in correct state
error 0x80073CF6: package could not be registered / SingletonRegisterAdd failed
-> "Failed to reach state SingletonRegisterAdd"; package stuck at Status: Servicing
```

Circular dependency: the old package's service teardown marks the service for deletion; the new
package cannot register the same service name until that deletion completes; the pending delete only
completes at boot. Meanwhile the package sits in `Servicing`, so the AUMID still resolves but
**activation produces zero processes** — which the user experiences as "crash on launch".

### Fix: reboot

A reboot finalizes the pending service deletion; deployment then registers the service from the new
manifest and the package reaches `Ok`. Verified outcome on a real machine:

```
before                          after reboot
version  26.1013.4894.0         26.1021.3705.0
status   Servicing              Ok
service  START_TYPE 4 DISABLED  START_TYPE 2 AUTO_START, Running, path -> new dir
app      0 processes            starts (startup task)
```

Do not attempt `sc config` to fix the service (see §3) and do not "repair" the package before
rebooting — that is the case where a reboot is the only correct answer.

If a reboot is not acceptable, the remaining option is a full reinstall from the official installer.

---

## 3. The packaged service cannot be reconfigured with sc

Manifest declares:

```xml
<desktop6:Extension Category="windows.service"
    Executable="app/resources/codex-windows-sandbox-service.exe">
  <desktop6:Service Name="CodexSandboxService.OpenAI.Codex"
                     StartupType="auto" StartAccount="localSystem" />
</desktop6:Extension>
```

`sc qc` shows `TYPE: 210 WIN32_PACKAGED_PROCESS`. Its configuration belongs to the deployment
subsystem, so **even an elevated administrator gets `OpenService failed 5: access denied`** on
`sc config`, and `StartService` fails with `1058` (disabled). The registry key may well grant
Administrators FullControl — that is a red herring; the block is in the SCM, not the DACL.

Consequences for diagnosis:

- A packaged service stuck at `DISABLED` is usually a **deployment artifact**, not something a user
  did — and it will not be fixable by hand.
- It is restored by **redeploying the package** (successful update or reinstall), which re-applies
  `StartupType` from the manifest.
- While disabled, sandbox provisioning fails with `helper_read_acl_helper_spawn_failed`
  ("spawn read ACL helper failed"), because that helper is what the LocalSystem service spawns.

---

## 4. Desktop launcher with a real icon

A copy of `ChatGPT.exe` on the Desktop **will not run** — it is MSIX-packaged and needs its package
identity. Use a tiny launcher that activates the registered app:

```
explorer.exe shell:AppsFolder\OpenAI.Codex_2p2nqsd0c76g0!App
```

The AUMID uses the **PackageFamilyName**, which contains no version, so the launcher keeps working
across updates. It only breaks if the package `Name` or `Publisher` changes.

### Embedding the icon

`Add-Type -OutputAssembly` does not give icon control; compile with `csc` and `/win32icon`:

```powershell
$pkg  = Get-AppxPackage -Name OpenAI.Codex
$src  = Join-Path $pkg.InstallLocation 'app\resources\icon-chatgpt.ico'   # 8 sizes: 16..256
Copy-Item $src "$work\chatgpt.ico" -Force                                  # package path is version-specific
& "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe" `
    /nologo /target:winexe /optimize+ "/win32icon:$work\chatgpt.ico" `
    "/out:$work\chatgpt.exe" "$work\launcher.cs"
```

Verify the resource actually landed, and expect a size jump (4.6 KB without icon → ~112 KB with):

```powershell
# expect RT_ICON entries=8, RT_GROUP_ICON entries=1
# then confirm the artwork decodes:
python -c "from PIL import Image; im=Image.open('chatgpt.ico'); im.size=(256,256); im.load(); im.save('p.png')"
```

**Pitfall:** `[System.Drawing.Icon]::new($exeOrIco, 256, 256)` returns **random noise** for the
PNG-compressed 256px frame in this ICO (a .NET Framework/GDI+ limitation), and `Icon($exe, ...)`
can throw "parameter 'picture' must be an image usable as Icon". Use Pillow to verify the artwork,
and judge the embedded result by the PE resource counts, not by that API.

The icon is copied out of the package because its path embeds the version; re-run the copy after
every app update, or the icon eventually 404s and the Desktop shows a generic one.

---

## 5. Environment variables: the case-duplicate trap

If you add proxy env vars to help Codex, set them in the **same case the environment already uses**.
Windows env names are case-insensitive, but a Node/Electron parent may re-export
`http_proxy` as `HTTP_PROXY` (plus `NODE_USE_ENV_PROXY=1`), and PowerShell then fails with:

```
Get-ChildItem env:   -> 已添加了具有相同键的项。  (duplicate key)
Start-Process ... -RedirectStandardOutput ...  -> ArgumentException
```

Observed because uppercase `HTTP_PROXY`/`NO_PROXY` were written to `HKCU\Environment` while the
parent injected lowercase copies. Symptom was `Start-Process` throwing on every redirected spawn.

Check the real-world view (a process launched from Explorer gets a fresh environment from the
registry, unlike a child of your shell):

```
explorer.exe -> dump-env.cmd -> set | findstr /i proxy
```

Expect exactly one case per variable. If Codex still needs an explicit proxy, prefer the same case
the rest of the environment uses, and remember `NO_PROXY` must include `127.0.0.1`/`localhost` so the
`http://127.0.0.1:1455/auth/callback` OAuth callback is never routed through the proxy.
