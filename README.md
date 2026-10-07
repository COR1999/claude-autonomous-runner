# claude-autonomous-runner

Keep **Claude Code** working unattended. A small PowerShell loop that relaunches
headless turns back-to-back so the model never sits idle waiting for input — and
stops itself cleanly when your usage limit hits.

Proven in real use: scheduled overnight, it resumed a session and merged 14 PRs
in about an hour before the quota stopped it.

## How it works

```
Task Scheduler / manual launch
  └─> cd <your project>
       └─> loop:
             claude -p --continue --dangerously-skip-permissions --output-format json "<prompt>"
             ├─ reply ends with DONE-ALL      -> stop (goal complete)
             ├─ error carries limit wording   -> stop, or sleep until the reset (-WaitForReset)
             ├─ turn runs past the timeout    -> kill its process tree, count a failure
             ├─ N consecutive failures        -> stop (something broke)
             └─ max-hours cap                 -> stop (runaway backstop)
```

The whole trick is `claude -p --continue`: headless mode that resumes the most
recent session in the folder, does one autonomous turn, then exits. Loop it and
you get continuous unattended work; every turn's reply, exit code, cost and
duration land in a timestamped log so you can review everything afterwards.

JSON output is what keeps the stop conditions honest: completion and quota
checks look at the structured `result` / `is_error` fields, so a reply that
merely *talks about* rate limits or says "not DONE-ALL yet" does not end the
run.

## Requirements

- Windows with PowerShell 5.1+, or [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell) (`pwsh`) on Windows, macOS or Linux
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and logged in
- A project folder containing a previous Claude Code session to resume

## Quick start

```powershell
.\claude-autonomous-runner.ps1 -WorkDir "C:\path\to\your-project"
```

Options:

| Parameter | Default | Purpose |
|---|---|---|
| `-WorkDir` | *(required)* | Project whose last session gets resumed |
| `-MaxHours` | `10` | Safety deadline; always stops by this (fractions allowed) |
| `-FailureLimit` | `5` | Consecutive failed turns before giving up |
| `-TurnDelaySeconds` | `5` | Pause between turns |
| `-FailureBackoffSeconds` | `60` | Pause after a failed turn |
| `-TurnTimeoutMinutes` | `120` | Kill a turn that runs longer than this (`0` = never) |
| `-WaitForReset` | off | On a quota limit, sleep until the reset time it reports, then carry on |
| `-ResetBufferMinutes` | `2` | Extra wait after the reported reset |
| `-LogDir` | `logs\` next to the script | Where run logs go |
| `-ClaudePath` | `claude` on PATH, then `~\.localin\claude.exe` | CLI to run |
| `-Prompt` | continue-and-report-DONE-ALL | The instruction sent each turn |

Only one runner can work a given folder at a time; a second one logs that and
exits instead of interleaving turns into the same session.

With `-WaitForReset` a 5-hour session limit no longer ends the night: the runner
reads `resets 1:10am` (or `resets Oct 9, 4pm`) from the message, sleeps until
then, and resumes. A reset that passed in the last 30 minutes counts as due now
(the server can lag the clock), with retries spaced by `-FailureBackoffSeconds`.
It still stops if the reset falls after `-MaxHours`, or if no reset time can be
read.

Logs land in `<LogDir>\<project>-<start-time>.log`, one file per run.

## Schedule it overnight

```powershell
$script   = "$env:USERPROFILE\Desktop\claude-autonomous-runner\claude-autonomous-runner.ps1"
$action   = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
  -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" -WorkDir `"C:\path\to\your-project`" -WaitForReset"
$trigger  = New-ScheduledTaskTrigger -Once -At ([datetime]'2026-08-25T03:30:00')
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName 'Claude Autonomous' -Action $action -Trigger $trigger -Settings $settings
```

Check, stop, remove:

```powershell
Get-ScheduledTaskInfo -TaskName 'Claude Autonomous'
Stop-ScheduledTask    -TaskName 'Claude Autonomous'
Unregister-ScheduledTask -TaskName 'Claude Autonomous' -Confirm:$false
```

On macOS or Linux, cron does the same job:

```sh
# 03:30 every night
30 3 * * * pwsh -NoProfile -File ~/claude-autonomous-runner/claude-autonomous-runner.ps1 -WorkDir ~/code/your-project -WaitForReset
```

Review what it did interactively afterwards: `claude --continue` inside the
project folder.

## Honest caveats

- Runs with `--dangerously-skip-permissions`. That is the point — no human at
  3am to click *Allow* — but it means full autonomy over whatever folder you aim
  it at. Choose deliberately.
- Limit detection matches Anthropic CLI error wording ("session limit",
  "usage limit", reset times...). Wording is an undocumented surface and can
  change between versions; the `-MaxHours` cap is the guaranteed backstop.
- Reset times are read as machine-local time; a zone in the message such as
  `(Europe/Dublin)` is ignored. Run it on a machine set to your account's zone.
- On Windows the turn timeout needs `claude.exe` (the native installer). An npm
  `.cmd` shim still works but its turns are not timed out. Elsewhere any
  executable `claude` is timed out.
- Resumes whatever session was **last active in that folder** — nothing else.
- The machine must stay powered on. Asleep mid-run just pauses it.
- It will happily burn your entire remaining quota on the task you give it.

## Development

```powershell
Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser
Invoke-Pester ./tests
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
```

The parsing and decision logic lives in `ClaudeRunner.psm1` and is unit tested
without the CLI. `tests/Runner.Integration.Tests.ps1` drives the real script
against a scripted fake `claude` (compiled C# on Windows, bash elsewhere) to cover
the stop conditions, the reset wait, the turn timeout and the single-instance
lock. CI runs everything under Windows PowerShell 5.1 and under pwsh on Windows,
Linux and macOS.

## License

[MIT](LICENSE)
