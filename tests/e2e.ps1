. (Join-Path $PSScriptRoot 'common.ps1')
Import-TestNative

# Installed app, real display-off notification, real shutdown.exe, real user input. Nothing is driven through reflection.
$env:AUTOSHUTDOWN_NO_DIALOG = '1'
$installDir = Join-Path $env:LOCALAPPDATA 'AutoShutdown'

function Invoke-Cmd([string]$Path) {
    $ErrorActionPreference = 'Continue'
    $out = & cmd.exe /c "`"$Path`" < nul" 2>&1 | Out-String
    Write-Host "$(Split-Path $Path -Leaf) exit=$LASTEXITCODE"
    return $LASTEXITCODE
}

try {
    Write-Step 'Install and restart with a 1 minute delay'
    Assert ((Invoke-Cmd $script:InstallCmd) -eq 0) 'install command exits with 0'
    Set-Content -LiteralPath (Join-Path $installDir 'config.txt') -Value '1'
    foreach ($p in Get-InstalledAppProcesses) { Stop-Process -Id $p.ProcessId -Force; Wait-Process -Id $p.ProcessId -Timeout 5 -ErrorAction SilentlyContinue }
    Start-CommandLine (Get-RunValue)
    $procs = Wait-InstalledAppProcesses 1
    Assert ($procs.Count -eq 1) "installed app running (found $($procs.Count))"
    Start-Sleep -Seconds 8
    Assert (@(Get-InstalledAppProcesses).Count -eq 1) 'installed app still running after startup'
    Assert (-not ((Get-SystemPowerRequests) -match 'powershell\.exe')) 'no sleep block while the display is on'

    Write-Step 'Turn the display off'
    $t0 = Get-Date
    [void][TestNative]::PostMessage([IntPtr]0xFFFF, 0x0112, [IntPtr]0xF170, [IntPtr]2)
    Start-Sleep -Seconds 5
    $req = Get-SystemPowerRequests
    Write-Host "powercfg SYSTEM requests: $req"
    Assert ($req -match 'powershell\.exe') 'installed app blocks idle sleep after the display turns off'

    Write-Step 'Wait without input'
    while (((Get-Date) - $t0).TotalSeconds -lt 50) { Start-Sleep -Seconds 1 }
    Write-Host "50 s check: lastInput=$([TestNative]::LastInputTick())"
    while (((Get-Date) - $t0).TotalSeconds -lt 72) { Start-Sleep -Seconds 1 }
    $code = Test-ShutdownScheduled
    Assert ($code -eq 1190) "Windows has a shutdown scheduled 72 s after display off (probe exit code $code)"

    Write-Step 'Move the mouse'
    Write-Host ([TestNative]::MoveMouse())
    Start-Sleep -Seconds 5
    $code = Test-ShutdownScheduled
    Assert ($code -eq 0) "mouse input cancelled the scheduled shutdown (probe exit code $code)"
    Assert (@(Get-InstalledAppProcesses).Count -eq 1) 'installed app keeps running after cancelling'
}
finally {
    [void](Invoke-ShutdownAbort)
    [void](Invoke-Cmd $script:UninstallCmd)
}

Complete-Test
