. (Join-Path $PSScriptRoot 'common.ps1')

Import-AppTypes
$app = $null
$guid = 'SUB_VIDEO'
$setting = 'VIDEOIDLE'
try {
    $app = New-AppUnderTest -Minutes 60
    Write-Host "initial displayOff=$(Get-AppField $app 'displayOff')"

    Write-Step 'SC_MONITORPOWER broadcast'
    [void][TestNative]::PostMessage([IntPtr]0xFFFF, 0x0112, [IntPtr]0xF170, [IntPtr]2)
    $seen = $false
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        Invoke-Pump 0.5
        if (Get-AppField $app 'displayOff') { $seen = $true; break }
    }
    Write-Host "display-off notification after SC_MONITORPOWER: $seen"
    if (-not $seen) { Write-Warn 'SC_MONITORPOWER did not produce a display-off notification on this runner' }
    [void](Get-AppField $app 'displayOff')
    Write-Host ([TestNative]::MoveMouse())
    Invoke-Pump 3
    Write-Host "displayOff after input: $(Get-AppField $app 'displayOff')"

    Write-Step 'Display idle timeout of 1 minute'
    powercfg /setacvalueindex SCHEME_CURRENT $guid $setting 60
    powercfg /setdcvalueindex SCHEME_CURRENT $guid $setting 60
    powercfg /setactive SCHEME_CURRENT
    $seen = $false
    $deadline = (Get-Date).AddSeconds(100)
    while ((Get-Date) -lt $deadline) {
        Invoke-Pump 1
        if (Get-AppField $app 'displayOff') { $seen = $true; break }
    }
    Write-Host "display-off notification from idle timeout: $seen"
    if (-not $seen) { Write-Warn 'The display idle timeout did not produce a display-off notification on this runner' }
}
finally {
    if ($null -ne $app) { $app.ExitThread() }
    [void](Invoke-ShutdownAbort)
}
exit 0
