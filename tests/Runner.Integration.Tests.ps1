BeforeAll {
    Import-Module (Join-Path (Split-Path $PSScriptRoot) 'ClaudeRunner.psm1') -Force
    $script:onWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
    $script:runner = Join-Path (Split-Path $PSScriptRoot) 'claude-autonomous-runner.ps1'
    $script:psExe = (Get-Process -Id $PID).Path

    # A stand-in for the claude CLI. Each invocation plays the next line of
    # script.tsv ("exit<TAB>sleepSeconds<TAB>stdout[<TAB>holdSeconds]", \n for
    # newlines; the last line repeats), and records its argv and pid next to
    # itself. holdSeconds leaves a grandchild holding stdout open after exit.
    $script:fakeDir = Join-Path ([IO.Path]::GetTempPath()) ('car-fake-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $fakeDir | Out-Null

    if ($onWindows) {
        $script:fake = Join-Path $fakeDir 'claude.exe'
        $source = Join-Path $fakeDir 'fake.cs'
        Set-Content -LiteralPath $source -Encoding ASCII -Value @'
using System; using System.IO; using System.Threading;
public static class Fake {
    public static int Main(string[] args) {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string countFile = Path.Combine(dir, "count");
        int n = File.Exists(countFile) ? int.Parse(File.ReadAllText(countFile).Trim()) : 0;
        File.WriteAllText(countFile, (n + 1).ToString());
        File.WriteAllText(Path.Combine(dir, "pid"), System.Diagnostics.Process.GetCurrentProcess().Id.ToString());
        File.WriteAllLines(Path.Combine(dir, "args"), args);
        string[] lines = File.ReadAllLines(Path.Combine(dir, "script.tsv"));
        string[] parts = lines[Math.Min(n, lines.Length - 1)].Split(new[] { '\t' }, 4);
        Thread.Sleep(int.Parse(parts[1]) * 1000);
        var stdout = Console.OpenStandardOutput();
        byte[] bytes = new System.Text.UTF8Encoding(false).GetBytes(parts[2].Replace("\\n", "\n") + "\n");
        stdout.Write(bytes, 0, bytes.Length);
        stdout.Flush();
        if (parts.Length > 3) {
            var hold = new System.Diagnostics.ProcessStartInfo("cmd.exe", "/c ping -n " + (int.Parse(parts[3]) + 1) + " 127.0.0.1 >nul");
            hold.UseShellExecute = false;
            System.Diagnostics.Process.Start(hold);
        }
        return int.Parse(parts[0]);
    }
}
'@
        $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
        & $csc /nologo /out:$fake $source | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'failed to compile the fake CLI' }
    } else {
        $script:fake = Join-Path $fakeDir 'claude'
        $body = @'
#!/usr/bin/env bash
dir=$(cd "$(dirname "$0")" && pwd)
n=$(cat "$dir/count" 2>/dev/null || echo 0)
echo $((n + 1)) > "$dir/count"
echo $$ > "$dir/pid"
printf '%s\n' "$@" > "$dir/args"
total=$(wc -l < "$dir/script.tsv")
idx=$((n + 1)); [ "$idx" -gt "$total" ] && idx=$total
IFS=$'\t' read -r code secs text hold < <(sed -n "${idx}p" "$dir/script.tsv")
sleep "$secs"
printf '%s\n' "${text//\\n/$'\n'}"
[ -n "$hold" ] && { sleep "$hold" & }
exit "$code"
'@
        [IO.File]::WriteAllText($fake, $body.Replace("`r`n", "`n"))
        & chmod +x $fake
    }

    function Invoke-Runner {
        param([string[]]$Script, [hashtable]$Options = @{})
        foreach ($f in 'count', 'pid', 'args') { Remove-Item -LiteralPath (Join-Path $fakeDir $f) -ErrorAction SilentlyContinue }
        [IO.File]::WriteAllText((Join-Path $fakeDir 'script.tsv'), (($Script -join "`n") + "`n"))

        $work = Join-Path $fakeDir ('work-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        $logs = Join-Path $work '_logs'
        New-Item -ItemType Directory -Path $work | Out-Null

        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runner,
            '-WorkDir', $work, '-LogDir', $logs, '-ClaudePath', $fake, '-MaxHours', '1',
            '-TurnDelaySeconds', '0', '-FailureBackoffSeconds', '0')
        foreach ($k in $Options.Keys) {
            if ($Options[$k] -is [bool]) { if ($Options[$k]) { $argList += "-$k" } }
            else { $argList += "-$k"; $argList += [string]$Options[$k] }
        }
        Invoke-RunnerProcess $argList | Out-Null

        $log = Get-ChildItem -LiteralPath $logs -Filter *.log | Select-Object -First 1
        [pscustomobject]@{
            Log   = [IO.File]::ReadAllText($log.FullName)
            Calls = [int](Get-Content -LiteralPath (Join-Path $fakeDir 'count'))
            Args  = @(Get-Content -LiteralPath (Join-Path $fakeDir 'args') -Encoding UTF8)
        }
    }

    # Runs the runner in a child shell of the same edition, failing rather than
    # hanging the suite if it does not finish.
    function Invoke-RunnerProcess([string[]]$ArgList, [switch]$NoWait) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $psExe
        $psi.UseShellExecute = $false
        if ($psi.PSObject.Properties['ArgumentList']) {
            foreach ($a in $ArgList) { $psi.ArgumentList.Add($a) }
        } else {
            $psi.Arguments = ($ArgList | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' '
        }
        $proc = [Diagnostics.Process]::Start($psi)
        if ($NoWait) { return $proc }
        if (-not $proc.WaitForExit(90000)) {
            $proc.Kill()
            throw "runner did not finish within 90s: $($ArgList -join ' ')"
        }
        $proc
    }

    function Format-ResetClock([datetime]$At) {
        $At.ToString('h:mmtt', [Globalization.CultureInfo]::InvariantCulture).ToLowerInvariant()
    }
}

AfterAll {
    Remove-Item -LiteralPath $fakeDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'claude-autonomous-runner.ps1 end to end' {
    It 'stops when the reply ends with the completion token, passing the prompt intact' {
        # No embedded quotes: Windows PowerShell mangles them on the way into
        # the runner itself. Quoting is covered by the unit tests.
        $prompt = 'Keep going in C:\tmp\ dir, résumé · then reply DONE-ALL'
        $r = Invoke-Runner -Script @("0`t0`t{`"type`":`"result`",`"is_error`":false,`"result`":`"DONE-ALL`",`"total_cost_usd`":0.5}") -Options @{ Prompt = $prompt }
        $r.Calls | Should -Be 1
        $r.Log | Should -Match 'outcome=Done \| cost=\$0\.5000'
        $r.Log | Should -Match 'Stopping: model reports goal complete'
        $r.Args[0..4] -join ' ' | Should -Be '-p --continue --dangerously-skip-permissions --output-format json'
        $r.Args[5] | Should -BeExactly $prompt
    }

    It 'keeps going across turns until done' {
        $r = Invoke-Runner -Script @("0`t0`tstill working", "0`t0`tmore work", "0`t0`tDONE-ALL")
        $r.Calls | Should -Be 3
        $r.Log | Should -Match 'turn 3 \| exit=0 \| outcome=Done'
    }

    It 'does not stop on a long reply that only talks about limits' {
        $chatty = 'Reworked the usage limit handling so it resets at 3pm. ' * 10
        $r = Invoke-Runner -Script @("0`t0`t$chatty", "0`t0`tDONE-ALL")
        $r.Calls | Should -Be 2
    }

    It 'stops on a quota banner without -WaitForReset' {
        $r = Invoke-Runner -Script @("1`t0`tYou've hit your session limit · resets 3am", "0`t0`tDONE-ALL")
        $r.Calls | Should -Be 1
        $r.Log | Should -Match 'Stopping: usage/rate limit detected\.'
        $r.Log | Should -Match '·'   # UTF-8 survives the round trip
    }

    It 'resumes after a reset that is already due with -WaitForReset' {
        $banner = "You've hit your session limit · resets " + (Format-ResetClock (Get-Date).AddMinutes(-1))
        $r = Invoke-Runner -Script @("1`t0`t$banner", "0`t0`tDONE-ALL") -Options @{ WaitForReset = $true; ResetBufferMinutes = 0 }
        $r.Calls | Should -Be 2
        $r.Log | Should -Match 'Limit hit; sleeping until'
        $r.Log | Should -Match 'outcome=Done'
    }

    It 'stops when the reset falls after the deadline' {
        $banner = "usage limit reached · resets " + (Format-ResetClock (Get-Date).AddHours(3))
        $r = Invoke-Runner -Script @("1`t0`t$banner") -Options @{ WaitForReset = $true }
        $r.Calls | Should -Be 1
        $r.Log | Should -Match 'after the safety deadline'
    }

    It 'stops when no reset time can be read' {
        $r = Invoke-Runner -Script @("1`t0`tusage limit reached") -Options @{ WaitForReset = $true }
        $r.Log | Should -Match 'no reset time could be read'
    }

    It 'gives up after the configured run of failures' {
        $r = Invoke-Runner -Script @("1`t0`tboom") -Options @{ FailureLimit = 3 }
        $r.Calls | Should -Be 3
        $r.Log | Should -Match 'Stopping: 3 consecutive failed turns'
    }

    It 'resets the failure streak after a good turn' {
        $r = Invoke-Runner -Script @("1`t0`tboom", "0`t0`tok", "1`t0`tboom", "0`t0`tDONE-ALL") -Options @{ FailureLimit = 2 }
        $r.Calls | Should -Be 4
        $r.Log | Should -Match 'outcome=Done'
    }

    It 'kills a turn that outlives the timeout' {
        $r = Invoke-Runner -Script @("0`t60`tnever printed") -Options @{ TurnTimeoutMinutes = 0.05; FailureLimit = 1 }
        $r.Log | Should -Match 'Turn exceeded'
        $r.Log | Should -Match 'exit=124'
        $fakePid = [int](Get-Content -LiteralPath (Join-Path $fakeDir 'pid'))
        Get-Process -Id $fakePid -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'does not hang when a leftover child keeps the output pipe open' {
        $started = Get-Date
        $r = Invoke-Runner -Script @("0`t0`tDONE-ALL`t30") -Options @{ OutputDrainSeconds = 2 }
        ((Get-Date) - $started).TotalSeconds | Should -BeLessThan 25
        $r.Calls | Should -Be 1
        $r.Log | Should -Match 'Output pipe still held open'
        $r.Log | Should -Match 'outcome=Done'
    }

    It 'refuses to run twice against one folder' {
        [IO.File]::WriteAllText((Join-Path $fakeDir 'script.tsv'), "0`t8`tDONE-ALL`n")
        Remove-Item -LiteralPath (Join-Path $fakeDir 'pid') -ErrorAction SilentlyContinue
        $work = Join-Path $fakeDir 'shared'
        New-Item -ItemType Directory -Path $work | Out-Null
        $common = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runner, '-WorkDir', $work, '-ClaudePath', $fake, '-MaxHours', '1')

        $first = Invoke-RunnerProcess ($common + @('-LogDir', (Join-Path $work 'a'))) -NoWait
        $deadline = (Get-Date).AddSeconds(30)
        while (-not (Test-Path (Join-Path $fakeDir 'pid')) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }

        Invoke-RunnerProcess ($common + @('-LogDir', (Join-Path $work 'b'))) | Out-Null
        $first.WaitForExit()

        (Get-Content -Raw (Get-ChildItem (Join-Path $work 'b') -Filter *.log).FullName) | Should -Match 'Another runner is already active'
        (Get-Content -Raw (Get-ChildItem (Join-Path $work 'a') -Filter *.log).FullName) | Should -Match 'outcome=Done'
    }
}
