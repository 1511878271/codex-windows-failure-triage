# codex-windows-failure-triage

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
