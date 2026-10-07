# claude-autonomous-runner

Keep **Claude Code** working unattended. A small PowerShell loop that relaunches
headless turns back-to-back so the model never sits idle waiting for input — and
either stops cleanly when your usage limit hits or sleeps until it resets.

Proven in real use: scheduled overnight, it resumed a session and merged 14 PRs
in about an hour before the quota stopped it.

## How it works

```
Task Scheduler / cron / manual launch
  └─> cd <your project>
       └─> loop:
             claude -p --continue --dangerously-skip-permissions --output-format json "<prompt>"
             ├─ reply ends with DONE-ALL      -> stop, exit 0 (goal complete)
             ├─ error carries limit wording   -> stop, exit 2 — or with -WaitForReset,
             │                                   sleep until the reset it names
             ├─ turn runs past the timeout    -> kill its process tree, count a failure
             ├─ N consecutive failures        -> stop, exit 3 (something broke)
             └─ max-hours cap                 -> stop, exit 4 (runaway backstop)
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
| `-OutputDrainSeconds` | `30` | After the CLI exits, how long to wait for a child process still holding its output open |
| `-WaitForReset` | off | On a quota limit, sleep until the reset time it reports, then carry on |
| `-ResetBufferMinutes` | `2` | Extra wait after the reported reset |
| `-LogDir` | `logs\` next to the script | Where run logs go |
| `-ClaudePath` | `claude` on PATH, then `~\.localin\claude.exe` | CLI to run |
| `-Prompt` | continue-and-report-DONE-ALL | The instruction sent each turn |

Only one runner can work a given folder at a time; a second one logs that and
exits instead of interleaving turns into the same session. Stopping the runner
also stops its turn: on Windows the turn sits in a kill-on-close job object, and
elsewhere the next runner on that folder kills any turn its predecessor left
running. Each turn logs a `started | pid` line as it begins, so a long turn is
visibly in progress rather than silent.

With `-WaitForReset` a 5-hour session limit no longer ends the night: the runner
reads `resets 1:10am`, `resets Oct 9, 4pm (Europe/Dublin)` or the older
`usage limit reached|<unix time>` from the message, sleeps until then, and
resumes. A reset that passed in the last 30 minutes counts as due now (the
server can lag the clock), with retries spaced by `-FailureBackoffSeconds`. A
limit with no reset time in it, such as a bare API 429, is retried like a failed
turn. The run still stops if the reset falls after `-MaxHours`.

Logs land in `<LogDir>\<project>-<start-time>.log`, one file per run (a `-2`,
`-3`, ... suffix is added if another run already took that name).

The exit code says why the run ended, which shows up as Task Scheduler's
*Last Run Result* or in cron mail:

| Code | Meaning |
|---|---|
| `0` | Model reported the goal complete |
| `1` | The runner itself failed (bad `-WorkDir`, CLI not found, ...) |
| `2` | Quota limit (without `-WaitForReset`, or the reset is past `-MaxHours`) |
| `3` | `-FailureLimit` consecutive failed turns |
| `4` | `-MaxHours` deadline reached |
| `5` | Another runner already owns this folder |

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
- A zone in the reset message such as `(Europe/Dublin)` is honoured under pwsh
  7. Windows PowerShell 5.1 cannot resolve those names, so there the time is
  read as machine-local: keep the machine on your account's zone, or use pwsh.
- An npm install's `claude.cmd` / `claude.ps1` shim is resolved to the
  `claude.exe` it launches, so it gets the same timeout and cleanup as the native
  installer. A shim the runner cannot see through still works, but its turns
  are not timed out.
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
