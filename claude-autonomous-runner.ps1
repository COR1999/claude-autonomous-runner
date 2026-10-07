param(
    [Parameter(Mandatory = $true)]
    [string]$WorkDir,

    [double]$MaxHours = 10,
    [int]$FailureLimit = 5,
    [int]$TurnDelaySeconds = 5,
    [int]$FailureBackoffSeconds = 60,
    [double]$TurnTimeoutMinutes = 120,
    [switch]$WaitForReset,
    [double]$ResetBufferMinutes = 2,
    [string]$LogDir = (Join-Path $PSScriptRoot 'logs'),
    [string]$ClaudePath,
    [string]$Prompt = "Continue working autonomously on the current task from this session. Make concrete progress without asking questions. If the overall goal is fully complete with nothing left to do, reply with exactly: DONE-ALL"
)

$ErrorActionPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot 'ClaudeRunner.psm1') -Force
$onWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT

if (-not (Test-Path -LiteralPath $WorkDir -PathType Container)) {
    throw "WorkDir does not exist: $WorkDir"
}
$WorkDir = (Resolve-Path -LiteralPath $WorkDir).ProviderPath

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$timeStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile = Join-Path $LogDir ("{0}-{1}.log" -f (Split-Path $WorkDir -Leaf), $timeStamp)

$claude = $ClaudePath
if (-not $claude) { $claude = (Get-Command claude -ErrorAction SilentlyContinue).Source }
if (-not $claude) {
    $claude = [IO.Path]::Combine([Environment]::GetFolderPath('UserProfile'), '.local', 'bin', $(if ($onWindows) { 'claude.exe' } else { 'claude' }))
}
if (-not (Test-Path -LiteralPath $claude)) { throw "claude executable not found: $claude" }

function Write-RunnerLog([string]$Message) {
    Add-Content -LiteralPath $logFile -Encoding UTF8 -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
}

function Invoke-ClaudeTurn {
    $claudeArgs = @('-p', '--continue', '--dangerously-skip-permissions', '--output-format', 'json', $Prompt)

    $extension = [IO.Path]::GetExtension($claude).ToLowerInvariant()
    $isBinary = if ($onWindows) { $extension -eq '.exe' } else { $extension -ne '.ps1' }
    if (-not $isBinary) {
        # npm installs on Windows expose claude as a .cmd/.ps1 shim, which
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

    $proc = [Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Close()
    $stdout = $proc.StandardOutput.ReadToEndAsync()
    $stderr = $proc.StandardError.ReadToEndAsync()

    $timeoutMs = if ($TurnTimeoutMinutes -gt 0) { [int]($TurnTimeoutMinutes * 60000) } else { -1 }
    if (-not $proc.WaitForExit($timeoutMs)) {
        Write-RunnerLog "Turn exceeded ${TurnTimeoutMinutes} minutes; killing process tree $($proc.Id)."
        if ($onWindows) {
            & taskkill.exe /T /F /PID $proc.Id 2>&1 | Out-Null
        } else {
            $proc.Kill($true)  # .NET Core 3+: whole tree
        }
        $proc.WaitForExit()
        $text = "Turn timed out after $TurnTimeoutMinutes minutes.`r`n" + $stdout.Result + $stderr.Result
        return ConvertFrom-TurnOutput -Text $text -ExitCode 124
    }
    $proc.WaitForExit()  # flushes the async readers

    $text = $stdout.Result
    if ($stderr.Result.Trim()) { $text = $stderr.Result.TrimEnd() + "`r`n" + $text }
    ConvertFrom-TurnOutput -Text $text -ExitCode $proc.ExitCode
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
try {
    $ownsMutex = $mutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    $ownsMutex = $true
}
if (-not $ownsMutex) {
    Write-RunnerLog "=== Another runner is already active for $WorkDir; exiting. ==="
    return
}

try {
    Set-Location -LiteralPath $WorkDir
    $deadline = (Get-Date).AddHours($MaxHours)
    $consecutiveFailures = 0
    $turnCount = 0

    Write-RunnerLog "=== Runner started | workdir: $WorkDir | max hours: $MaxHours | wait for reset: $([bool]$WaitForReset) ==="

    while ($true) {
        if ((Get-Date) -ge $deadline) {
            Write-RunnerLog "Stopping: ${MaxHours}-hour safety deadline reached."
            break
        }

        $turn = Invoke-ClaudeTurn
        $turnCount++
        $outcome = Get-TurnOutcome $turn

        Write-RunnerLog ("--- turn {0} | {1} ---`r`n{2}" -f $turnCount, (Format-TurnSummary $turn $outcome), $turn.Result)

        if ($outcome -eq 'Done') {
            Write-RunnerLog "Stopping: model reports goal complete."
            break
        }

        if ($outcome -eq 'Limit') {
            if (-not $WaitForReset) {
                Write-RunnerLog "Stopping: usage/rate limit detected."
                break
            }
            $resetAt = Get-LimitResetTime $turn.Result
            if (-not $resetAt) {
                Write-RunnerLog "Stopping: usage/rate limit detected, but no reset time could be read from it."
                break
            }
            # Never sooner than the failure backoff: a reset that is due now
            # but not yet applied server-side must not become a busy loop.
            $resumeAt = $resetAt.AddMinutes($ResetBufferMinutes)
            $earliest = (Get-Date).AddSeconds($FailureBackoffSeconds)
            if ($resumeAt -lt $earliest) { $resumeAt = $earliest }
            if ($resumeAt -ge $deadline) {
                Write-RunnerLog ("Stopping: limit resets at {0:yyyy-MM-dd HH:mm}, after the safety deadline." -f $resetAt)
                break
            }
            Write-RunnerLog ("Limit hit; sleeping until {0:yyyy-MM-dd HH:mm:ss}." -f $resumeAt)
            Wait-Until $resumeAt
            $consecutiveFailures = 0
            continue
        }

        if ($outcome -eq 'Failure') {
            $consecutiveFailures++
            Write-RunnerLog "Failed turn, failure streak: $consecutiveFailures"
            if ($consecutiveFailures -ge $FailureLimit) {
                Write-RunnerLog "Stopping: $FailureLimit consecutive failed turns."
                break
            }
            Start-Sleep -Seconds $FailureBackoffSeconds
            continue
        }

        $consecutiveFailures = 0
        Start-Sleep -Seconds $TurnDelaySeconds
    }

    Write-RunnerLog "=== Runner exited | turns: $turnCount ==="
} finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
