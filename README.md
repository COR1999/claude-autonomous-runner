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
             claude -p --continue --dangerously-skip-permissions "<prompt>"
             ├─ model replies DONE-ALL      -> stop (goal complete)
             ├─ output matches limit wording -> stop (quota gone)
             ├─ N consecutive failures       -> stop (something broke)
             └─ max-hours cap                -> stop (runaway backstop)
```

The whole trick is `claude -p --continue`: headless mode that resumes the most
recent session in the folder, does one autonomous turn, then exits. Loop it and
you get continuous unattended work; every turn's output lands in a timestamped
log so you can review everything afterwards.

## Requirements

- Windows with PowerShell 5.1+ (macOS/Linux port welcome)
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
| `-MaxHours` | `10` | Safety deadline; always stops by this |
| `-FailureLimit` | `5` | Consecutive failed turns before giving up |
| `-TurnDelaySeconds` | `5` | Pause between turns |
| `-LogDir` | `logs\` next to the script | Where run logs go |
| `-Prompt` | continue-and-report-DONE-ALL | The instruction sent each turn |

Logs land in `<LogDir>\<project>-<start-time>.log`, one file per run.

## Schedule it overnight

```powershell
$script   = "$env:USERPROFILE\Desktop\claude-autonomous-runner\claude-autonomous-runner.ps1"
$action   = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
  -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" -WorkDir `"C:\path\to\your-project`""
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

Review what it did interactively afterwards: `claude --continue` inside the
project folder.

## Honest caveats

- Runs with `--dangerously-skip-permissions`. That is the point — no human at
  3am to click *Allow* — but it means full autonomy over whatever folder you aim
  it at. Choose deliberately.
- Limit detection matches Anthropic CLI error wording ("session limit",
  "usage limit", reset times...). Wording is an undocumented surface and can
  change between versions; the `-MaxHours` cap is the guaranteed backstop.
- Resumes whatever session was **last active in that folder** — nothing else.
- The machine must stay powered on. Asleep mid-run just pauses it.
- It will happily burn your entire remaining quota on the task you give it.

## License

[MIT](LICENSE)
