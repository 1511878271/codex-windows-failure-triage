# Recover a blank / white / hidden Codex Desktop window.
#
# Symptom set: the window is blank or invisible, often will not close, yet the process tree looks
# alive and the main process reports Responding=True. That combination means the compositor is
# wedged, not that the app crashed — there is normally no crash dump and no driver reset.
#
# This kills the tree, clears the GPU/compositor caches (they regenerate on next launch) and
# relaunches. Local Storage / Session Storage are deliberately preserved so UI state and recent
# conversations survive.
#
#   & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile `
#       -ExecutionPolicy Bypass -File fix-blank-window.ps1
#
# Add -Launcher to relaunch through a specific shortcut/exe instead of the package AUMID.

[CmdletBinding()]
param(
    [string]$PackageName        = 'OpenAI.Codex',
    [string]$Launcher           = '',
    [string]$ProcessNames       = 'ChatGPT,codex',
    [int]$StartupWaitSeconds    = 30
)

$ErrorActionPreference = 'Continue'

function Say([string]$m) { Write-Host $m }

Say '== 1. stop the wedged app =='
$names = $ProcessNames -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
$running = Get-Process -Name $names -ErrorAction SilentlyContinue
Say ('   running before: ' + ($running | Measure-Object).Count)
if ($running) {
    $running | ForEach-Object { Say ('   killing PID ' + $_.Id + '  ' + $_.ProcessName) }
    foreach ($n in $names) { Stop-Process -Name $n -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 4
}
Say ('   running after: ' + ((Get-Process -Name $names -ErrorAction SilentlyContinue) | Measure-Object).Count)

Say '== 2. clear GPU / compositor caches =='
$pkg = Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $pkg) { throw "$PackageName is not installed." }
$profile = Join-Path $env:LOCALAPPDATA ('Packages\' + $pkg.PackageFamilyName + '\LocalCache\Roaming\Codex\web\Codex')
if (-not (Test-Path $profile)) { throw "Profile not found: $profile" }
$targets = @(
    (Join-Path $profile 'Default\GPUCache'),
    (Join-Path $profile 'Default\DawnGraphiteCache'),
    (Join-Path $profile 'Default\DawnWebGPUCache'),
    (Join-Path $profile 'ShaderCache'),
    (Join-Path $profile 'GrShaderCache')
)
foreach ($t in $targets) {
    if (Test-Path $t) {
        $n = (Get-ChildItem $t -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object).Count
        Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue
        Say ('   cleared ' + $t.Replace($profile, '<profile>') + '  (' + $n + ' items)')
    } else {
        Say ('   absent  ' + $t.Replace($profile, '<profile>'))
    }
}

Say '== 3. relaunch =='
if ($Launcher -and (Test-Path $Launcher)) {
    Start-Process -FilePath $Launcher
} else {
    # Activating the package family resolves to whatever version is installed.
    Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') `
                  -ArgumentList ('shell:AppsFolder\' + $pkg.PackageFamilyName + '!App')
}
Say ('   waiting ' + $StartupWaitSeconds + 's ...')
Start-Sleep -Seconds $StartupWaitSeconds

$win = Get-Process -Name ($names | Where-Object { $_ -ne 'codex' }) -ErrorAction SilentlyContinue |
       Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $win) {
    Say '   WARNING: no visible window yet. Give it another 20s, or rerun this script.'
    Say '   If it repeats on every launch, disable the MSIX startup task (auto-start at logon) and'
    Say '   start the app after the desktop is ready; then test with hardware acceleration off.'
    exit 1
}
Say ('   window PID ' + $win.Id + '  responding=' + $win.Responding + "  title='" + $win.MainWindowTitle + "'")
Say ''
Say 'Done. Verify it is painting, not merely visible: capture with PrintWindow and expect a large'
Say 'PNG with dozens of distinct colours, not a few-KB near-uniform image.'
exit 0
