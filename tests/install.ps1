. (Join-Path $PSScriptRoot 'common.ps1')
Import-TestNative

$env:AUTOSHUTDOWN_NO_DIALOG = '1'
$installDir = Join-Path $env:LOCALAPPDATA 'AutoShutdown'
$installed  = Join-Path $installDir 'AutoShutdown.ps1'
$psExe      = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

function Invoke-AppScript([string]$Path, [string[]]$Arguments = @()) {
    $ErrorActionPreference = 'Continue'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    if ($Path -like '*.cmd') {
        $out = & cmd.exe /c "`"$Path`" < nul" 2>&1 | Out-String
    }
    else {
        $out = & $psExe -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments 2>&1 | Out-String
    }
    $code = $LASTEXITCODE
    $sw.Stop()
    Write-Host "exit=$code seconds=$([math]::Round($sw.Elapsed.TotalSeconds, 1))"
    Write-Host $out
    return [pscustomobject]@{ Code = $code; Output = $out; Seconds = $sw.Elapsed.TotalSeconds }
}

function Write-ProcessTree($Proc) {
    $parent = Get-CimInstance Win32_Process -Filter "ProcessId = $($Proc.ParentProcessId)" -ErrorAction SilentlyContinue
    Write-Host "pid=$($Proc.ProcessId) parent=$($Proc.ParentProcessId) ($($parent.Name)) cmd=$($Proc.CommandLine)"
}

# Returns Start menu shortcuts that launch the installed script.
function Get-StartMenuLinks {
    $shell = New-Object -ComObject WScript.Shell
    $dir = [Environment]::GetFolderPath('Programs')
    return @(Get-ChildItem -LiteralPath $dir -Filter '*.lnk' | Where-Object {
        $shell.CreateShortcut($_.FullName).Arguments -like '*AutoShutdown.ps1*'
    })
}

Write-Step 'Environment'
$explorer = @(Get-Process explorer -ErrorAction SilentlyContinue)
$explorerElevated = if ($explorer.Count -gt 0) { [TestNative]::IsElevated($explorer[0].Id) } else { -1 }
Write-Host "explorer running: $($explorer.Count -gt 0), explorer elevated: $explorerElevated"
Write-Host "test process elevated: $([TestNative]::IsElevated($PID))"

Write-Step 'Install'
$r = Invoke-AppScript (Join-Path $script:RepoRoot 'Install.cmd')
Assert ($r.Code -eq 0) 'Install.cmd exits with 0'
Assert ($r.Output -match '\[dialog:Information\]') 'install reports completion'
Assert (Test-Path -LiteralPath $installed) 'script copied to %LOCALAPPDATA%\AutoShutdown'
$run = Get-RunValue
Write-Host "Run value: $run"
Assert ($run -like '"*\conhost.exe" --headless *') 'Run value starts conhost --headless'
Assert ($run -like "*-File `"$installed`"") 'Run value points at the installed script'
$links = @(Get-StartMenuLinks)
Assert ($links.Count -eq 1) "one Start menu shortcut created (found $($links.Count))"

$procs = Wait-InstalledAppProcesses 1
Assert ($procs.Count -eq 1) "one app instance is running after install (found $($procs.Count))"
if ($procs.Count -ge 1) {
    Write-ProcessTree $procs[0]
    $p = Get-Process -Id $procs[0].ProcessId
    Assert ($p.MainWindowHandle -eq [IntPtr]::Zero) 'app has no visible main window'
    $elevated = [TestNative]::IsElevated($procs[0].ProcessId)
    Write-Host "app elevated: $elevated"
    if ($explorerElevated -eq 0) {
        Assert ($elevated -eq 0) 'app installed from an elevated prompt runs non-elevated'
    }
    else {
        Write-Warn "explorer itself is elevated ($explorerElevated) on this runner, so the non-elevated launch cannot be checked"
    }
}

Write-Step 'Second launch is rejected'
$r = Invoke-AppScript $installed
Assert ($r.Code -eq 0) 'second launch exits with 0'
Assert ($r.Output -match '\[dialog:Information\]') 'second launch reports already running'
Assert ($r.Seconds -lt 20) 'second launch returns promptly'
Assert (@(Get-InstalledAppProcesses).Count -eq 1) 'still exactly one instance'

Write-Step 'Run value command starts the app'
foreach ($p in Get-InstalledAppProcesses) { Stop-Process -Id $p.ProcessId -Force; Wait-Process -Id $p.ProcessId -Timeout 5 -ErrorAction SilentlyContinue }
Start-CommandLine $run
$procs = Wait-InstalledAppProcesses 1
Assert ($procs.Count -eq 1) "the Run value command starts one instance (found $($procs.Count))"
if ($procs.Count -ge 1) { Write-ProcessTree $procs[0] }

Write-Step 'Reinstall replaces the running instance and re-enables autostart'
if (-not (Test-Path $script:ApprovedKey)) { New-Item -Path $script:ApprovedKey -Force | Out-Null }
New-ItemProperty -Path $script:ApprovedKey -Name 'AutoShutdown' -PropertyType Binary -Value ([byte[]](3,0,0,0,0,0,0,0,0,0,0,0)) -Force | Out-Null
$oldPid = if ($procs.Count -ge 1) { $procs[0].ProcessId } else { -1 }
$r = Invoke-AppScript $installed @('-Install')
Assert ($r.Code -eq 0) 'reinstall from the installed copy exits with 0'
$procs = Wait-InstalledAppProcesses 1
Assert ($procs.Count -eq 1) "one instance after reinstall (found $($procs.Count))"
if ($procs.Count -ge 1) { Assert ($procs[0].ProcessId -ne $oldPid) 'instance was restarted' }
Assert ($null -eq (Get-ItemProperty -Path $script:ApprovedKey -Name 'AutoShutdown' -ErrorAction SilentlyContinue)) 'reinstall clears a Task Manager disable record'
Assert ($null -ne (Get-RunValue)) 'Run value present after reinstall'

Write-Step 'Uninstall'
$r = Invoke-AppScript (Join-Path $script:RepoRoot 'Uninstall.cmd')
Assert ($r.Code -eq 0) 'Uninstall.cmd exits with 0'
Assert ((Wait-InstalledAppProcesses 0 10).Count -eq 0) 'no instance after uninstall'
Assert ($null -eq (Get-RunValue)) 'Run value removed'
Assert (@(Get-StartMenuLinks).Count -eq 0) 'Start menu shortcut removed'
Assert (-not (Test-Path -LiteralPath $installDir)) 'install directory removed'

Complete-Test
