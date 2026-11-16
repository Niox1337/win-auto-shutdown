. (Join-Path $PSScriptRoot 'common.ps1')

Write-Host "Apartment: $([Threading.Thread]::CurrentThread.GetApartmentState())"
Import-AppTypes

$app = $null
try {
    Write-Step 'Startup'
    $app = New-AppUnderTest -Minutes 1
    Write-Host "minutes=$(Get-AppField $app 'minutes') displayOff=$(Get-AppField $app 'displayOff')"
    Assert ((Get-AppField $app 'minutes') -eq 1) 'config.txt is loaded'
    Assert (-not (Get-AppField $app 'sleepBlocked')) 'sleep is not blocked while the display is on'

    Write-Step 'Display off blocks idle sleep'
    Invoke-AppMethod $app 'OnDisplayState' @(0)
    Assert (Get-AppField $app 'displayOff') 'displayOff is set'
    Assert (Get-AppField $app 'sleepBlocked') 'sleepBlocked is set'
    $req = Get-SystemPowerRequests
    Write-Host "powercfg SYSTEM requests: $req"
    Assert ($req -match 'powershell\.exe') 'powercfg /requests lists powershell.exe under SYSTEM'

    Write-Step 'Display on releases the sleep block'
    Invoke-AppMethod $app 'OnDisplayState' @(1)
    Assert (-not (Get-AppField $app 'displayOff')) 'displayOff is cleared'
    Assert (-not (Get-AppField $app 'sleepBlocked')) 'sleepBlocked is cleared'
    Assert (-not ((Get-SystemPowerRequests) -match 'powershell\.exe')) 'powercfg /requests no longer lists powershell.exe'

    Write-Step 'Dimmed counts as on'
    Invoke-AppMethod $app 'OnDisplayState' @(2)
    Assert (-not (Get-AppField $app 'displayOff')) 'state 2 does not start counting'

    Write-Step 'Pause'
    Invoke-AppMethod $app 'SetPaused' @($true)
    Invoke-AppMethod $app 'OnDisplayState' @(0)
    Assert (-not (Get-AppField $app 'sleepBlocked')) 'paused app does not block sleep'
    Set-AppField $app 'displayOffSinceTick' (Get-TickAgo 120000)
    Invoke-Pump 2
    Assert (-not (Get-AppField $app 'shutdownPending')) 'paused app does not start a shutdown'
    Invoke-AppMethod $app 'SetPaused' @($false)
    Assert (Get-AppField $app 'sleepBlocked') 'resuming while display is off blocks sleep again'
    Invoke-Pump 2
    Assert (-not (Get-AppField $app 'shutdownPending')) 'resuming restarts the countdown instead of firing at once'
    Invoke-AppMethod $app 'OnDisplayState' @(1)

    Write-Step 'Suspend stops counting'
    Invoke-AppMethod $app 'OnDisplayState' @(0)
    Invoke-AppMethod $app 'OnSuspending'
    Assert (-not (Get-AppField $app 'displayOff')) 'suspend clears displayOff'
    Assert (-not (Get-AppField $app 'sleepBlocked')) 'suspend releases the sleep block'
    Set-AppField $app 'displayOffSinceTick' (Get-TickAgo 120000)
    Invoke-Pump 2
    Assert (-not (Get-AppField $app 'shutdownPending')) 'no shutdown after suspend even with an old start tick'

    Write-Step 'shutdown.exe failure is detected and does not abort a foreign shutdown'
    Start-Process -FilePath "$env:SystemRoot\System32\shutdown.exe" -ArgumentList '/s /t 600 /c ci-guard' -WindowStyle Hidden -Wait
    Invoke-AppMethod $app 'OnDisplayState' @(0)
    Set-AppField $app 'displayOffSinceTick' (Get-TickAgo 61000)
    Invoke-Pump 3
    Assert (-not (Get-AppField $app 'shutdownPending')) 'app does not consider itself pending when shutdown.exe fails'
    Invoke-AppMethod $app 'OnDisplayState' @(1)
    Invoke-Pump 1
    $code = Invoke-ShutdownAbort
    Assert ($code -eq 0) "the foreign shutdown is still pending afterwards (abort exit code $code)"

    Write-Step 'Real timing: 1 minute of display off starts the shutdown'
    $t0 = Get-Date
    Invoke-AppMethod $app 'OnDisplayState' @(0)
    Invoke-Pump 50
    Assert (-not (Get-AppField $app 'shutdownPending')) 'no shutdown after 50 seconds'
    $deadline = (Get-Date).AddSeconds(20)
    while (-not (Get-AppField $app 'shutdownPending') -and (Get-Date) -lt $deadline) { Invoke-Pump 0.5 }
    $elapsed = ((Get-Date) - $t0).TotalSeconds
    Assert (Get-AppField $app 'shutdownPending') ("shutdown started after {0:N1} seconds" -f $elapsed)
    # A second request fails with 1190 only when a shutdown is already scheduled.
    $probe = Start-Process -FilePath "$env:SystemRoot\System32\shutdown.exe" -ArgumentList '/s /t 600 /c ci-probe' -WindowStyle Hidden -Wait -PassThru
    Assert ($probe.ExitCode -eq 1190) "Windows reports a shutdown already scheduled (probe exit code $($probe.ExitCode))"
    Assert (Get-AppField $app 'sleepBlocked') 'sleep stays blocked during the countdown'

    Write-Step 'Display turning on without input does not cancel'
    Invoke-AppMethod $app 'OnDisplayState' @(1)
    Invoke-Pump 3
    Assert (Get-AppField $app 'shutdownPending') 'countdown continues when the display turns on by itself'

    Write-Step 'User input cancels'
    $before = [TestNative]::LastInputTick()
    Write-Host ([TestNative]::MoveMouse())
    Invoke-Pump 3
    $after = [TestNative]::LastInputTick()
    Write-Host "last input tick before=$before after=$after"
    if ($after -ne $before) {
        Assert (-not (Get-AppField $app 'shutdownPending')) 'mouse input cancels the countdown'
    }
    else {
        Write-Warn 'SendInput did not change GetLastInputInfo on this runner, so input cancellation could not be exercised'
        Invoke-AppMethod $app 'CancelPendingShutdown' @([string]$null)
    }
    $code = Invoke-ShutdownAbort
    Assert ($code -eq 1116) "no shutdown is pending after cancellation (abort exit code $code)"

    Write-Step 'Autostart toggle'
    $isEnabled = { [AutoShutdown.App].GetMethod('IsAutostartEnabled', [System.Reflection.BindingFlags]'NonPublic,Static').Invoke($null, @()) }
    $menuChecked = { [void](Invoke-AppMethod $app 'SyncState'); (Get-AppField $app 'autostartItem').Checked }
    Remove-ItemProperty -Path $script:RunKey -Name 'AutoShutdown' -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $script:ApprovedKey -Name 'AutoShutdown' -ErrorAction SilentlyContinue
    Assert (-not (& $isEnabled)) 'autostart reads as off without a Run value'
    Assert (-not (& $menuChecked)) 'menu item unchecked without a Run value'
    Invoke-AppMethod $app 'SetAutostart' @($true)
    $run = Get-RunValue
    Write-Host "Run value: $run"
    Assert ($run -like "*-File `"$($script:AppScript)`"") 'turning autostart on writes a Run value for the script'
    Assert (& $isEnabled) 'autostart reads as on'
    Assert (& $menuChecked) 'menu item checked'
    if (-not (Test-Path $script:ApprovedKey)) { New-Item -Path $script:ApprovedKey -Force | Out-Null }
    New-ItemProperty -Path $script:ApprovedKey -Name 'AutoShutdown' -PropertyType Binary -Value ([byte[]](3,0,0,0,0,0,0,0,0,0,0,0)) -Force | Out-Null
    Assert (-not (& $isEnabled)) 'a Task Manager disable record reads as off'
    Assert (-not (& $menuChecked)) 'menu item unchecked when Task Manager disabled it'
    Invoke-AppMethod $app 'SetAutostart' @($true)
    Assert ($null -eq (Get-ItemProperty -Path $script:ApprovedKey -Name 'AutoShutdown' -ErrorAction SilentlyContinue)) 'turning autostart on clears the disable record'
    Assert (& $isEnabled) 'autostart reads as on again'
    Invoke-AppMethod $app 'SetAutostart' @($false)
    Assert ($null -eq (Get-RunValue)) 'turning autostart off removes the Run value'
    Assert (-not (& $menuChecked)) 'menu item unchecked after turning off'

    Write-Step 'Exit cleanup'
    Invoke-AppMethod $app 'OnDisplayState' @(0)
    Assert (Get-AppField $app 'sleepBlocked') 'sleep blocked before exit'
    $app.ExitThread()
    $app = $null
    Assert (-not ((Get-SystemPowerRequests) -match 'powershell\.exe')) 'exit releases the sleep block'
}
finally {
    if ($null -ne $app) { $app.ExitThread() }
    [void](Invoke-ShutdownAbort)
    Remove-ItemProperty -Path $script:RunKey -Name 'AutoShutdown' -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $script:ApprovedKey -Name 'AutoShutdown' -ErrorAction SilentlyContinue
}

Complete-Test
