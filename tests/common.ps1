$ErrorActionPreference = 'Stop'

$script:RepoRoot     = Split-Path $PSScriptRoot -Parent
# APP_DIR points at an extracted release folder. Without it the repository checkout is used.
$script:AppDir       = if ($env:APP_DIR) { $env:APP_DIR } else { $script:RepoRoot }
$script:AppScript    = Join-Path $script:AppDir 'AutoShutdown.ps1'
$script:InstallCmd   = Join-Path $script:AppDir 'Install.cmd'
$script:UninstallCmd = Join-Path $script:AppDir 'Uninstall.cmd'
$script:Failures  = New-Object System.Collections.Generic.List[string]

function Write-Step([string]$Text) { Write-Host "`n=== $Text ===" }

function Assert([bool]$Condition, [string]$Text) {
    if ($Condition) { Write-Host "PASS  $Text" }
    else { Write-Host "FAIL  $Text"; $script:Failures.Add($Text) }
}

function Write-Warn([string]$Text) { Write-Host "::warning::$Text" }

function Complete-Test {
    if ($script:Failures.Count -gt 0) {
        Write-Host "`n$($script:Failures.Count) check(s) failed:"
        $script:Failures | ForEach-Object { Write-Host "  - $_" }
        exit 1
    }
    Write-Host "`nAll checks passed."
    exit 0
}

# Returns the C# here-string assigned to $source in AutoShutdown.ps1.
function Get-AppSource {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:AppScript, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw ('Parse errors: ' + ($errors | Out-String)) }
    $assign = $ast.Find({
        param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$source'
    }, $true)
    $str = $assign.Right.Find({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)
    return $str.Value
}

function Import-AppTypes {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    Add-Type -TypeDefinition (Get-AppSource) -ReferencedAssemblies System.Windows.Forms, System.Drawing -IgnoreWarnings
    Import-TestNative
}

function Import-TestNative {
    if ($null -ne ('TestNative' -as [type])) { return }
    Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class TestNative
{
    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }

    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public MOUSEINPUT mi; }

    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }

    [DllImport("user32.dll", SetLastError = true)]
    static extern uint SendInput(uint count, INPUT[] inputs, int size);

    [DllImport("user32.dll")]
    static extern bool GetLastInputInfo(ref LASTINPUTINFO info);

    [DllImport("user32.dll")]
    public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    public static string MoveMouse()
    {
        INPUT[] inputs = new INPUT[1];
        inputs[0].type = 0;
        inputs[0].mi.dx = 7;
        inputs[0].mi.dy = 7;
        inputs[0].mi.dwFlags = 1;
        uint sent = SendInput(1, inputs, Marshal.SizeOf(typeof(INPUT)));
        return "sent=" + sent + " lastError=" + Marshal.GetLastWin32Error();
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr OpenProcess(uint access, bool inherit, int pid);

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool GetTokenInformation(IntPtr token, int infoClass, out int info, int length, out int returned);

    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr handle);

    // Returns 1 when the process token is elevated, 0 when not, -1 when it cannot be read.
    public static int IsElevated(int pid)
    {
        IntPtr process = OpenProcess(0x1000, false, pid);
        if (process == IntPtr.Zero) return -1;
        IntPtr token;
        if (!OpenProcessToken(process, 0x0008, out token)) { CloseHandle(process); return -1; }
        int elevated;
        int returned;
        bool ok = GetTokenInformation(token, 20, out elevated, 4, out returned);
        CloseHandle(token);
        CloseHandle(process);
        if (!ok) return -1;
        return elevated != 0 ? 1 : 0;
    }

    public static uint LastInputTick()
    {
        LASTINPUTINFO info = new LASTINPUTINFO();
        info.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        GetLastInputInfo(ref info);
        return info.dwTime;
    }
}
'@
}

$script:Flags = [System.Reflection.BindingFlags]'NonPublic,Instance'

function Get-AppField($App, [string]$Name) {
    return [AutoShutdown.App].GetField($Name, $script:Flags).GetValue($App)
}

function Set-AppField($App, [string]$Name, $Value) {
    [AutoShutdown.App].GetField($Name, $script:Flags).SetValue($App, $Value)
}

function Invoke-AppMethod($App, [string]$Name, [object[]]$Arguments = @()) {
    return [AutoShutdown.App].GetMethod($Name, $script:Flags).Invoke($App, $Arguments)
}

# Runs the WinForms message loop on the current thread for the given duration.
function Invoke-Pump([double]$Seconds) {
    $end = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $end) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 50
    }
}

function Get-TickNow {
    return [uint32]([int64][Environment]::TickCount -band 0xFFFFFFFFL)
}

function Get-TickAgo([int64]$Milliseconds) {
    return [uint32](([int64](Get-TickNow) - $Milliseconds + 4294967296L) % 4294967296L)
}

# Returns the process lines listed under SYSTEM: in powercfg /requests.
function Get-SystemPowerRequests {
    $text = (powercfg /requests | Out-String)
    $m = [regex]::Match($text, '(?s)SYSTEM:\s*(.*?)\r?\n\s*AWAYMODE:')
    return $m.Groups[1].Value.Trim()
}

# Runs shutdown.exe /a and returns its exit code. 0 means a pending shutdown was aborted, 1116 means none was pending.
function Invoke-ShutdownAbort {
    $p = Start-Process -FilePath "$env:SystemRoot\System32\shutdown.exe" -ArgumentList '/a' -WindowStyle Hidden -Wait -PassThru
    return $p.ExitCode
}

function New-AppUnderTest([int]$Minutes) {
    $dir = Join-Path $env:TEMP ('autoshutdown-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $config = Join-Path $dir 'config.txt'
    Set-Content -LiteralPath $config -Value "$Minutes"
    $app = New-Object AutoShutdown.App($config, $script:AppScript)
    Invoke-Pump 2
    return $app
}

$script:RunKey      = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$script:ApprovedKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'

function Get-RunValue {
    return (Get-ItemProperty -Path $script:RunKey -Name 'AutoShutdown' -ErrorAction SilentlyContinue).AutoShutdown
}

# Starts a Run-key style command line by splitting the quoted executable from its arguments.
function Start-CommandLine([string]$CommandLine) {
    $m = [regex]::Match($CommandLine, '^"([^"]+)"\s+(.*)$')
    if (-not $m.Success) { throw "Unexpected command line: $CommandLine" }
    Start-Process -FilePath $m.Groups[1].Value -ArgumentList $m.Groups[2].Value
}

# Schedules a probe shutdown. Exit code 1190 means one was already scheduled. Exit code 0 means none was, and the probe is aborted again.
function Test-ShutdownScheduled {
    $p = Start-Process -FilePath "$env:SystemRoot\System32\shutdown.exe" -ArgumentList '/s /t 600 /c ci-probe' -WindowStyle Hidden -Wait -PassThru
    if ($p.ExitCode -eq 0) { [void](Invoke-ShutdownAbort) }
    return $p.ExitCode
}

function Get-InstalledAppProcesses {
    return @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
        Where-Object { $_.CommandLine -like '*AutoShutdown.ps1*' -and $_.CommandLine -notlike '*-Install*' -and $_.CommandLine -notlike '*-Uninstall*' })
}

function Wait-InstalledAppProcesses([int]$Count, [int]$TimeoutSeconds = 30) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $procs = @(Get-InstalledAppProcesses)
        if ($procs.Count -eq $Count) { return ,$procs }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    return ,$procs
}
