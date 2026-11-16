. (Join-Path $PSScriptRoot 'common.ps1')

Write-Step 'Encoding'
$bytes = [System.IO.File]::ReadAllBytes($script:AppScript)
Assert ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) 'AutoShutdown.ps1 starts with a UTF-8 BOM'

Write-Step 'Parse'
$source = Get-AppSource
Assert ($source.Length -gt 1000) 'C# source extracted from the script'
Assert ($source.Contains([string][char]0x7184)) 'Chinese text survives decoding in PowerShell 5.1'

Write-Step 'Compile without -IgnoreWarnings (informational)'
$warnCheck = {
    param($src)
    try {
        Add-Type -TypeDefinition $src -ReferencedAssemblies System.Windows.Forms, System.Drawing -ErrorAction Stop
        'no warnings'
    }
    catch { 'warnings or errors: ' + $_.Exception.Message }
}
$result = & powershell.exe -NoProfile -Command $warnCheck -args $source
Write-Host $result

Write-Step 'Compile as the app does'
try {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    Add-Type -TypeDefinition $source -ReferencedAssemblies System.Windows.Forms, System.Drawing -IgnoreWarnings
    Assert $true 'Add-Type -IgnoreWarnings compiles the source'
}
catch {
    Write-Host $_.Exception.Message
    Assert $false 'Add-Type -IgnoreWarnings compiles the source'
}
Assert ($null -ne ('AutoShutdown.App' -as [type])) 'AutoShutdown.App type is loaded'
Assert ($null -ne ('AutoShutdown.DisplayStateWindow' -as [type])) 'AutoShutdown.DisplayStateWindow type is loaded'

Complete-Test
