---
name: codex-windows-failure-triage
description: Triage Codex failures on Windows from evidence rather than guesswork - OAuth login that never persists, "route-aware request timed out" / "application network permission was revoked", MCP servers or plugin catalogs that fail to load, Windows sandbox provisioning failures, repeated plugin-icon warnings, and Chromium profile warnings in the desktop app. Use when Codex login fails, a user reports version skew across several Codex installs, or codex doctor reports a sandbox failure.
---

# Codex Windows Failure Triage

Codex on Windows fails in layers, and the visible symptom is usually two layers away from the
cause. Work top-down through the evidence sources below instead of trusting the first error text.

Run `scripts/collect-codex-evidence.ps1` first; it is read-only and gathers every source in one pass.
A machine with an undefined execution policy will refuse to load it, so invoke it explicitly:

```powershell
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile `
  -ExecutionPolicy Bypass -File '<skill-dir>\scripts\collect-codex-evidence.ps1'
```

## Ground rules

- **`logs_2.sqlite` is a ring buffer.** It retained only ~2,300 rows (~15 minutes) in one observed
  incident, and rows read at T were already deleted at T+2min. Capture the log *immediately* after
  a failure, before anything else.
- **`codex doctor` is the authority**, not the log tail. It reports recorded, structured state
  (including the last sandbox provisioning failure) that the log may have already rotated away.
- **But its sandbox verdict is a *recorded* verdict, not a live test.** It reads the last
  `setup_error.json`, so it can keep reporting `sandbox provisioning failed` after the cause is
  gone — one machine showed `failed` for an error written *before a reboot*. Confirm with a real
  run (`codex sandbox -- cmd.exe /c echo ok`, file-redirected) before believing either a red or a
  green sandbox line, and expect a successful run to delete `setup_error.json`.
- Login uses a **plain** HTTP client; MCP, plugin catalogs and sandboxed egress use the
  **route-aware** client. One working while the other fails is a signal, not a contradiction.
- Never conclude "the network is down" from Codex alone. Always test the same URL with `curl.exe`
  as a control, and check whether it resolves into a proxy's fake-IP range.
- **Establish the network path before reading any Codex error** (Step 0, the first section below).
  Five cheap checks tell you whether the fault is the tunnel being off, the exit country, the node's
  IP reputation, the stored token, or genuinely Codex. Skipping them is how an edge 403 gets
  misreported as a login bug, and how a perfectly good Codex install gets "repaired" for someone
  else's outage. This is also the step that most often ends the investigation with no Codex change
  needed at all.

## Step 0 - Prove where the network actually breaks (VPN / proxy / node)

Run this before blaming Codex. Each check is cheap and decisive, and they are ordered so the
cheapest possible cause is eliminated first.

**1. Is a proxy process even running?**

```powershell
Test-NetConnection 127.0.0.1 -Port <port> -InformationLevel Quiet
```

Never infer this from a config file: a saved config with the app closed is the single most common
cause, and the one people skip because everything *looks* configured.

**2. TUN mode, or only the Windows system proxy?**

```powershell
Get-NetAdapter | Where-Object { $_.InterfaceDescription -match 'TAP|TUN|Wireguard|Mihomo|Wintun' } |
    Select-Object Name, InterfaceDescription, Status
Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' |
    Select-Object ProxyEnable, ProxyServer
```

These two are **not** equivalent for Codex. `HKCU\...\Internet Settings` is WinINET, read by
browsers and .NET but **not** by Rust/reqwest, which is what Codex is. Codex honours only
`HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY` / `NO_PROXY` (either case) and `NO_PROXY`.

So with TUN off and only the system proxy enabled, browsers and `codex login` diverge: the browser
sign-in page loads, and Codex itself goes **direct** and fails. A tunnel adapter that is `Up` means
the OS captures traffic at the network layer and Codex needs no proxy awareness at all. Corroborate
through DNS: addresses inside `198.18.0.0/15` are a proxy's fake-IP range, which only appears while
the TUN resolver is active.

**3. Where does the node actually exit?**

```powershell
curl.exe -x http://127.0.0.1:<port> https://chatgpt.com/cdn-cgi/trace
```

Read `loc=`, `ip=`, `colo=`. OpenAI does not serve every country: an exit in an unsupported region
fails sign-in however healthy the tunnel looks. This is the check that separates "the network is
broken" from "the network is fine but this exit is not allowed". Note the address family too - an
IPv6-only exit can be flagged where the same node's IPv4 is not.

**4. Is this node's IP acceptable to OpenAI?**

Send a deliberately malformed token request and read the status class:

```powershell
curl.exe -x http://127.0.0.1:<port> -X POST -H 'Content-Type: application/x-www-form-urlencoded' `
  --data 'grant_type=authorization_code&code=dummy&client_id=dummy' `
  https://auth.openai.com/oauth/token
```

- **400 carrying an OpenAI JSON error** - the request reached OpenAI and was processed. IP and
  region are fine. This is a pass, and a positive result is worth stating as such.
- **403, an HTML Cloudflare page, or `unsupported_country_region_territory`** - the node or its
  region is blocked. Change nodes; do not touch Codex config.

**5. Does the stored credential actually work through this node?**

A present `auth.json` proves only that something was written.

```powershell
curl.exe -x http://127.0.0.1:<port> -H "Authorization: Bearer <access_token>" `
  -H "chatgpt-account-id: <account_id>" https://chatgpt.com/backend-api/me
```

- **200** returns the account object: token, account and node all genuinely work, so any remaining
  failure is local to Codex. This is the strongest single signal available.
- **401** - re-login.
- **403 while check 4 passed** - the account, not the network.

Also decode `id_token`'s `exp` instead of trusting `last_refresh`; a failing refresh still reports
as "configured".

**6. Sample the node; do not probe it once.**

Checks 4 and 5 prove the node is *allowed*. They do not prove it is *usable*. A node can pass both
and still break Codex, because Codex has internal deadlines (MCP handshake ~30 s, model-catalog and
route-aware requests shorter) that a slow or lossy node silently exceeds.

Run each endpoint several times and record the success rate and spread:

```powershell
foreach ($u in @('https://chatgpt.com/cdn-cgi/trace','https://mcp.context7.com/mcp')) {
  $ok = 0; $t = @()
  1..6 | ForEach-Object {
    $r = & curl.exe -sS --max-time 15 -o NUL -w "%{http_code} %{time_total}" $u 2>&1
    if ($LASTEXITCODE -eq 0) { $ok++; $t += [math]::Round([double]($r -split ' ')[1], 1) }
  }
  Write-Output ("{0}  ok={1}/6  times={2}" -f $u, $ok, ($t -join ','))
}
```

One observed incident, same machine, three days apart:

| | healthy node | degraded node |
|---|---|---|
| exit | `loc=US colo=SJC` | `loc=SG colo=SIN` |
| `chatgpt.com` | 200, ~1 s | 200, **4.9-10.6 s**, some 20 s timeouts |
| `mcp.context7.com` | 405, ~1.2 s | **0/6 - every attempt timed out** |
| malformed oauth POST | 400 | 400 (still accepted) |

The node was never blocked - it was simply too slow, which surfaced in Codex as
`list_models ... request timed out`, `route-aware request timed out` on the plugin catalog, and
`timed out handshaking with MCP server after 29.999995s`. **A passing check 4 with a failing
check 6 means "change nodes", not "repair Codex".** Report the numbers; they are what convinces a
user the fault is upstream of Codex - and note that a single probe would have looked healthy.


## Step 1 - Identify which binary is actually running

Windows keeps several Codex versions side by side. Compare, in this order:

1. The running process and its parent (`Get-CimInstance Win32_Process`), because the parent decides
   which app owns the app-server.
2. `CODEX_CLI_PATH` in `%USERPROFILE%\.codex\config.toml`.
3. Loose vs hashed binaries in `%LOCALAPPDATA%\OpenAI\Codex\bin\`.

Layout to expect:

```
bin\codex.exe                     <- legacy loose binary, easy to mistake for "the" version
bin\<hash>\codex.exe              <- current CLI; CODEX_CLI_PATH should point here
bin\<hash>\rg.exe                 <- ripgrep for that build; pairs with a *different* hash
bin\codex-windows-sandbox-setup.exe  <- legacy duplicate of the hashed one
```

- A loose `bin\codex.exe` reporting something like `0.130.0-alpha.5` while the hashed dir holds a
  300 MB binary a month newer **is** the "many versions, startup version differs" complaint.
- **Do not delete an orphan-looking `bin\<hash>\` on sight.** A directory holding only `rg.exe` and
  created within seconds of the current `codex.exe` is that build's ripgrep, not garbage. Check the
  file timestamps against the current binary before removing anything.
- Quarantine (move to a sibling backup dir) rather than delete, and check the loose binaries are
  not the running process (`Get-Process ... | Where-Object Path`) or referenced by
  `chrome-native-hosts.json` first.

### After any app or CLI update: audit every versioned path in `config.toml`

The updater rewrites *some* versioned paths and leaves others pointing at directories it has just
deleted. Observed in one update: `notify`, the bundled-plugin cache paths and
`BROWSER_USE_CODEX_APP_VERSION` all moved to the new build, while the whole `[mcp_servers.node_repl]`
block and `CODEX_CLI_PATH` still named the previous `cua_node\<hash>` and `bin\<hash>` - both
removed. The result is a `node_repl` MCP server whose `command` cannot be launched, plus a stale
`CODEX_CLI_PATH`, while `codex doctor` reports nothing specific about it.

Fewer than half the versioned paths being updated is the tell. Extract and test them all:

```powershell
$raw = Get-Content "$env:USERPROFILE\.codex\config.toml" -Raw
[regex]::Matches($raw, "[A-Za-z]:\\[^\s;`"']+") |
  ForEach-Object { $_.Value.TrimEnd(',') } | Sort-Object -Unique |
  Where-Object { $_ -match '\.(exe|mjs|js)$' -or $_.TrimEnd('\') -like '*node_modules' } |
  ForEach-Object { "{0}  {1}" -f (Test-Path -LiteralPath $_), $_ }
```

Every line must read `True`. Repair by replacing the stale hash with the hash actually present on
disk - the hash is the only part that changes - then re-validate by **parsing** the file, not by
re-reading it:

```powershell
python -c "import tomllib;tomllib.load(open(r'<config.toml>','rb'));print('TOML OK')"
```

Back the file up first, and expect the app to rewrite it again; a fix that survives one restart is
what matters. Do not "fix" a path the app deliberately manages - compare against a fresh
`notify` line, which the updater does keep current.

## Step 2 - Resolve the login question separately

Read `%USERPROFILE%\.codex\auth.json`. If it is absent, login never persisted regardless of what
the browser showed.

In `logs_2.sqlite`, the `codex_login::server` rows give the whole story:

```
received login callback ... has_code=true has_state=true state_valid=true   <- browser step OK
starting oauth token exchange issuer=https://auth.openai.com/ ...           <- now the POST
oauth token exchange succeeded                                              <- success
oauth token exchange transport failure is_timeout=... is_connect=... is_request=...
```

Interpret the three booleans:

| Pattern | Meaning |
|---|---|
| `is_connect=true` | TCP/TLS never completed - DNS, routing, or the proxy node |
| `is_connect=false, is_request=true` | Connected fine, the request died - proxy tunnel, upstream reset |
| `is_timeout=true` | The request stalled - saturation or a hung tunnel |

An exchange failure lasting tens of seconds that later succeeds unchanged points at a transient
proxy or bandwidth problem, not at Codex config. Check what else was running at that moment: a
concurrent runtime download (a ~500 MB `node-runtime.tar.gz` was in flight during one observed
failure) will starve the token exchange.

A separate, older class of failure shows as `HTTP 401 Unauthorized: Could not parse your
authentication token. Please try signing in again.` - a stale token, cured by re-login.

### The login client has only one real path, so one hiccup is fatal

Newer builds log an extra line when the first attempt fails:

```
starting oauth token exchange ...
oauth token connection failed; retrying with system proxy     <- the fallback
oauth token exchange transport failure is_timeout=false is_connect=false is_request=true
```

That fallback is reliably **dead** on a TUN-only proxy setup, for two independent reasons:

- the Windows system proxy is off — Clash/mihomo in TUN mode writes `enable_system_proxy: false`,
  so `ProxyEnable=0` and there is no system proxy to retry through;
- Codex's own switch is off too — `codex doctor` reports `respect system proxy  disabled`
  (`respect_system_proxy` / `system_proxy_fallback`, default off).

Consequence: a single transient `connection failed` becomes a hard login failure. So when the user
says "login failed", separate two questions: *is the path healthy now* (Step 0, sample it — the node
is often fine a minute later) and *was it healthy during the attempt* (the timeline usually shows a
just-resumed machine, a node switch, or a clock correction). Re-login is then the fix; adding a
proxy env var (see the case-duplicate trap in `references/desktop-app.md` §5) is the durable
mitigation, and `NO_PROXY` must include `127.0.0.1` so the `1455` callback stays direct.

Also decode the `id_token` `exp` before believing "auth is configured": an expired token with a
successful `last_refresh` still reports configured, and forces a re-login that has nothing to do
with the network fault under investigation.

## Step 3 - Read route-aware failures as sandbox state, not as networking

Errors from `codex_exec_server::client::http_client::route_aware_http_client`:

```
route-aware request timed out
application network permission was revoked
destination denied by application network policy
application network policy is unavailable
```

These come from the application network policy and the execution-scoped network proxy. The
decision that matters is whether the sandbox provisioned. Confirm with `codex doctor`:

```
sandbox provisioning     failed
error code               helper_unknown_error
network sandbox          restricted
```

`network sandbox: restricted` is normal for an active sandbox. `sandbox provisioning: failed` is
the defect, and it is what starves the route-aware client - which is why `mcp.context7.com` and
`chatgpt.com/backend-api/ps/*` fail through Codex while `curl.exe` reaches them fine.

**The read-ACL step is the usual blocker.** Sandbox setup grants read ACEs across the user
profile and fails hard on the first directory it cannot modify. The evidence is in
`%USERPROFILE%\.codex\.sandbox\`:

- `setup_error.json` - structured failure, e.g. `helper_unknown_error` / `read ACL run had errors`
- `sandbox.<date>.log` - the exact object, e.g.
  `grant read ACE failed on C:\Users\<user>\<dir> for sandbox_group: SetNamedSecurityInfoW failed: 5`

Error `5` is `ERROR_ACCESS_DENIED` on the DACL write. Confirm the cause with `icacls "<path>"`: a
profile directory whose **owner is `BUILTIN\Administrators`** and that grants only
`Everyone:(R)` + `Administrators:(F)` gives the signed-in user no `WRITE_DAC`, so setup cannot add
its ACE and aborts the whole run.

### Repair

The signed-in user is typically a non-elevated administrator (`BUILTIN\Administrators` shows
*Group used for deny only* in `whoami /groups`), so the DACL write needs one UAC elevation:

```powershell
$sid = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
Start-Process -FilePath "$env:SystemRoot\System32\icacls.exe" `
  -ArgumentList @("`"$target`"", '/grant', "*${sid}:(OI)(CI)F") -Verb RunAs -Wait
```

Adds one allow entry for the signed-in user. Contents and owner stay untouched. Verify the ACE
appears, then confirm the failure code *moves forward* - a changed `error code` in
`setup_error.json` means that blocker is cleared.

Rollback:

```powershell
icacls "<target>" /remove:g "*<sid>"
```

### Re-provisioning: how to trigger it, and how to read the result

Two traps, both observed on a real machine:

- **Restarting the desktop app does NOT re-provision.** Provisioning runs per *sandboxed command*,
  not at startup. After a full app restart the sandbox log and `setup_error.json` kept their old
  mtimes for more than ten minutes. Never promise a user that a restart will clear a sandbox
  failure - and note the deadlock: a thread running under `dangerFullAccess` never provisions, so
  a user who only ever uses full-access threads can never clear an inherited provisioning failure.
- **A confined shell fakes the failure.** Running `codex sandbox -- <cmd>` from a sandboxed or
  otherwise confined session reports `helper_read_acl_helper_spawn_failed` even on a healthy
  machine, because the confinement blocks the piped spawn the read-ACL helper needs. Worse, that
  run *overwrites* `setup_error.json`, after which `codex doctor` faithfully echoes a failure that
  does not exist. A scheduling detour (`schtasks /run`) did not escape the confinement either.

Trigger it for real by redirecting to **files instead of pipes**, which is enough to get past the
pipe restriction:

```powershell
Start-Process -FilePath <codex.exe> `
  -ArgumentList @('sandbox','--','cmd.exe','/c','echo ok') `
  -RedirectStandardOutput <out.txt> -RedirectStandardError <err.txt> -NoNewWindow -Wait -PassThru
```

Success is unambiguous; three markers move together:

| Evidence | Healthy | Failed |
|---|---|---|
| `sandbox.<date>.log` | `read ACL run completed` | `read ACL run completed with errors` |
| `.sandbox-bin\` | `codex-command-runner-<cli-version>.exe` staged | absent for the running CLI |
| `.sandbox\setup_error.json` | absent | present with an error code |
| `codex doctor` | `provisioning complete`, `0 fail` | `provisioning failed`, `1 fail` |

The helper-staging line is easy to miss and worth checking on its own: if `.sandbox-bin` holds no
command-runner matching the running CLI version, provisioning never completed and nothing can run
in the sandbox. `hide users: failed to hide ... C:\Users\Default ... 5` is benign and appears on
healthy runs too - do not chase it.

A post-repair confirmation must also account for the route-aware client being a *global* exec-server
component rather than a per-thread one: re-check the route-aware errors after provisioning
completes, because a full-access thread can still surface them while the proxy is broken.

## Step 4 - Fix config warnings that Codex itself flags

Codex names its own bad config keys. Grep the log for
`unrecognized configuration setting`, which reports the exact path:

```
`mcp_servers.context7.type` is ignored. Check for typos or deprecated settings.
```

Remove the named key; keep the rest of the section. Validate afterwards by parsing the file rather
than by re-reading it, so a syntax break cannot slip through:

```powershell
& <python> -c "import tomllib;tomllib.load(open(r'<config.toml>','rb'));print('TOML OK')"
```

Back the file up first. The desktop app rewrites `config.toml`, so verify the edit survived a
restart.

## Step 5 - Plugin icon warnings: find the declaring file, not the loader

`codex_core_skills::loader` emits, once per plugin-layer load:

```
ignoring interface.icon_small: icon path with '..' must resolve under plugin assets/
ignoring interface.icon_large: icon path with '..' must resolve under plugin assets/
```

The count is inflated because the same plugin tree is loaded from **two roots** -
`%USERPROFILE%\.codex\plugins\cache\...` and
`%USERPROFILE%\.cache\codex-runtimes\codex-primary-runtime\plugins\...` - which is why the warnings
appear to name different paths.

The declaring fields live in **YAML, not JSON**, so a JSON-only search finds nothing. Search the
skill metadata files:

```
**\skills\*\agents\openai.yaml    -> interface.icon_small / interface.icon_large
```

A path like `../spreadsheets/assets/file-spreadsheet.png` is rejected even though the target
exists. Fix it the way sibling skills already do - give the skill its own `assets/` and use a
child-relative path:

```yaml
icon_small: "./assets/file-spreadsheet.png"
icon_large: "./assets/file-spreadsheet.png"
```

Copy the image into `skills/<skill>/assets/` and patch **every** copy of the tree, or the warning
returns on the next load.

Two things make this a recurring chore rather than a one-off:

- **The rule is stricter than its message.** `../../assets/logo.svg` resolving correctly to the
  plugin's own `assets/` directory - with the file present - is still rejected. Do not reason about
  whether the path would resolve; treat **any** `..` as fatal and rewrite it child-relative.
- **Every bundle update can change the offender list.** Bundle `26.723.12215` flagged only
  `spreadsheets/skills/excel-live-control`; two versions later `26.1005.12141` shipped the same
  defect *plus* a new one in `template-creator/skills/template-creator`, and the update silently
  reverted all previous fixes. Re-run the icon scan (section 11 of the evidence script) after every
  runtime or app update instead of
  assuming a previously repaired tree is still repaired.

### "Icon bug" is two unrelated bugs - identify which one first

| Reported as | Layer | Where to look |
|---|---|---|
| `ignoring interface.icon_small: icon path with '..'` repeating in logs | plugin/skill metadata | `skills\*\agents\openai.yaml` - the section above |
| the desktop launcher shows a blank/generic icon | the `.exe` you built | `references/desktop-app.md` §4 |

For the launcher case the cause is simply that the executable has **no icon resource** - an exe
compiled without `/win32icon` renders as Windows' generic blank icon. Embed the package's own
`app\resources\icon-chatgpt.ico` (8 sizes, 16-256) with `csc /win32icon:`, and prove it landed by
counting PE resources (`RT_ICON` = 8, `RT_GROUP_ICON` = 1) rather than by eye.

## Step 6 - Desktop-app layer: blank window, update loop, profile dialog

The desktop app is a packaged Electron app and fails quite differently from the CLI. Its real
profile is **virtualized**:

```
%LOCALAPPDATA%\Packages\OpenAI.Codex_<publisherId>\LocalCache\Roaming\Codex\web\Codex
```

not `%APPDATA%\Codex`, which does not exist. App logs live under
`...\LocalCache\Local\Codex\Logs\<year>\<month>\<day>\`.

Classify the report before touching anything:

| User says | Likely layer | Go to |
|---|---|---|
| "white / blank box, won't close" | wedged compositor | 6.1 |
| "prompts to update, then crashes, then prompts again" | MSIX registration | 6.2 |
| "profile error / preferences can't be read" dialog | Chromium profile | 6.3 |

### 6.1 Blank or invisible window

Signature: a live process tree with `Responding=True` and **no painting**. Prove it, do not describe
it - enumerate the app's top-level windows (a window can exist with `visible=False`), then capture
the window's own content with `PrintWindow(..., PW_RENDERFULLCONTENT)`. A blank capture is a few KB
with 1-6 distinct colours; a real UI is ~60 KB+ with dozens. Never judge by a screen capture: an
occluded window yields the desktop behind it.

Fix with `scripts/fix-blank-window.ps1`, which kills the tree, clears the five GPU/compositor caches
(`Default\GPUCache`, `Default\DawnGraphiteCache`, `Default\DawnWebGPUCache`, `ShaderCache`,
`GrShaderCache`) and relaunches. Preserve `Local Storage` / `Session Storage` - that is user state.

Rule out a genuine crash first: no `Application Error` 1000, no Crashpad dump, no display-driver
TDR (System log 4101/4099). If all three are clean it is a wedged compositor.

It recurs when the app auto-starts at logon through its MSIX startup task, before the GPU/desktop is
ready. That same autostart is a plausible source of "several warning dialogs at every boot", so
disabling it is the durable fix.

### 6.2 Update loop (prompts -> updates -> "crashes" -> prompts again)

The download succeeds; **registration** fails, so the old build stays active and the prompt returns.
The "crash" is the planned restart that swaps builds and finds nothing new. Look in the **WER**
event log for `StoreAgentInstallFailure1` carrying `0x80073CF6` / `0x80073CF9` - these may not appear
in `AppXDeploymentServer/Operational` at all, so an empty deployment log proves nothing.

The nastiest variant is `0x80070430` (*service marked for deletion*): the outgoing package's service
teardown blocks the incoming package from registering `windows.service`, deployment rolls back, and
the package sticks at `Status: Servicing`. In that state the AUMID still resolves but activation
yields **zero processes** - exactly the user's "crash on launch". It cannot be fixed with `sc` (see
below) and needs a **reboot**, which finalizes the pending delete.

### 6.3 Profile-error dialog

A dialog reading "个人资料错误 / 系统无法读取您的偏好设置..." is Chromium's profile-error dialog. Before
assuming corruption, actually parse the files - in one observed case all seven `Preferences` /
`Local State` / `Secure Preferences` files were valid JSON, every ACL granted the user full control,
and the dialog was not logged at all. Report it as unreproduced rather than inventing a cause.

### The packaged service is not yours to configure

`CodexSandboxService.OpenAI.Codex` is declared in the manifest as `StartupType="auto"` /
`StartAccount="localSystem"`, and `sc qc` reports `TYPE: 210 WIN32_PACKAGED_PROCESS`. Its
configuration belongs to the deployment subsystem: **even an elevated administrator gets
`OpenService failed 5: access denied`** on `sc config`, whatever the registry ACL says. A packaged
service sitting at `DISABLED` is a deployment artifact rather than a user choice, and only a
successful redeploy (update or reinstall) restores it. While it is disabled, sandbox provisioning
fails with `helper_read_acl_helper_spawn_failed`.

Full command sequences, the error-code table and the verification steps live in
`references/desktop-app.md`.

## Step 7 - Database and credential-file health

`codex doctor` already reports per-database integrity; read that first. Then check the two things it
does not show, both of which were real on one machine.

**Free pages and WAL.** Query them directly rather than trusting file size:

```sql
PRAGMA page_size; PRAGMA page_count; PRAGMA freelist_count; PRAGMA journal_mode;
```

Observed: `logs_2.sqlite` at `page_count=9733` with `freelist=9119` - about 94% free pages - and a
4 MB `-wal` next to a 39 MB file holding only ~3,300 rows. The log store deletes old rows but never
reclaims space or checkpoints, which is why history disappears within minutes. That is *expected*
behaviour to plan around, **not** corruption, and it must not be "repaired".

The actionable variants are different: a `-wal` that only ever grows, `database is locked`, or a
non-`ok` `integrity_check`. Space pathology and corruption are separate findings - say which one
you actually have.

**Credential file shape.** Parse `auth.json` and decode the `id_token` payload's `exp` / `iat`:

- missing `tokens.access_token` or `tokens.refresh_token` - the write was partial;
- expired `id_token` - refresh is failing silently while status still reads "configured";
- unparseable JSON - back it up and re-login rather than hand-editing it.

Corrupt databases are rare; a misread or rotated log store is common. Do not present the second as
the first.

## Reporting

State separately, and never merge them:

1. What was **verified fixed** (with the command that proves it).
2. What was **changed** (exact paths, plus the rollback command).
3. What was **narrowed but not fixed**, and the single next action that would confirm it.
4. What was **not reproduced**, so the user is not told a cause was found.

Prefer quarantine over deletion for anything a running process might own, and re-read the target
with `icacls`/`Get-Acl` after any permission change rather than trusting the command's exit code.
