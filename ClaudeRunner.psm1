Set-StrictMode -Version 2.0

# Wording the CLI uses when a plan or API quota is exhausted. Undocumented and
# version-dependent, so it is only ever matched against error output, never
# against a successful reply (the model may legitimately talk about limits).
$script:LimitPattern = '(?i)session limit|usage limit|rate limit|limit reached|limit has been|hit your .{0,20}limit|resets? (on|at)\b|resets? \d|credit balance'

$script:DoneToken = 'DONE-ALL'

function ConvertTo-WindowsArgument {
    <#
    .SYNOPSIS
    Quotes one argument so CommandLineToArgvW / the MSVC runtime parse it back verbatim.
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $backslashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\') {
            $backslashes++
            continue
        }
        if ($ch -eq '"') {
            [void]$sb.Append([char]'\', 2 * $backslashes + 1)
        } elseif ($backslashes -gt 0) {
            [void]$sb.Append([char]'\', $backslashes)
        }
        $backslashes = 0
        [void]$sb.Append($ch)
    }
    # Backslashes before the closing quote must be doubled or they escape it.
    if ($backslashes -gt 0) { [void]$sb.Append([char]'\', 2 * $backslashes) }
    [void]$sb.Append('"')
    $sb.ToString()
}

function ConvertFrom-TurnOutput {
    <#
    .SYNOPSIS
    Normalises one `claude -p` run into a turn record.

    .DESCRIPTION
    With --output-format json the CLI prints a single result object. Anything
    else (stderr noise, a plain-text error printed before JSON mode engaged)
    is tolerated: the last line that parses as a result object wins, and if
    none does the raw text becomes the result with IsJson = $false.
    #>
    param(
        [AllowEmptyString()][string]$Text,
        [int]$ExitCode
    )

    if ($null -eq $Text) { $Text = '' }

    $turn = [pscustomobject]@{
        ExitCode       = $ExitCode
        IsJson         = $false
        IsError        = ($ExitCode -ne 0)
        Result         = $Text.Trim()
        ApiErrorStatus = $null
        CostUsd        = $null
        DurationMs     = $null
        NumTurns       = $null
        SessionId      = $null
        Raw            = $Text
    }

    $lines = $Text -split "`r?`n"
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $line = $lines[$i].Trim()
        if (-not $line.StartsWith('{')) { continue }
        try { $obj = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if ($obj.PSObject.Properties['type'] -and $obj.type -eq 'result') {
            $turn.IsJson = $true
            $turn.IsError = ($ExitCode -ne 0) -or ($obj.PSObject.Properties['is_error'] -and [bool]$obj.is_error)
            $turn.Result = if ($obj.PSObject.Properties['result'] -and $null -ne $obj.result) { ([string]$obj.result).Trim() } else { '' }
            foreach ($map in @(
                    @('ApiErrorStatus', 'api_error_status'),
                    @('CostUsd', 'total_cost_usd'),
                    @('DurationMs', 'duration_ms'),
                    @('NumTurns', 'num_turns'),
                    @('SessionId', 'session_id'))) {
                if ($obj.PSObject.Properties[$map[1]]) { $turn.($map[0]) = $obj.($map[1]) }
            }
            break
        }
    }
    $turn
}

function Test-DoneSignal {
    <#
    .SYNOPSIS
    True when the reply's final line is the completion token.

    .DESCRIPTION
    Matching the token anywhere would stop the runner on a reply such as
    "not DONE-ALL yet, still have tests to fix". Only a final line consisting
    of the token (allowing markdown emphasis / code ticks / a trailing period)
    counts.
    #>
    param([AllowEmptyString()][string]$Reply)

    if ([string]::IsNullOrWhiteSpace($Reply)) { return $false }
    $last = ($Reply.Trim() -split "`r?`n")[-1].Trim()
    $last = $last.Trim('*', '_', '`', ' ', '.')
    $last -ceq $script:DoneToken
}

function Test-LimitMessage {
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $false }
    $Text -match $script:LimitPattern
}

function Get-TurnOutcome {
    <#
    .SYNOPSIS
    Classifies a turn record: Done, Limit, Failure or Continue.
    #>
    param([Parameter(Mandatory = $true)]$Turn)

    if (-not $Turn.IsError -and (Test-DoneSignal $Turn.Result)) { return 'Done' }

    if ($Turn.IsJson) {
        if ($Turn.IsError -and ($Turn.ApiErrorStatus -eq 429 -or (Test-LimitMessage $Turn.Result))) { return 'Limit' }
    } else {
        # Without JSON we cannot tell a reply from an error banner. The quota
        # banner is a single short line, so only short output is trusted.
        if (Test-LimitMessage $Turn.Result) {
            if ($Turn.IsError -or $Turn.Result.Length -le 300) { return 'Limit' }
        }
    }

    if ($Turn.IsError) { return 'Failure' }
    'Continue'
}

function Get-LimitResetTime {
    <#
    .SYNOPSIS
    Extracts the reset time from a quota message, as a local DateTime.

    .DESCRIPTION
    Understands "resets 1:10am", "resets at 3pm", "resets Oct 8, 3pm" and
    "resets Oct 8 at 3:30 PM". A trailing "(Europe/Dublin)" style zone is
    ignored: the time is taken as machine-local, which is what the CLI prints
    for the logged-in user. A time-only value that passed within the last
    GraceMinutes is returned as-is (the reset is due now); one further in the
    past means the same clock time tomorrow. Returns $null when nothing parses.
    #>
    param(
        [AllowEmptyString()][string]$Message,
        [datetime]$Now = (Get-Date),
        [int]$GraceMinutes = 30
    )

    if ([string]::IsNullOrEmpty($Message)) { return $null }

    $rx = '(?i)resets?\s+(?:on\s+)?(?:(?<mon>jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+(?<day>\d{1,2})(?:st|nd|rd|th)?,?\s+)?(?:at\s+)?(?<h>\d{1,2})(?::(?<m>\d{2}))?\s*(?<ap>am|pm)\b'
    $match = [regex]::Match($Message, $rx)
    if (-not $match.Success) { return $null }

    $hour = [int]$match.Groups['h'].Value
    $minute = if ($match.Groups['m'].Success) { [int]$match.Groups['m'].Value } else { 0 }
    if ($hour -lt 1 -or $hour -gt 12 -or $minute -gt 59) { return $null }
    $isPm = $match.Groups['ap'].Value -ieq 'pm'
    if ($hour -eq 12) { $hour = 0 }
    if ($isPm) { $hour += 12 }

    if ($match.Groups['mon'].Success) {
        $months = 'jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'
        $month = [array]::IndexOf($months, $match.Groups['mon'].Value.Substring(0, 3).ToLowerInvariant()) + 1
        $day = [int]$match.Groups['day'].Value
        if ($day -lt 1 -or $day -gt [datetime]::DaysInMonth($Now.Year, $month)) { return $null }
        $candidate = New-Object datetime ($Now.Year, $month, $day, $hour, $minute, 0, [System.DateTimeKind]::Local)
        # "resets Jan 2" seen on Dec 30 refers to next year.
        if ($candidate -lt $Now.AddDays(-1)) { $candidate = $candidate.AddYears(1) }
        return $candidate
    }

    # The first occurrence not more than the grace window ago: a server still
    # reporting "resets 1:10am" at 1:12am means "about now", not tomorrow.
    $candidate = (New-Object datetime ($Now.Year, $Now.Month, $Now.Day, $hour, $minute, 0, [System.DateTimeKind]::Local)).AddDays(-1)
    while ($candidate -lt $Now.AddMinutes(-$GraceMinutes)) { $candidate = $candidate.AddDays(1) }
    $candidate
}

function Format-TurnSummary {
    param([Parameter(Mandatory = $true)]$Turn, [string]$Outcome)

    $parts = @("exit=$($Turn.ExitCode)", "outcome=$Outcome")
    if ($Turn.IsJson) {
        if ($null -ne $Turn.CostUsd) { $parts += ('cost=${0:N4}' -f [double]$Turn.CostUsd) }
        if ($null -ne $Turn.DurationMs) { $parts += ('duration={0:N0}s' -f ([double]$Turn.DurationMs / 1000)) }
        if ($null -ne $Turn.NumTurns) { $parts += "steps=$($Turn.NumTurns)" }
        if ($null -ne $Turn.ApiErrorStatus) { $parts += "api_error=$($Turn.ApiErrorStatus)" }
    } else {
        $parts += 'non-json'
    }
    $parts -join ' | '
}

Export-ModuleMember -Function ConvertTo-WindowsArgument, ConvertFrom-TurnOutput, Test-DoneSignal, Test-LimitMessage, Get-TurnOutcome, Get-LimitResetTime, Format-TurnSummary
