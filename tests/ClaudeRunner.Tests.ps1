BeforeAll {
    Import-Module (Join-Path (Split-Path $PSScriptRoot) 'ClaudeRunner.psm1') -Force

    if (-not ('ArgvProbe' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ArgvProbe {
    [DllImport("shell32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CommandLineToArgvW(string cmdLine, out int argc);
    [DllImport("kernel32.dll")]
    static extern IntPtr LocalFree(IntPtr mem);
    public static string[] Split(string cmdLine) {
        int argc;
        IntPtr argv = CommandLineToArgvW(cmdLine, out argc);
        try {
            var result = new string[argc];
            for (int i = 0; i < argc; i++)
                result[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(argv, i * IntPtr.Size));
            return result;
        } finally { LocalFree(argv); }
    }
}
'@
    }

    function Get-JsonTurn([string]$Result, [bool]$IsError = $false, $ApiError = $null, [int]$ExitCode = 0) {
        $json = [ordered]@{
            type = 'result'; subtype = 'success'; is_error = $IsError; result = $Result
            api_error_status = $ApiError; total_cost_usd = 0.25; duration_ms = 1500; num_turns = 3; session_id = 'abc'
        } | ConvertTo-Json -Compress
        ConvertFrom-TurnOutput -Text $json -ExitCode $ExitCode
    }
}

# CommandLineToArgvW is the Windows parser this quoting targets.
Describe 'ConvertTo-WindowsArgument' -Skip:([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    It 'round-trips <Name> through CommandLineToArgvW' -ForEach @(
        @{ Name = 'plain word'; Value = 'hello' }
        @{ Name = 'empty string'; Value = '' }
        @{ Name = 'spaces'; Value = 'Continue working. Reply with exactly: DONE-ALL' }
        @{ Name = 'embedded quotes'; Value = 'say "hi" now' }
        @{ Name = 'trailing backslash'; Value = 'C:\path with space\' }
        @{ Name = 'backslash before quote'; Value = 'a\"b c' }
        @{ Name = 'many backslashes'; Value = 'x \\\\ y\\' }
        @{ Name = 'non-ascii'; Value = 'résumé · naïve' }
    ) {
        $line = 'claude.exe ' + (ConvertTo-WindowsArgument $Value)
        $argv = [ArgvProbe]::Split($line)
        $argv.Count | Should -Be 2
        $argv[1] | Should -BeExactly $Value
    }

    It 'leaves simple flags unquoted' {
        ConvertTo-WindowsArgument '--continue' | Should -BeExactly '--continue'
    }
}

Describe 'ConvertFrom-TurnOutput' {
    It 'reads the JSON result object' {
        $turn = Get-JsonTurn 'all good'
        $turn.IsJson | Should -BeTrue
        $turn.IsError | Should -BeFalse
        $turn.Result | Should -Be 'all good'
        $turn.CostUsd | Should -Be 0.25
        $turn.NumTurns | Should -Be 3
    }

    It 'finds the result line after stderr noise' {
        $json = '{"type":"result","is_error":false,"result":"ok"}'
        $turn = ConvertFrom-TurnOutput -Text "warning: something`r`n$json`r`n" -ExitCode 0
        $turn.IsJson | Should -BeTrue
        $turn.Result | Should -Be 'ok'
    }

    It 'falls back to raw text when no JSON is present' {
        $turn = ConvertFrom-TurnOutput -Text "You've hit your session limit · resets 1:10am (Europe/Dublin)`r`n" -ExitCode 1
        $turn.IsJson | Should -BeFalse
        $turn.IsError | Should -BeTrue
        $turn.Result | Should -Match 'session limit'
    }

    It 'ignores JSON that is not a result object' {
        $turn = ConvertFrom-TurnOutput -Text '{"type":"system"}' -ExitCode 0
        $turn.IsJson | Should -BeFalse
    }

    It 'treats a non-zero exit as an error even if JSON says otherwise' {
        (Get-JsonTurn 'x' -ExitCode 1).IsError | Should -BeTrue
    }

    It 'handles empty output' {
        $turn = ConvertFrom-TurnOutput -Text '' -ExitCode 0
        $turn.Result | Should -Be ''
        Get-TurnOutcome $turn | Should -Be 'Continue'
    }
}

Describe 'Test-DoneSignal' {
    It 'accepts <Reply>' -ForEach @(
        @{ Reply = 'DONE-ALL' }
        @{ Reply = "  DONE-ALL  `r`n" }
        @{ Reply = "Merged the last PR.`n`nDONE-ALL" }
        @{ Reply = '**DONE-ALL**' }
        @{ Reply = '`DONE-ALL`' }
        @{ Reply = 'DONE-ALL.' }
    ) {
        Test-DoneSignal $Reply | Should -BeTrue
    }

    It 'rejects <Reply>' -ForEach @(
        @{ Reply = 'Not DONE-ALL yet: tests still failing.' }
        @{ Reply = "DONE-ALL`nActually, one more thing to fix." }
        @{ Reply = 'done-all' }
        @{ Reply = '' }
        @{ Reply = 'I will reply DONE-ALL when finished' }
    ) {
        Test-DoneSignal $Reply | Should -BeFalse
    }
}

Describe 'Get-TurnOutcome' {
    It 'is Done for a clean completion' {
        Get-TurnOutcome (Get-JsonTurn "Wrapped up.`nDONE-ALL") | Should -Be 'Done'
    }

    It 'is not Done when the completion token comes with an error' {
        Get-TurnOutcome (Get-JsonTurn 'DONE-ALL' -IsError $true) | Should -Be 'Failure'
    }

    It 'is Continue when a successful reply merely discusses limits' {
        $reply = 'Added handling for the usage limit message; it resets at 3pm in tests.'
        Get-TurnOutcome (Get-JsonTurn $reply) | Should -Be 'Continue'
    }

    It 'is Limit for a JSON error carrying quota wording' {
        Get-TurnOutcome (Get-JsonTurn "You've hit your session limit · resets 1:10am" -IsError $true) | Should -Be 'Limit'
    }

    It 'is Limit for an HTTP 429' {
        Get-TurnOutcome (Get-JsonTurn 'API Error' -IsError $true -ApiError 429) | Should -Be 'Limit'
    }

    It 'is Failure for other JSON errors' {
        Get-TurnOutcome (Get-JsonTurn 'API Error: 500' -IsError $true -ApiError 500) | Should -Be 'Failure'
    }

    It 'is Limit for the older timestamped banner' {
        Get-TurnOutcome (ConvertFrom-TurnOutput -Text 'Claude AI usage limit reached|1749924000' -ExitCode 1) | Should -Be 'Limit'
    }

    It 'is Limit for the short plain-text banner even with exit 0' {
        $turn = ConvertFrom-TurnOutput -Text "You've hit your session limit · resets 1:10am (Europe/Dublin)" -ExitCode 0
        Get-TurnOutcome $turn | Should -Be 'Limit'
    }

    It 'is Continue for long plain-text output that mentions limits with exit 0' {
        $text = ('Refactored the rate limit handler. ' * 20)
        Get-TurnOutcome (ConvertFrom-TurnOutput -Text $text -ExitCode 0) | Should -Be 'Continue'
    }

    It 'is Failure for a non-zero exit without limit wording' {
        Get-TurnOutcome (ConvertFrom-TurnOutput -Text 'boom' -ExitCode 1) | Should -Be 'Failure'
    }
}

BeforeDiscovery {
    # IANA zone ids resolve on .NET 6+ (pwsh) everywhere, never on .NET Framework.
    $ianaZones = try { [void][TimeZoneInfo]::FindSystemTimeZoneById('America/New_York'); $true } catch { $false }
}

Describe 'Get-LimitResetTime' {
    BeforeAll { $now = [datetime]'2026-10-07T00:25:00' }

    It 'reads the Unix timestamp form' {
        Get-LimitResetTime 'Claude AI usage limit reached|1749924000' -LocalZone ([TimeZoneInfo]::Utc) |
            Should -Be ([datetime]'2025-06-14T18:00:00')
    }

    It 'reads "reset at" wording' {
        Get-LimitResetTime 'Claude usage limit reached. Your limit will reset at 1pm.' -Now $now |
            Should -Be ([datetime]'2026-10-07T13:00:00')
    }

    It 'converts a zoned reset to local time' -Skip:(-not $ianaZones) {
        Get-LimitResetTime 'resets 1:10am (America/New_York)' -Now ([datetime]'2026-10-07T03:00:00') -LocalZone ([TimeZoneInfo]::Utc) |
            Should -Be ([datetime]'2026-10-07T05:10:00')
    }

    It 'converts a zoned dated reset to local time' -Skip:(-not $ianaZones) {
        Get-LimitResetTime 'resets Oct 9, 4pm (America/New_York)' -Now $now -LocalZone ([TimeZoneInfo]::Utc) |
            Should -Be ([datetime]'2026-10-09T20:00:00')
    }

    It 'applies the grace window on the zone clock' -Skip:(-not $ianaZones) {
        # 01:12 UTC is 21:12 in New York; a 9:10pm New York reset is 2 minutes old.
        Get-LimitResetTime 'resets 9:10pm (America/New_York)' -Now ([datetime]'2026-10-07T01:12:00') -LocalZone ([TimeZoneInfo]::Utc) |
            Should -Be ([datetime]'2026-10-07T01:10:00')
    }

    It 'falls back to local time for a zone it cannot resolve' {
        Get-LimitResetTime 'resets 1:10am (Mars/Olympus_Mons)' -Now $now -LocalZone ([TimeZoneInfo]::Utc) |
            Should -Be ([datetime]'2026-10-07T01:10:00')
    }

    It 'reads a time later today' {
        Get-LimitResetTime "You've hit your session limit · resets 1:10am" -Now $now |
            Should -Be ([datetime]'2026-10-07T01:10:00')
    }

    It 'rolls a time well in the past over to tomorrow' {
        Get-LimitResetTime 'limit reached, resets at 11pm' -Now ([datetime]'2026-10-07T23:45:00') |
            Should -Be ([datetime]'2026-10-08T23:00:00')
    }

    It 'treats a reset that passed within the grace window as due now' {
        Get-LimitResetTime 'limit reached, resets at 12am' -Now $now |
            Should -Be ([datetime]'2026-10-07T00:00:00')
    }

    It 'applies the grace window across midnight' {
        Get-LimitResetTime 'resets 11:50pm' -Now ([datetime]'2026-10-08T00:05:00') |
            Should -Be ([datetime]'2026-10-07T23:50:00')
    }

    It 'honours a custom grace window' {
        Get-LimitResetTime 'resets at 12am' -Now $now -GraceMinutes 10 |
            Should -Be ([datetime]'2026-10-08T00:00:00')
    }

    It 'reads hour-only pm times' {
        Get-LimitResetTime 'usage limit · resets 3pm' -Now $now | Should -Be ([datetime]'2026-10-07T15:00:00')
    }

    It 'treats 12pm as noon' {
        Get-LimitResetTime 'resets 12:30 PM' -Now $now | Should -Be ([datetime]'2026-10-07T12:30:00')
    }

    It 'reads a dated reset' {
        Get-LimitResetTime 'weekly limit · resets Oct 9, 4pm' -Now $now | Should -Be ([datetime]'2026-10-09T16:00:00')
    }

    It 'reads a dated reset with "at" and a full month name' {
        Get-LimitResetTime 'resets on October 9 at 4:15am' -Now $now | Should -Be ([datetime]'2026-10-09T04:15:00')
    }

    It 'rolls a January date seen in December into next year' {
        Get-LimitResetTime 'resets Jan 2, 9am' -Now ([datetime]'2026-12-30T10:00:00') |
            Should -Be ([datetime]'2027-01-02T09:00:00')
    }

    It 'returns null for <Message>' -ForEach @(
        @{ Message = 'usage limit reached' }
        @{ Message = 'resets 13:00pm' }
        @{ Message = 'resets Feb 30, 1am' }
        @{ Message = '' }
    ) {
        Get-LimitResetTime $Message -Now $now | Should -BeNullOrEmpty
    }
}

Describe 'Format-TurnSummary' {
    It 'includes cost and duration for JSON turns' {
        $s = Format-TurnSummary (Get-JsonTurn 'x') 'Continue'
        $s | Should -Match 'exit=0'
        $s | Should -Match 'outcome=Continue'
        $s | Should -Match 'cost=\$0\.2500'
        $s | Should -Match 'duration=2s'
    }

    It 'flags non-JSON turns' {
        Format-TurnSummary (ConvertFrom-TurnOutput -Text 'x' -ExitCode 1) 'Failure' | Should -Match 'non-json'
    }
}
