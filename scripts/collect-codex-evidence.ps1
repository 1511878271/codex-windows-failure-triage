# collect-codex-evidence.ps1
#
# Read-only evidence collector for Codex-on-Windows failures.
# It writes nothing, changes nothing, and is safe to run while Codex is running.
#
#   & '<skill-dir>\scripts\collect-codex-evidence.ps1'
#   & '<skill-dir>\scripts\collect-codex-evidence.ps1' -CodexHome 'D:\profile\.codex' -LogTail 60
#
# Capture this output immediately after a failure: logs_2.sqlite is a ring buffer that
# deleted an observed 18:45 failure window within ~2 minutes.

[CmdletBinding()]
param(
    [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),
    [string]$CodexBin  = (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'),
    [int]$LogTail = 40,
    [int]$ProxyPort = 0   # 0 = auto-detect from the WinINET ProxyServer value
)

$ErrorActionPreference = 'Continue'

function Section([string]$Title) {
    Write-Output ''
    Write-Output ('=' * 72)
    Write-Output ("== " + $Title)
    Write-Output ('=' * 72)
}

function Try-Item([string]$Path) {
    try { Get-Item -LiteralPath $Path -Force -ErrorAction Stop } catch { $null }
}

# ---------------------------------------------------------------- sqlite access
function Resolve-Sqlite {
    $cmd = Get-Command sqlite3 -ErrorAction SilentlyContinue
    if ($cmd) { return @{ Kind = 'exe'; Path = $cmd.Source } }

    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links')
    ) | Where-Object { Test-Path $_ }

    foreach ($root in $candidates) {
        $hit = Get-ChildItem -Path $root -Recurse -Depth 3 -Filter 'sqlite3.exe' -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if ($hit) { return @{ Kind = 'exe'; Path = $hit.FullName } }
    }

    # Fall back to any python that carries the sqlite3 stdlib module.
    foreach ($py in @('python', 'python3', 'py')) {
        $c = Get-Command $py -ErrorAction SilentlyContinue
        if ($c) { return @{ Kind = 'python'; Path = $c.Source } }
    }
    return $null
}

function Invoke-Sql([hashtable]$Sqlite, [string]$Db, [string]$Query) {
    if (-not $Sqlite) { return @('(no sqlite3 or python available; install sqlite3 to read the log DB)') }
    if ($Sqlite.Kind -eq 'exe') {
        return @(& $Sqlite.Path $Db $Query 2>&1)
    }
    # Route the query through a file so embedded quotes can never break the wrapper.
    $id   = [guid]::NewGuid().ToString('N')
    $sql  = Join-Path $env:TEMP ("codex-triage-$id.sql")
    $py   = Join-Path $env:TEMP ("codex-triage-$id.py")
    $body = @"
import sqlite3
try:
    con = sqlite3.connect(r'$Db')
    con.text_factory = lambda b: b.decode('utf-8', 'replace')
    q = open(r'$sql', encoding='utf-8').read()
    for row in con.execute(q):
        print(' | '.join('' if c is None else str(c) for c in row))
except Exception as e:
    print('SQL ERROR:', e)
"@
    try {
        Set-Content -LiteralPath $sql -Value $Query -Encoding UTF8
        Set-Content -LiteralPath $py  -Value $body  -Encoding UTF8
        return @(& $Sqlite.Path $py 2>&1)
    } finally {
        Remove-Item -LiteralPath $sql, $py -Force -ErrorAction SilentlyContinue
    }
}

$Sqlite = Resolve-Sqlite

Section 'Context'
Write-Output ("time            : " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'))
Write-Output ("CODEX_HOME      : " + $CodexHome + "  (exists=" + (Test-Path $CodexHome) + ")")
Write-Output ("CODEX_BIN       : " + $CodexBin  + "  (exists=" + (Test-Path $CodexBin)  + ")")

# ------------------------------------------------------------------- 1. version
Section '1. Installed versions and the binary actually running'

$running = Get-CimInstance Win32_Process -Filter "Name='codex.exe'" -ErrorAction SilentlyContinue
if ($running) {
    foreach ($p in $running) {
        Write-Output ("running codex  PID " + $p.ProcessId + "  " + $p.ExecutablePath)
        $parent = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $p.ParentProcessId) -ErrorAction SilentlyContinue
        if ($parent) { Write-Output ("   parent     PID " + $parent.ProcessId + "  " + $parent.Name) }
    }
} else { Write-Output 'running codex  : none' }

$cfg = Join-Path $CodexHome 'config.toml'
if (Test-Path $cfg) {
    $cli = Select-String -LiteralPath $cfg -Pattern 'CODEX_CLI_PATH' -ErrorAction SilentlyContinue
    if ($cli) { $cli | ForEach-Object { Write-Output ('config         : ' + $_.Line.Trim()) } }
}

if (Test-Path $CodexBin) {
    Write-Output ''
    Write-Output '-- bin layout (loose legacy vs hashed per-build dirs) --'
    Get-ChildItem -LiteralPath $CodexBin -Force -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.PSIsContainer) {
            $inner = Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
            Write-Output ("  DIR  " + $_.Name)
            foreach ($f in $inner) {
                Write-Output ("        " + $f.Name.PadRight(34) + $f.Length.ToString().PadLeft(12) + "  " + $f.LastWriteTime)
            }
        } else {
            $ver = ''
            try { $ver = $_.VersionInfo.FileVersion } catch { }
            Write-Output ("  FILE " + $_.Name.PadRight(34) + $_.Length.ToString().PadLeft(12) + "  " + $_.LastWriteTime + "  ver=" + $ver)
        }
    }
    $loose = Join-Path $CodexBin 'codex.exe'
    if (Test-Path $loose) {
        $lv = (Try-Item $loose).VersionInfo.FileVersion
        Write-Output ''
        Write-Output ("NOTE: loose bin\codex.exe exists (ver=" + $lv + "). If it differs from the hashed build")
        Write-Output '      CODEX_CLI_PATH points at, that is the reported "startup version differs" skew.'
    }
}

# ---------------------------------------------------------------------- 2. auth
Section '2. Auth state'

$auth = Join-Path $CodexHome 'auth.json'
if (Test-Path $auth) {
    $i = Try-Item $auth
    Write-Output ("auth.json       : present, " + $i.Length + " bytes, modified " + $i.LastWriteTime)
    try {
        $j = Get-Content -LiteralPath $auth -Raw | ConvertFrom-Json
        Write-Output ("  top-level keys: " + (($j.PSObject.Properties.Name) -join ', '))
        Write-Output ("  auth_mode     : " + $j.auth_mode)
        Write-Output ("  last_refresh  : " + $j.last_refresh)
        if ($j.tokens) { Write-Output ("  tokens        : " + (($j.tokens.PSObject.Properties.Name) -join ', ')) }
    } catch { Write-Output ('  (could not parse: ' + $_.Exception.Message + ')') }
} else {
    Write-Output 'auth.json       : ABSENT - login never persisted, whatever the browser showed.'
}

# -------------------------------------------------------------- 3. log DB window
Section '3. logs_2.sqlite retention window  (ring buffer - read it now)'

$db = Join-Path $CodexHome 'logs_2.sqlite'
if (Test-Path $db) {
    $i = Try-Item $db
    Write-Output ("db              : " + $i.Length + " bytes, modified " + $i.LastWriteTime)
    $w = Invoke-Sql $Sqlite $db "SELECT datetime(MIN(ts),'unixepoch','localtime'), datetime(MAX(ts),'unixepoch','localtime'), COUNT(*) FROM logs;"
    Write-Output ("window          : " + ($w -join '  '))
    Write-Output '(MIN -> MAX -> row count. A short window means older evidence is already gone.)'
} else { Write-Output 'db              : missing' }

Section '4. Recent WARN / ERROR rows'

if (Test-Path $db) {
    $q = "SELECT datetime(ts,'unixepoch','localtime') || ' [' || level || '] ' || target || ' :: ' || substr(replace(coalesce(feedback_log_body,''),char(10),' '),1,260) FROM logs WHERE level IN ('ERROR','WARN') ORDER BY id DESC LIMIT $LogTail;"
    Invoke-Sql $Sqlite $db $q | ForEach-Object { Write-Output $_ }
}

Section '5. Login / token-exchange rows'

if (Test-Path $db) {
    $q = "SELECT datetime(ts,'unixepoch','localtime') || ' [' || level || '] ' || target || ' :: ' || substr(replace(coalesce(feedback_log_body,''),char(10),' '),1,240) FROM logs WHERE target LIKE 'codex_login%' AND coalesce(feedback_log_body,'') NOT LIKE '%Reloading auth%' AND coalesce(feedback_log_body,'') NOT LIKE '%Reloaded auth%' ORDER BY id DESC LIMIT 25;"
    Invoke-Sql $Sqlite $db $q | ForEach-Object { Write-Output $_ }
}

Section '6. Route-aware / network-policy failure rows'

if (Test-Path $db) {
    $q = "SELECT datetime(ts,'unixepoch','localtime') || ' :: ' || target || ' :: ' || substr(replace(coalesce(feedback_log_body,''),char(10),' '),1,240) FROM logs WHERE feedback_log_body LIKE '%route%ware%' OR feedback_log_body LIKE '%network permission%' OR feedback_log_body LIKE '%network policy%' OR feedback_log_body LIKE '%timed out%' ORDER BY id DESC LIMIT 20;"
    Invoke-Sql $Sqlite $db $q | ForEach-Object { Write-Output $_ }
}

# ------------------------------------------------------------------ 7. sandbox
Section '7. Windows sandbox provisioning state'

$sb = Join-Path $CodexHome '.sandbox'
if (Test-Path $sb) {
    foreach ($f in @('setup_error.json', 'setup_marker.json', 'deny_read_acl_state.json')) {
        $p = Join-Path $sb $f
        if (Test-Path $p) {
            Write-Output ('-- ' + $f + '  (modified ' + (Try-Item $p).LastWriteTime + ')')
            Get-Content -LiteralPath $p -Raw -ErrorAction SilentlyContinue | ForEach-Object { Write-Output ('   ' + $_) }
        }
    }
    Write-Output ''
    Write-Output '-- sandbox setup logs (newest first) --'
    $logs = Get-ChildItem -LiteralPath $sb -Filter '*.log' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 3
    foreach ($l in $logs) {
        Write-Output ('-- ' + $l.Name + '  (' + $l.Length + ' bytes, ' + $l.LastWriteTime + ')')
        Get-Content -LiteralPath $l.FullName -Tail 12 -ErrorAction SilentlyContinue |
            ForEach-Object { Write-Output ('   ' + $_) }
    }
    Write-Output ''
    Write-Output '-- sandbox accounts / service --'
    Get-LocalUser -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'CodexSandbox' } |
        Select-Object Name, Enabled | Format-Table -AutoSize | Out-String -Width 120 | Write-Output
    Get-Service -Name '*CodexSandbox*' -ErrorAction SilentlyContinue |
        Select-Object Name, Status, StartType | Format-Table -AutoSize | Out-String -Width 120 | Write-Output
    Write-Output '-- sandbox firewall rules --'
    Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'codex' } |
        Select-Object DisplayName, Direction, Action, Enabled | Format-Table -AutoSize | Out-String -Width 140 | Write-Output
} else { Write-Output ('.sandbox missing at ' + $sb) }

Section '8. Permission check on user-profile directories the sandbox reads'

# Sandbox setup grants read ACEs across the profile and aborts on the first denial.
# A directory owned by BUILTIN\Administrators with only Everyone:(R) blocks it (error 5).
$profileRoot = $env:USERPROFILE
Get-ChildItem -LiteralPath $profileRoot -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        $acl = Get-Acl -LiteralPath $_.FullName -ErrorAction Stop
        $me  = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $mine = $acl.Access | Where-Object { $_.IdentityReference -eq $me -and $_.AccessControlType -eq 'Allow' }
        $hasFull = $mine | Where-Object { $_.FileSystemRights -match 'FullControl' }
        if (-not $hasFull) {
            Write-Output ('  CHECK  ' + $_.FullName)
            Write-Output ('         owner=' + $acl.Owner + '  signed-in-user-allow-entries=' + ($mine | Measure-Object).Count)
        }
    } catch { }
}
Write-Output '(Only directories lacking a FullControl allow entry for the signed-in user are listed.)'

# ------------------------------------------------------------------- 9. network
Section '9. Network path: VPN / proxy / node  (five checks, cheapest first)'

$envNames = @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY', 'http_proxy', 'https_proxy', 'all_proxy', 'no_proxy')
$set = $envNames | Where-Object { (Get-Item -Path ("env:" + $_) -ErrorAction SilentlyContinue) }
if ($set) { $set | ForEach-Object { Write-Output ('  ' + $_ + '=' + (Get-Item ("env:" + $_)).Value) } }
else { Write-Output '  proxy env vars: none set (codex reads ONLY these, never WinINET)' }

$ie = $null
try { $ie = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop } catch { }
if ($ie) {
    Write-Output ('  WinINET (browsers/.NET only): ProxyEnable=' + $ie.ProxyEnable + '  ProxyServer=' + $ie.ProxyServer)
    if ($ProxyPort -le 0 -and $ie.ProxyServer -match ':(\d+)') { $ProxyPort = [int]$Matches[1] }
}
if ($ProxyPort -le 0) { $ProxyPort = 7897 }
$proxyUrl = 'http://127.0.0.1:' + $ProxyPort

# --- check 1: is the tunnel process actually listening?
$listening = Test-NetConnection -ComputerName 127.0.0.1 -Port $ProxyPort -InformationLevel Quiet -WarningAction SilentlyContinue
Write-Output ''
Write-Output ('  [1] proxy 127.0.0.1:' + $ProxyPort + ' listening = ' + $listening)
if (-not $listening) {
    Write-Output '      ^^ A CLOSED PORT MEANS THE VPN/PROXY IS OFF. Stop here and tell the user to'
    Write-Output '         start it. Everything downstream will fail and no Codex change will help.'
}

# --- check 2: TUN adapter vs system-proxy-only
Write-Output ''
Write-Output '  [2] TUN adapter present?'
$tun = Get-NetAdapter -ErrorAction SilentlyContinue |
       Where-Object { $_.InterfaceDescription -match 'TAP|TUN|Wireguard|Mihomo|Wintun|Meta Tunnel' -or $_.Name -match 'TUN|Mihomo|Clash|Verge|Meta' }
if ($tun) {
    $tun | Select-Object Name, InterfaceDescription, Status |
        Format-Table -AutoSize | Out-String -Width 120 | ForEach-Object { Write-Output ('      ' + $_) }
    Write-Output '      TUN up => the OS captures traffic; codex needs no proxy awareness.'
} else {
    Write-Output '      no tunnel adapter. If only the WinINET system proxy is on, browsers work while'
    Write-Output '      Rust/reqwest (codex) goes DIRECT and fails - it honours only HTTP(S)_PROXY.'
}

# --- check 3: DNS + fake-IP
Write-Output ''
Write-Output '  [3] DNS resolution / fake-IP range'
foreach ($host_ in @('auth.openai.com', 'chatgpt.com', 'mcp.context7.com')) {
    $ips = @()
    try { $ips = (Resolve-DnsName $host_ -ErrorAction Stop | Where-Object { $_.IPAddress } | Select-Object -ExpandProperty IPAddress) } catch { }
    $fake = $ips | Where-Object { $_ -like '198.18.*' -or $_ -like '198.19.*' }
    $note = if ($fake) { '  <-- 198.18/15 fake-IP: TUN resolver active' } else { '' }
    Write-Output ('      ' + $host_.PadRight(20) + ($ips -join ', ') + $note)
}

$curl = Get-Command curl.exe -ErrorAction SilentlyContinue
if ($curl) {
    # --- check 4: where does the node exit, and does OpenAI accept it?
    Write-Output ''
    Write-Output '  [4] node exit country, then OpenAI acceptance of this IP'
    $trace = & $curl.Source -sS --max-time 20 -x $proxyUrl https://chatgpt.com/cdn-cgi/trace 2>&1
    foreach ($k in @('ip=', 'loc=', 'colo=')) {
        $line = $trace | Where-Object { $_ -like ($k + '*') } | Select-Object -First 1
        if ($line) { Write-Output ('      ' + $line) }
    }
    Write-Output '      (loc= in an unsupported region fails sign-in however healthy the tunnel is.)'
    Write-Output ''
    Write-Output '      malformed oauth POST -> expect 400 with OpenAI JSON. 403/HTML = IP or region blocked.'
    $oauth = & $curl.Source -sS --max-time 25 -x $proxyUrl -X POST `
        -H 'Content-Type: application/x-www-form-urlencoded' `
        --data 'grant_type=authorization_code&code=dummy&client_id=dummy' `
        -o - -w '      [status=%{http_code}]' `
        https://auth.openai.com/oauth/token 2>&1
    $joined = ($oauth | Out-String)
    if ($joined -match '"type"\s*:\s*"invalid_request_error"' -or $joined -match 'invalid_request') {
        Write-Output '      => 400-class OpenAI error: request REACHED OpenAI. IP/region are fine.'
    } elseif ($joined -match '<html' -or $joined -match 'cloudflare' -or $joined -match 'unsupported_country') {
        Write-Output '      => BLOCKED at the edge. Change node; do NOT change Codex config.'
    }
    $joined.Trim() -split "`n" | Select-Object -First 4 | ForEach-Object { Write-Output ('      ' + $_) }

    # --- check 5: does the stored token actually work through this node?
    Write-Output ''
    Write-Output '  [5] stored token against the account endpoint (strongest single signal)'
    $authPath = Join-Path $CodexHome 'auth.json'
    if (Test-Path $authPath) {
        try {
            $a = Get-Content -LiteralPath $authPath -Raw | ConvertFrom-Json
            $tok = $a.tokens.access_token
            $acct = $a.tokens.account_id
            $res = & $curl.Source -sS --max-time 25 -x $proxyUrl -o NUL -w 'http=%{http_code}' `
                   -H ("Authorization: Bearer " + $tok) -H ("chatgpt-account-id: " + $acct) `
                   https://chatgpt.com/backend-api/me 2>&1
            Write-Output ('      ' + ($res -join ' '))
            Write-Output '      200 = token+account+node all work; remaining failure is local to Codex.'
            Write-Output '      401 = re-login.  403 while [4] passed = the account, not the network.'
        } catch { Write-Output ('      could not read auth.json: ' + $_.Exception.Message) }
    } else { Write-Output '      auth.json absent - log in first.' }
} else { Write-Output '  curl.exe unavailable; checks 4 and 5 skipped.' }


# ---------------------------------------------------------------- 10. doctor
Section '10. codex doctor (authoritative recorded state)'

$doctor = $null
if (Test-Path $CodexBin) {
    $doctor = Get-ChildItem -LiteralPath $CodexBin -Recurse -Depth 1 -Filter 'codex.exe' -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
}
if ($doctor) {
    Write-Output ('using ' + $doctor.FullName)
    & $doctor.FullName doctor 2>&1 | Select-Object -First 45 | ForEach-Object { Write-Output $_ }
    Write-Output '...'
    Write-Output '(Full output: run `codex doctor` directly. The Notes block and the sandbox section'
    Write-Output ' carry the provisioning verdict and the recorded error code.)'
} else { Write-Output 'codex.exe not found under CODEX_BIN' }

Section '11. Plugin metadata warnings (icon paths)'

# Declared in YAML, not JSON. Two roots load the same tree, so warnings look duplicated.
$roots = @(
    (Join-Path $CodexHome 'plugins'),
    (Join-Path $env:USERPROFILE '.cache\codex-runtimes')
)
foreach ($r in $roots) {
    if (-not (Test-Path $r)) { continue }
    Get-ChildItem -LiteralPath $r -Recurse -Filter 'openai.yaml' -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $m = Select-String -LiteralPath $_.FullName -Pattern '\.\./' -ErrorAction SilentlyContinue
        if ($m) {
            Write-Output ('  ' + $_.FullName)
            $m | ForEach-Object { Write-Output ('      L' + $_.LineNumber + ': ' + $_.Line.Trim()) }
        }
    }
}
Write-Output '(Any hit above is a path the loader rejects: "icon path with .. must resolve under plugin assets/".)'

Section '12. Database health and space pathology'

# integrity_check tells you about corruption; freelist/WAL tell you about the ring-buffer
# behaviour that makes history disappear. They are different findings - report which you have.
foreach ($name in @('state_5.sqlite', 'logs_2.sqlite', 'goals_1.sqlite', 'memories_1.sqlite', 'queue_1.sqlite')) {
    $f = Join-Path $CodexHome $name
    if (-not (Test-Path $f)) { Write-Output ('  ' + $name.PadRight(22) + 'MISSING'); continue }
    $integrity = (Invoke-Sql $Sqlite $f 'PRAGMA integrity_check;' | Select-Object -First 1)
    $pages     = (Invoke-Sql $Sqlite $f 'SELECT page_count FROM pragma_page_count();' | Select-Object -First 1)
    $free      = (Invoke-Sql $Sqlite $f 'SELECT freelist_count FROM pragma_freelist_count();' | Select-Object -First 1)
    $mode      = (Invoke-Sql $Sqlite $f 'PRAGMA journal_mode;' | Select-Object -First 1)
    $wal       = (Get-Item ($f + '-wal') -ErrorAction SilentlyContinue).Length
    $pct = ''
    if ($pages -and $free -and [int]$pages -gt 0) {
        $pct = '  free=' + [math]::Round(100 * [int]$free / [int]$pages) + '%'
    }
    Write-Output ('  ' + $name.PadRight(22) + 'integrity=' + $integrity + '  pages=' + $pages + $pct + '  journal=' + $mode + '  wal=' + $wal)
}
Write-Output '  pages mostly free + a large -wal = the log ring buffer never reclaims space.'
Write-Output '  That is expected, not corruption. Only a non-ok integrity_check needs repair.'

Section '13. Credential file shape'

$authPath = Join-Path $CodexHome 'auth.json'
if (-not (Test-Path $authPath)) {
    Write-Output '  auth.json absent - login never persisted.'
} else {
    # Pure PowerShell on purpose: a bare `python` on PATH is often the Microsoft Store stub,
    # which exits silently and would make this section look clean when it never ran.
    try {
        $j = Get-Content -LiteralPath $authPath -Raw | ConvertFrom-Json
        Write-Output ('  auth_mode    : ' + $j.auth_mode)
        Write-Output ('  last_refresh : ' + $j.last_refresh)

        $tok = $j.tokens
        if (-not $tok) { Write-Output '  NO tokens object - the credential write was partial.' }

        foreach ($k in @('id_token', 'access_token', 'refresh_token')) {
            $v = ''
            if ($tok -and $tok.PSObject.Properties[$k]) { $v = [string]$tok.$k }
            $extra = ''
            if ($k -eq 'id_token' -and $v.Split('.').Count -eq 3) {
                try {
                    $p = $v.Split('.')[1].Replace('-', '+').Replace('_', '/')
                    switch ($p.Length % 4) { 2 { $p += '==' } 3 { $p += '=' } }
                    $payload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json
                    if ($payload.exp) {
                        $exp = [DateTimeOffset]::FromUnixTimeSeconds([int64]$payload.exp).LocalDateTime
                        $state = if ($exp -gt (Get-Date)) { 'VALID' } else { 'EXPIRED' }
                        $extra = '  exp=' + $exp.ToString('yyyy-MM-dd HH:mm:ss') + '  (' + $state + ')'
                    }
                } catch { $extra = '  (id_token payload decode failed: ' + $_.Exception.Message + ')' }
            }
            if (-not $v) { $extra += '  <-- MISSING' }
            Write-Output ('  ' + $k.PadRight(14) + 'len=' + $v.Length + $extra)
        }
        if (-not $tok.access_token -or -not $tok.refresh_token) {
            Write-Output '  A missing access_token or refresh_token means the write was partial: re-login.'
        }
        if ($extra -match 'EXPIRED') {
            Write-Output '  An expired id_token with a healthy last_refresh means refresh is failing'
            Write-Output '  silently while status still reports as configured.'
        }
    } catch {
        Write-Output ('  auth.json is not parseable JSON: ' + $_.Exception.Message)
        Write-Output '  Back it up and re-login rather than hand-editing it.'
    }
}

Section 'Done'
Write-Output 'Nothing was modified. Pair this with `codex doctor` before and after any repair.'
