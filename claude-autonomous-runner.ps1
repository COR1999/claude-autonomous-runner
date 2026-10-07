param(
    [Parameter(Mandatory = $true)]
    [string]$WorkDir,

    # Validated here, at the boundary, so a bad value fails at launch rather
    # than at the first sleep or deadline check hours into a run.
    [ValidateScript({ $_ -gt 0 })][double]$MaxHours = 10,
    [ValidateRange(1, [int]::MaxValue)][int]$FailureLimit = 5,
    [ValidateRange(0, [int]::MaxValue)][int]$TurnDelaySeconds = 5,
    [ValidateRange(0, [int]::MaxValue)][int]$FailureBackoffSeconds = 60,
    [ValidateScript({ $_ -ge 0 })][double]$TurnTimeoutMinutes = 120,
    [ValidateRange(0, [int]::MaxValue)][int]$OutputDrainSeconds = 30,
    [switch]$WaitForReset,
    [ValidateScript({ $_ -ge 0 })][double]$ResetBufferMinutes = 2,
    [string]$LogDir = (Join-Path $PSScriptRoot 'logs'),
    [string]$ClaudePath,
    [ValidateNotNullOrEmpty()][string]$Prompt = "Continue working autonomously on the current task from this session. Make concrete progress without asking questions. If the overall goal is fully complete with nothing left to do, reply with exactly: DONE-ALL"
)

$ErrorActionPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot 'ClaudeRunner.psm1') -Force
$onWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT

if (-not (Test-Path -LiteralPath $WorkDir -PathType Container)) {
    throw "WorkDir does not exist: $WorkDir"
}
$WorkDir = (Resolve-Path -LiteralPath $WorkDir).ProviderPath

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$logBase = Join-Path $LogDir ("{0}-{1}" -f (Split-Path $WorkDir -Leaf), (Get-Date -Format 'yyyyMMdd-HHmmss'))
# Claim the name atomically: two runners started in the same second (a
# double-fired schedule, say) must not write into one log.
for ($n = 1; ; $n++) {
    $logFile = if ($n -eq 1) { "$logBase.log" } else { "$logBase-$n.log" }
    try {
        [IO.File]::Open($logFile, [IO.FileMode]::CreateNew).Dispose()
        break
    } catch [IO.IOException] {
        if ($n -ge 100) { throw }
    }
}

$claude = $ClaudePath
if (-not $claude) { $claude = (Get-Command claude -ErrorAction SilentlyContinue).Source }
if (-not $claude) {
    $claude = [IO.Path]::Combine([Environment]::GetFolderPath('UserProfile'), '.local', 'bin', $(if ($onWindows) { 'claude.exe' } else { 'claude' }))
}
if (-not (Test-Path -LiteralPath $claude)) { throw "claude executable not found: $claude" }
$claude = Resolve-ClaudeExecutable $claude

function Write-RunnerLog([string]$Message) {
    Add-Content -LiteralPath $logFile -Encoding UTF8 -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
}

function Invoke-ClaudeTurn {
    $claudeArgs = @('-p', '--continue', '--dangerously-skip-permissions', '--output-format', 'json', $Prompt)

    $extension = [IO.Path]::GetExtension($claude).ToLowerInvariant()
    $isBinary = if ($onWindows) { $extension -eq '.exe' } else { $extension -ne '.ps1' }
    if (-not $isBinary) {
        # A .cmd/.ps1 that Resolve-ClaudeExecutable could not see through
        # cannot be started (and killed) as a bare process; run it without a
        # timeout.
        $text = & $claude @claudeArgs 2>&1 | Out-String
        return ConvertFrom-TurnOutput -Text $text -ExitCode $LASTEXITCODE
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $claude
    if ($psi.PSObject.Properties['ArgumentList']) {
        foreach ($a in $claudeArgs) { $psi.ArgumentList.Add($a) }
    } else {
        $psi.Arguments = ($claudeArgs | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' '
    }
    $psi.WorkingDirectory = $WorkDir
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8

    try {
        $proc = [Diagnostics.Process]::Start($psi)
    } catch {
        return ConvertFrom-TurnOutput -Text "Could not start ${claude}: $($_.Exception.Message)" -ExitCode 127
    }
    $proc.StandardInput.Close()
    $stdout = New-Object ClaudeRunner.PipeDrain $proc.StandardOutput
    $stderr = New-Object ClaudeRunner.PipeDrain $proc.StandardError

    # If this runner is killed mid-turn, the turn must not live on headless
    # with full permissions: on Windows the job kills it with us; elsewhere
    # the next runner finds it through the turn file and kills it.
    if ($onWindows -and -not [ClaudeRunner.TurnJob]::Attach($proc)) {
        Write-RunnerLog "Could not attach the turn to a kill-on-close job; it may outlive a killed runner."
    }
    Set-Content -LiteralPath $turnFile -Value ("{0} {1}" -f $proc.Id, $proc.StartTime.ToUniversalTime().Ticks)
    Write-RunnerLog "--- turn $turnCount started | pid $($proc.Id) ---"

    $timeoutMs = if ($TurnTimeoutMinutes -gt 0) { [int]($TurnTimeoutMinutes * 60000) } else { -1 }
    $timedOut = -not $proc.WaitForExit($timeoutMs)
    if ($timedOut) {
        Write-RunnerLog "Turn exceeded ${TurnTimeoutMinutes} minutes; killing process tree $($proc.Id)."
        Stop-ProcessTree $proc
        $proc.WaitForExit()
    }

    # A descendant that outlived the CLI can hold the pipes open forever;
    # give the tail a moment to arrive, then take what is there.
    $drained = $stdout.Wait($OutputDrainSeconds * 1000) -and $stderr.Wait($OutputDrainSeconds * 1000)
    if (-not $drained) {
        Write-RunnerLog "Output pipe still held open ${OutputDrainSeconds}s after exit (a leftover child process?); continuing with what was read."
    }

    $text = $stdout.Text
    if ($stderr.Text.Trim()) { $text = $stderr.Text.TrimEnd() + "`r`n" + $text }
    if ($timedOut) {
        return ConvertFrom-TurnOutput -Text ("Turn timed out after $TurnTimeoutMinutes minutes.`r`n" + $text) -ExitCode 124
    }
    ConvertFrom-TurnOutput -Text $text -ExitCode $proc.ExitCode
}

function Stop-ProcessTree([Diagnostics.Process]$Process) {
    if ($onWindows) {
        & taskkill.exe /T /F /PID $Process.Id 2>&1 | Out-Null
    } else {
        # .NET Core 3+: whole tree. Throws if the process already exited.
        try { $Process.Kill($true) } catch [InvalidOperationException] { Write-Verbose 'already exited' }
    }
}

function Stop-LeftoverTurn {
    # A previous runner killed mid-turn (outside Windows, where no job object
    # covers it) leaves its turn running; resuming the same session beside it
    # would interleave two agents. The start time guards against PID reuse.
    if (-not (Test-Path -LiteralPath $turnFile)) { return }
    $fields = (Get-Content -LiteralPath $turnFile -TotalCount 1) -split ' '
    Remove-Item -LiteralPath $turnFile -Force
    if ($fields.Count -ne 2) { return }
    $leftover = Get-Process -Id ([int]$fields[0]) -ErrorAction SilentlyContinue
    if (-not $leftover) { return }
    try { $started = $leftover.StartTime.ToUniversalTime().Ticks } catch { return }
    # .NET on Linux derives StartTime from the system uptime, so two processes
    # can read the same start a few milliseconds apart: allow a second.
    if ([math]::Abs($started - [long]$fields[1]) -gt [TimeSpan]::TicksPerSecond) { return }
    Write-RunnerLog "Killing turn $($leftover.Id) left running by a previous runner."
    Stop-ProcessTree $leftover
    [void]$leftover.WaitForExit(5000)
}

function Wait-Until([datetime]$Until) {
    # Short sleeps against the wall clock, so a machine that slept through
    # part of the wait does not oversleep on wake.
    while ((Get-Date) -lt $Until) {
        $remaining = ($Until - (Get-Date)).TotalSeconds
        Start-Sleep -Seconds ([int][math]::Ceiling([math]::Min(60, [math]::Max(1, $remaining))))
    }
}

# Two runners resuming the same folder would interleave turns in one session.
$sha = [Security.Cryptography.SHA256]::Create()
$identity = if ($onWindows) { $WorkDir.ToLowerInvariant() } else { $WorkDir }
$key = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($identity)) | Select-Object -First 8 | ForEach-Object { $_.ToString('x2') })
$mutex = New-Object System.Threading.Mutex($false, "Global\claude-autonomous-runner-$key")
# Per-user state, not the shared temp dir: on Linux /tmp is world-writable,
# and a planted turn file would make the next runner kill a process of ours.
$appData = [Environment]::GetFolderPath('LocalApplicationData')
if (-not $appData) { $appData = [IO.Path]::GetTempPath() }  # no profile at all
$stateDir = Join-Path $appData 'claude-autonomous-runner'
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
$turnFile = Join-Path $stateDir "$key.turn"
try {
    $ownsMutex = $mutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    $ownsMutex = $true
}
if (-not $ownsMutex) {
    Write-RunnerLog "=== Another runner is already active for $WorkDir; exiting. ==="
    exit 5
}

# Exit codes, so Task Scheduler's "Last Run Result" or cron can tell why a
# run ended. 1 is left to PowerShell for an unhandled error.
$exitCode = 0  # goal complete

try {
    Set-Location -LiteralPath $WorkDir
    $deadline = (Get-Date).AddHours($MaxHours)
    $consecutiveFailures = 0
    $turnCount = 0

    Write-RunnerLog "=== Runner started | workdir: $WorkDir | max hours: $MaxHours | wait for reset: $([bool]$WaitForReset) ==="
    Stop-LeftoverTurn

    while ($true) {
        if ((Get-Date) -ge $deadline) {
            Write-RunnerLog "Stopping: ${MaxHours}-hour safety deadline reached."
            $exitCode = 4
            break
        }

        $turnCount++
        $turn = Invoke-ClaudeTurn
        Remove-Item -LiteralPath $turnFile -ErrorAction SilentlyContinue
        $outcome = Get-TurnOutcome $turn

        Write-RunnerLog ("--- turn {0} | {1} ---`r`n{2}" -f $turnCount, (Format-TurnSummary $turn $outcome), $turn.Result)

        if ($outcome -eq 'Done') {
            Write-RunnerLog "Stopping: model reports goal complete."
            break
        }

        if ($outcome -eq 'Limit') {
            if (-not $WaitForReset) {
                Write-RunnerLog "Stopping: usage/rate limit detected."
                $exitCode = 2
                break
            }
            $resetAt = Get-LimitResetTime $turn.Result
            if ($resetAt) {
                # Never sooner than the failure backoff: a reset that is due
                # now but not yet applied server-side must not busy-loop.
                $resumeAt = $resetAt.AddMinutes($ResetBufferMinutes)
                $earliest = (Get-Date).AddSeconds($FailureBackoffSeconds)
                if ($resumeAt -lt $earliest) { $resumeAt = $earliest }
                if ($resumeAt -ge $deadline) {
                    Write-RunnerLog ("Stopping: limit resets at {0:yyyy-MM-dd HH:mm}, after the safety deadline." -f $resetAt)
                    $exitCode = 2
                    break
                }
                Write-RunnerLog ("Limit hit; sleeping until {0:yyyy-MM-dd HH:mm:ss}." -f $resumeAt)
                Wait-Until $resumeAt
                $consecutiveFailures = 0
                continue
            }
            # A bare API rate limit (HTTP 429) names no reset time and usually
            # clears within minutes: retry it like a failure, which the
            # failure limit still bounds.
            Write-RunnerLog "Limit hit with no readable reset time; retrying after backoff."
            $outcome = 'Failure'
        }

        if ($outcome -eq 'Failure') {
            $consecutiveFailures++
            Write-RunnerLog "Failed turn, failure streak: $consecutiveFailures"
            if ($consecutiveFailures -ge $FailureLimit) {
                Write-RunnerLog "Stopping: $FailureLimit consecutive failed turns."
                $exitCode = 3
                break
            }
            Start-Sleep -Seconds $FailureBackoffSeconds
            continue
        }

        $consecutiveFailures = 0
        Start-Sleep -Seconds $TurnDelaySeconds
    }

    Write-RunnerLog "=== Runner exited | turns: $turnCount | exit code: $exitCode ==="
} finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
exit $exitCode
