Set-StrictMode -Version 2.0

# Wording the CLI uses when a plan or API quota is exhausted. Undocumented and
# version-dependent, so it is only ever matched against error output, never
# against a successful reply (the model may legitimately talk about limits).
$script:LimitPattern = '(?i)session limit|usage limit|rate limit|limit reached|limit has been|hit your .{0,20}limit|resets? (on|at)\b|resets? \d|credit balance'

$script:DoneToken = 'DONE-ALL'

# PipeDrain reads a redirected pipe on a worker thread, keeping whatever has
# arrived: ReadToEnd only returns at EOF, and EOF never comes while any
# descendant (a dev server the model started, say) still holds the pipe open.
# TurnJob ties a turn's process tree to the runner's lifetime on Windows.
if (-not ('ClaudeRunner.TurnJob' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
namespace ClaudeRunner {
    public sealed class PipeDrain {
        private readonly StringBuilder text = new StringBuilder();
        private readonly Task task;
        public PipeDrain(TextReader reader) {
            task = Task.Run(() => {
                var buffer = new char[4096];
                int n;
                while ((n = reader.Read(buffer, 0, buffer.Length)) > 0) {
                    lock (text) { text.Append(buffer, 0, n); }
                }
            });
        }
        public bool Wait(int milliseconds) { return task.Wait(milliseconds); }
        public string Text { get { lock (text) { return text.ToString(); } } }
    }

    // Windows only. Processes assigned here (and everything they spawn) are
    // killed by the OS when this process exits, however it exits: the job
    // handle is never closed explicitly, so it closes with the process.
    public static class TurnJob {
        [StructLayout(LayoutKind.Sequential)]
        struct BasicLimits {
            public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass, SchedulingClass;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct IoCounters { public ulong a, b, c, d, e, f; }
        [StructLayout(LayoutKind.Sequential)]
        struct ExtendedLimits {
            public BasicLimits Basic;
            public IoCounters Io;
            public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
        }
        const uint KillOnJobClose = 0x2000;
        const int ExtendedLimitInformation = 9;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref ExtendedLimits info, uint length);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

        static IntPtr job = IntPtr.Zero;

        public static bool Attach(System.Diagnostics.Process process) {
            if (job == IntPtr.Zero) {
                IntPtr created = CreateJobObject(IntPtr.Zero, null);
                if (created == IntPtr.Zero) return false;
                var info = new ExtendedLimits();
                info.Basic.LimitFlags = KillOnJobClose;
                if (!SetInformationJobObject(created, ExtendedLimitInformation, ref info, (uint)Marshal.SizeOf(info))) return false;
                job = created;
            }
            return AssignProcessToJobObject(job, process.Handle);
        }
    }
}
'@
}

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
    Extracts the reset time from a quota message, as a clock time in LocalZone.

    .DESCRIPTION
    Understands "resets 1:10am", "reset at 3pm", "resets Oct 8, 3pm",
    "resets Oct 8 at 3:30 PM", and the older "usage limit reached|1749924000"
    form whose suffix is a Unix timestamp.

    A trailing zone such as "(Europe/Dublin)" is honoured when the runtime can
    resolve it (pwsh on .NET 6+ knows IANA ids on every OS; Windows PowerShell
    does not), otherwise the time is taken as local.

    A time-only value that passed within the last GraceMinutes is returned
    as-is (the reset is due now); one further in the past means the same
    clock time tomorrow. Returns $null when nothing parses.
    #>
    param(
        [AllowEmptyString()][string]$Message,
        [datetime]$Now = (Get-Date),
        [int]$GraceMinutes = 30,
        [TimeZoneInfo]$LocalZone = [TimeZoneInfo]::Local
    )

    if ([string]::IsNullOrEmpty($Message)) { return $null }
    $nowClock = [datetime]::SpecifyKind($Now, [DateTimeKind]::Unspecified)

    $epoch = [regex]::Match($Message, '(?i)limit reached\|(?<s>\d{10})\b')
    if ($epoch.Success) {
        $utc = [DateTimeOffset]::FromUnixTimeSeconds([long]$epoch.Groups['s'].Value).UtcDateTime
        return [datetime]::SpecifyKind([TimeZoneInfo]::ConvertTimeFromUtc($utc, $LocalZone), [DateTimeKind]::Unspecified)
    }

    $rx = '(?i)resets?\s+(?:on\s+)?(?:(?<mon>jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+(?<day>\d{1,2})(?:st|nd|rd|th)?,?\s+)?(?:at\s+)?(?<h>\d{1,2})(?::(?<m>\d{2}))?\s*(?<ap>am|pm)\b(?:\s*\((?<tz>[A-Za-z][\w+\-]*(?:/[\w+\-]+)+)\))?'
    $match = [regex]::Match($Message, $rx)
    if (-not $match.Success) { return $null }

    $hour = [int]$match.Groups['h'].Value
    $minute = if ($match.Groups['m'].Success) { [int]$match.Groups['m'].Value } else { 0 }
    if ($hour -lt 1 -or $hour -gt 12 -or $minute -gt 59) { return $null }
    $isPm = $match.Groups['ap'].Value -ieq 'pm'
    if ($hour -eq 12) { $hour = 0 }
    if ($isPm) { $hour += 12 }

    # Work on the zone's own wall clock, then convert the answer back.
    $zone = $LocalZone
    if ($match.Groups['tz'].Success) {
        try { $zone = [TimeZoneInfo]::FindSystemTimeZoneById($match.Groups['tz'].Value) } catch { $zone = $LocalZone }
    }
    $zoneNow = if ($zone.Id -eq $LocalZone.Id) { $nowClock } else { [TimeZoneInfo]::ConvertTime($nowClock, $LocalZone, $zone) }

    if ($match.Groups['mon'].Success) {
        $months = 'jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'
        $month = [array]::IndexOf($months, $match.Groups['mon'].Value.Substring(0, 3).ToLowerInvariant()) + 1
        $day = [int]$match.Groups['day'].Value
        if ($day -lt 1 -or $day -gt [datetime]::DaysInMonth($zoneNow.Year, $month)) { return $null }
        $candidate = New-Object datetime ($zoneNow.Year, $month, $day, $hour, $minute, 0)
        # "resets Jan 2" seen on Dec 30 refers to next year.
        if ($candidate -lt $zoneNow.AddDays(-1)) { $candidate = $candidate.AddYears(1) }
    } else {
        # The first occurrence not more than the grace window ago: a server
        # still reporting "resets 1:10am" at 1:12am means "about now".
        $candidate = (New-Object datetime ($zoneNow.Year, $zoneNow.Month, $zoneNow.Day, $hour, $minute, 0)).AddDays(-1)
        while ($candidate -lt $zoneNow.AddMinutes(-$GraceMinutes)) { $candidate = $candidate.AddDays(1) }
    }

    if ($zone.Id -eq $LocalZone.Id) { return $candidate }
    try {
        [TimeZoneInfo]::ConvertTime($candidate, $zone, $LocalZone)
    } catch [ArgumentException] {
        # A wall-clock time skipped by a DST change; an hour late is harmless.
        [TimeZoneInfo]::ConvertTime($candidate.AddHours(1), $zone, $LocalZone)
    }
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

function Resolve-ClaudeExecutable {
    <#
    .SYNOPSIS
    Sees through an npm shim to the native executable it launches.

    .DESCRIPTION
    npm exposes package binaries on Windows as claude.cmd / claude.ps1 shims.
    Current @anthropic-ai/claude-code ships bin/claude.exe, so the shim only
    runs that exe; launching it directly lets the runner time out, job-attach
    and drain the turn like any native install. Anything that does not look
    like such a shim, or whose target is missing, is returned unchanged.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    $extension = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($extension -notin '.cmd', '.ps1') { return $Path }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $Path }

    # cmd-shim writes "%dp0%\<relative>.exe" (.cmd) or "$basedir/<relative>.exe" (.ps1).
    $match = [regex]::Match([IO.File]::ReadAllText($Path), '(?:%dp0%|\$basedir)[\\/]+(?<rel>[^"%$]+?\.exe)"')
    if (-not $match.Success) { return $Path }

    $target = Join-Path (Split-Path -Parent $Path) $match.Groups['rel'].Value
    if (Test-Path -LiteralPath $target -PathType Leaf) { return (Resolve-Path -LiteralPath $target).ProviderPath }
    $Path
}

Export-ModuleMember -Function ConvertTo-WindowsArgument, ConvertFrom-TurnOutput, Test-DoneSignal, Test-LimitMessage, Get-TurnOutcome, Get-LimitResetTime, Format-TurnSummary, Resolve-ClaudeExecutable
