. (Join-Path $PSScriptRoot 'common.ps1')

# Extracts the release zip through the Explorer zip folder, with the downloaded-file mark applied first.
$zip = Get-ChildItem -Path (Join-Path $script:RepoRoot 'pkg') -Filter '*.zip' -Recurse | Select-Object -First 1
Assert ($null -ne $zip) 'release zip downloaded'
Write-Host "zip: $($zip.FullName)"
Set-Content -LiteralPath $zip.FullName -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3"

$dest = Join-Path $env:RUNNER_TEMP 'extracted'
New-Item -ItemType Directory -Path $dest -Force | Out-Null
$shell = New-Object -ComObject Shell.Application
$shell.NameSpace($dest).CopyHere($shell.NameSpace($zip.FullName).Items(), 0x14)

$folder = Get-ChildItem -LiteralPath $dest -Directory | Select-Object -First 1
$deadline = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $deadline -and ($null -eq $folder -or @(Get-ChildItem -LiteralPath $folder.FullName).Count -lt 4)) {
    Start-Sleep -Milliseconds 500
    $folder = Get-ChildItem -LiteralPath $dest -Directory | Select-Object -First 1
}
Assert ($null -ne $folder) 'zip contains a folder'
if ($null -ne $folder) {
    Write-Host "folder: $($folder.Name)"
    Get-ChildItem -LiteralPath $folder.FullName | ForEach-Object { Write-Host "  $($_.Name)" }
    $env:APP_DIR = $folder.FullName
    . (Join-Path $PSScriptRoot 'common.ps1')
    Assert (Test-Path -LiteralPath $script:AppScript) 'app script extracted with its Chinese name'
    Assert (Test-Path -LiteralPath $script:InstallCmd) 'install command extracted with its Chinese name'
    Assert (Test-Path -LiteralPath $script:UninstallCmd) 'uninstall command extracted with its Chinese name'
    $mark = Get-Content -LiteralPath $script:AppScript -Stream Zone.Identifier -ErrorAction SilentlyContinue
    Write-Host "downloaded-file mark on extracted script: $([bool]$mark)"
    Add-Content -Path $env:GITHUB_ENV -Value "APP_DIR=$($folder.FullName)" -Encoding UTF8
}

Complete-Test
