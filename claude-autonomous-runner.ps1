param(
    [Parameter(Mandatory = $true)]
    [string]$WorkDir,

    [int]$MaxHours = 10,
    [int]$FailureLimit = 5,
    [int]$TurnDelaySeconds = 5,
    [int]$FailureBackoffSeconds = 60,
    [int]$TurnTimeoutMinutes = 120,
    [switch]$WaitForReset,
    [int]$ResetBufferMinutes = 2,
    [string]$LogDir = (Join-Path $PSScriptRoot 'logs'),
    [string]$ClaudePath,
    [string]$Prompt = "Continue working autonomously on the current task from this session. Make concrete progress without asking questions. If the overall goal is fully complete with nothing left to do, reply with exactly: DONE-ALL"
)

$ErrorActionPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot 'ClaudeRunner.psm1') -Force

if (-not (Test-Path -LiteralPath $WorkDir -PathType Container)) {
    throw "WorkDir does not exist: $WorkDir"
}
$WorkDir = (Resolve-Path -LiteralPath $WorkDir).ProviderPath

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$timeStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile = Join-Path $LogDir ("{0}-{1}.log" -f (Split-Path $WorkDir -Leaf), $timeStamp)

$claude = $ClaudePath
if (-not $claude) { $claude = (Get-Command claude -ErrorAction SilentlyContinue).Source }
if (-not $claude) { $claude = Join-Path $env:USERPROFILE '.local\bin\claude.exe' }
if (-not (Test-Path -LiteralPath $claude)) { throw "claude executable not found: $claude" }

function Write-Log([string]$Message) {
    Add-Content -LiteralPath $logFile -Encoding UTF8 -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
}

function Invoke-ClaudeTurn {
    $claudeArgs = @('-p', '--continue', '--dangerously-skip-permissions', '--output-format', 'json', $Prompt)

    if ([IO.Path]::GetExtension($claude) -ne '.exe') {
        # npm installs expose claude as a .cmd/.ps1 shim, which cannot be
        # started (and killed) as a bare process; run it without a timeout.
        $text = & $claude @claudeArgs 2>&1 | Out-String
        return ConvertFrom-TurnOutput -Text $text -ExitCode $LASTEXITCODE
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $claude
    $psi.Arguments = ($claudeArgs | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' '
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

    $timeoutMs = if ($TurnTimeoutMinutes -gt 0) { $TurnTimeoutMinutes * 60000 } else { -1 }
    if (-not $proc.WaitForExit($timeoutMs)) {
        Write-Log "Turn exceeded ${TurnTimeoutMinutes} minutes; killing process tree $($proc.Id)."
        & taskkill.exe /T /F /PID $proc.Id 2>&1 | Out-Null
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
$key = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($WorkDir.ToLowerInvariant())) | Select-Object -First 8 | ForEach-Object { $_.ToString('x2') })
$mutex = New-Object System.Threading.Mutex($false, "Global\claude-autonomous-runner-$key")
try {
    $ownsMutex = $mutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    $ownsMutex = $true
}
if (-not $ownsMutex) {
    Write-Log "=== Another runner is already active for $WorkDir; exiting. ==="
    return
}

try {
    Set-Location -LiteralPath $WorkDir
    $deadline = (Get-Date).AddHours($MaxHours)
    $consecutiveFailures = 0
    $turnCount = 0

    Write-Log "=== Runner started | workdir: $WorkDir | max hours: $MaxHours | wait for reset: $([bool]$WaitForReset) ==="

    while ($true) {
        if ((Get-Date) -ge $deadline) {
            Write-Log "Stopping: ${MaxHours}-hour safety deadline reached."
            break
        }

        $turn = Invoke-ClaudeTurn
        $turnCount++
        $outcome = Get-TurnOutcome $turn

        Write-Log ("--- turn {0} | {1} ---`r`n{2}" -f $turnCount, (Format-TurnSummary $turn $outcome), $turn.Result)

        if ($outcome -eq 'Done') {
            Write-Log "Stopping: model reports goal complete."
            break
        }

        if ($outcome -eq 'Limit') {
            if (-not $WaitForReset) {
                Write-Log "Stopping: usage/rate limit detected."
                break
            }
            $resetAt = Get-LimitResetTime $turn.Result
            if (-not $resetAt) {
                Write-Log "Stopping: usage/rate limit detected, but no reset time could be read from it."
                break
            }
            $resumeAt = $resetAt.AddMinutes($ResetBufferMinutes)
            if ($resumeAt -ge $deadline) {
                Write-Log ("Stopping: limit resets at {0:yyyy-MM-dd HH:mm}, after the safety deadline." -f $resetAt)
                break
            }
            Write-Log ("Limit hit; sleeping until {0:yyyy-MM-dd HH:mm}." -f $resumeAt)
            Wait-Until $resumeAt
            $consecutiveFailures = 0
            continue
        }

        if ($outcome -eq 'Failure') {
            $consecutiveFailures++
            Write-Log "Failed turn, failure streak: $consecutiveFailures"
            if ($consecutiveFailures -ge $FailureLimit) {
                Write-Log "Stopping: $FailureLimit consecutive failed turns."
                break
            }
            Start-Sleep -Seconds $FailureBackoffSeconds
            continue
        }

        $consecutiveFailures = 0
        Start-Sleep -Seconds $TurnDelaySeconds
    }

    Write-Log "=== Runner exited | turns: $turnCount ==="
} finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
