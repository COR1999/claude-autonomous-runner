param(
    [Parameter(Mandatory = $true)]
    [string]$WorkDir,

    [int]$MaxHours = 10,
    [int]$FailureLimit = 5,
    [int]$TurnDelaySeconds = 5,
    [string]$LogDir = (Join-Path $PSScriptRoot 'logs'),
    [string]$Prompt = "Continue working autonomously on the current task from this session. Make concrete progress without asking questions. If the overall goal is fully complete with nothing left to do, reply with exactly: DONE-ALL"
)

$ErrorActionPreference = 'Continue'

if (-not (Test-Path -LiteralPath $WorkDir)) {
    throw "WorkDir does not exist: $WorkDir"
}

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$timeStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile = Join-Path $LogDir ("{0}-{1}.log" -f (Split-Path $WorkDir -Leaf), $timeStamp)

$claude = (Get-Command claude -ErrorAction SilentlyContinue).Source
if (-not $claude) { $claude = Join-Path $env:USERPROFILE '.local\bin\claude.exe' }
if (-not (Test-Path -LiteralPath $claude)) { throw "claude executable not found on PATH or at $env:USERPROFILE\.local\bin\claude.exe" }

function Write-Log([string]$Message) {
    Add-Content -LiteralPath $logFile -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
}

Set-Location -LiteralPath $WorkDir
$deadline = (Get-Date).AddHours($MaxHours)
$consecutiveFailures = 0

Write-Log "=== Runner started | workdir: $WorkDir | max hours: $MaxHours ==="

while ($true) {
    if ((Get-Date) -ge $deadline) {
        Write-Log "Stopping: ${MaxHours}-hour safety deadline reached."
        break
    }

    $out = & $claude -p --continue --dangerously-skip-permissions $Prompt 2>&1 | Out-String
    Add-Content -LiteralPath $logFile -Value ("[{0}] --- turn output ---`r`n{1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $out.TrimEnd())

    if ($LASTEXITCODE -eq 0 -and $out -match 'DONE-ALL') {
        Write-Log "Stopping: model reports goal complete."
        break
    }

    if ($out -match '(?i)session limit|usage limit|rate limit|limit reached|limit has been|hit your .{0,20}limit|resets? (on|at)\b|resets? \d|credit balance') {
        Write-Log "Stopping: usage/rate limit detected."
        break
    }

    if ($LASTEXITCODE -ne 0) {
        $consecutiveFailures++
        Write-Log "Non-zero exit ($LASTEXITCODE), failure streak: $consecutiveFailures"
        if ($consecutiveFailures -ge $FailureLimit) {
            Write-Log "Stopping: $FailureLimit consecutive failed turns."
            break
        }
        Start-Sleep -Seconds 60
        continue
    }

    $consecutiveFailures = 0
    Start-Sleep -Seconds $TurnDelaySeconds
}

Write-Log "=== Runner exited ==="
