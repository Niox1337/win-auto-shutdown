. (Join-Path $PSScriptRoot 'common.ps1')

$env:AUTOSHUTDOWN_NO_DIALOG = '1'
$installDir = Join-Path $env:LOCALAPPDATA 'AutoShutdown'
$installed  = Join-Path $installDir 'AutoShutdown.ps1'
$link       = Join-Path ([Environment]::GetFolderPath('Startup')) 'AutoShutdown.lnk'
$psExe      = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

function Get-AppProcesses {
    return @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
        Where-Object { $_.CommandLine -like '*AutoShutdown.ps1*' -and $_.CommandLine -notlike '*-Install*' -and $_.CommandLine -notlike '*-Uninstall*' })
}

function Wait-AppProcesses([int]$Count, [int]$TimeoutSeconds = 30) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $procs = Get-AppProcesses
        if ($procs.Count -eq $Count) { return $procs }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    return $procs
}

function Invoke-AppScript([string]$Path, [string[]]$Arguments = @()) {
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

Write-Step 'Environment'
Write-Host "explorer running: $(@(Get-Process explorer -ErrorAction SilentlyContinue).Count -gt 0)"
Write-Host "elevated: $(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))"

Write-Step 'Install'
$r = Invoke-AppScript (Join-Path $script:RepoRoot 'Install.cmd')
Assert ($r.Code -eq 0) 'Install.cmd exits with 0'
Assert ($r.Output -match '\[dialog:Information\]') 'install reports completion'
Assert (Test-Path -LiteralPath $installed) 'script copied to %LOCALAPPDATA%\AutoShutdown'
Assert (Test-Path -LiteralPath $link) 'startup shortcut created'
if (Test-Path -LiteralPath $link) {
    $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($link)
    Write-Host "shortcut: $($lnk.TargetPath) $($lnk.Arguments)"
    Assert ($lnk.TargetPath -like '*\conhost.exe') 'shortcut targets conhost.exe'
    Assert ($lnk.Arguments -like '--headless *') 'shortcut uses --headless'
}
$procs = Wait-AppProcesses 1
Assert ($procs.Count -eq 1) "one app instance is running after install (found $($procs.Count))"
if ($procs.Count -ge 1) {
    Write-ProcessTree $procs[0]
    $p = Get-Process -Id $procs[0].ProcessId
    Assert ($p.MainWindowHandle -eq [IntPtr]::Zero) 'app has no visible main window'
}

if ($procs.Count -eq 0) {
    Write-Step 'Fallback: start the shortcut directly to keep testing'
    Start-Process -FilePath $link
    $procs = Wait-AppProcesses 1
    Assert ($procs.Count -eq 1) "shortcut starts the app directly (found $($procs.Count))"
    if ($procs.Count -ge 1) { Write-ProcessTree $procs[0] }
}

Write-Step 'Second launch is rejected'
$r = Invoke-AppScript $installed
Assert ($r.Code -eq 0) 'second launch exits with 0'
Assert ($r.Output -match '\[dialog:Information\]') 'second launch reports already running'
Assert ($r.Seconds -lt 20) 'second launch returns promptly'
Assert ((Get-AppProcesses).Count -eq 1) 'still exactly one instance'

Write-Step 'Reinstall replaces the running instance'
$oldPid = if ($procs.Count -ge 1) { $procs[0].ProcessId } else { -1 }
$r = Invoke-AppScript $installed @('-Install')
Assert ($r.Code -eq 0) 'reinstall from the installed copy exits with 0'
$procs = Wait-AppProcesses 1
Assert ($procs.Count -eq 1) "one instance after reinstall (found $($procs.Count))"
if ($procs.Count -ge 1) { Assert ($procs[0].ProcessId -ne $oldPid) 'instance was restarted' }

Write-Step 'Uninstall'
$r = Invoke-AppScript (Join-Path $script:RepoRoot 'Uninstall.cmd')
Assert ($r.Code -eq 0) 'Uninstall.cmd exits with 0'
Assert ((Wait-AppProcesses 0 10).Count -eq 0) 'no instance after uninstall'
Assert (-not (Test-Path -LiteralPath $link)) 'startup shortcut removed'
Assert (-not (Test-Path -LiteralPath $installDir)) 'install directory removed'

Complete-Test
