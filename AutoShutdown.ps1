param(
    [switch]$Install,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$AppTitle        = '熄屏自动关机'
$InstallDir      = Join-Path $env:LOCALAPPDATA 'AutoShutdown'
$InstalledScript = Join-Path $InstallDir 'AutoShutdown.ps1'
$StartMenuLink   = Join-Path ([Environment]::GetFolderPath('Programs')) "$AppTitle.lnk"
$LegacyLink      = Join-Path ([Environment]::GetFolderPath('Startup')) 'AutoShutdown.lnk'
$RunKey          = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$ApprovedKey     = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
$RunValueName    = 'AutoShutdown'
$PsExe           = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$Conhost         = Join-Path $env:SystemRoot 'System32\conhost.exe'
$TrayHint        = '图标在任务栏右下角，时钟旁边。如果没看到，点一下时钟左边的 "^" 箭头（显示隐藏的图标）。'

# AUTOSHUTDOWN_NO_DIALOG=1 prints messages to the console instead of showing dialogs, for unattended runs.
function Show-Message([string]$Text, [string]$Icon = 'Information') {
    if ($env:AUTOSHUTDOWN_NO_DIALOG -eq '1') { Write-Host "[dialog:$Icon] $Text"; return }
    [void][System.Windows.Forms.MessageBox]::Show($Text, $AppTitle, 'OK', $Icon)
}

# Terminates running instances of this script other than the current process and returns how many were stopped.
function Stop-OtherInstances {
    $procs = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*AutoShutdown.ps1*' })
    foreach ($p in $procs) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        Wait-Process -Id $p.ProcessId -Timeout 5 -ErrorAction SilentlyContinue
    }
    return $procs.Count
}

function Undo-PendingShutdown {
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\shutdown.exe') -ArgumentList '/a' -WindowStyle Hidden -Wait
}

function Test-Elevated {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Removes the autostart entry and any Task Manager enable/disable record for it.
function Remove-Autostart {
    Remove-ItemProperty -Path $RunKey -Name $RunValueName -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $ApprovedKey -Name $RunValueName -ErrorAction SilentlyContinue
}

function Install-App {
    if ((Stop-OtherInstances) -gt 0) { Undo-PendingShutdown }

    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    if ($PSCommandPath -ne $InstalledScript) {
        Copy-Item -LiteralPath $PSCommandPath -Destination $InstalledScript -Force
    }
    Unblock-File -LiteralPath $InstalledScript
    Remove-Item -LiteralPath $LegacyLink -Force -ErrorAction SilentlyContinue

    # conhost --headless runs powershell without any visible console window.
    $arguments = "--headless `"$PsExe`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$InstalledScript`""

    Remove-Autostart
    if (-not (Test-Path $RunKey)) { New-Item -Path $RunKey -Force | Out-Null }
    New-ItemProperty -Path $RunKey -Name $RunValueName -Value "`"$Conhost`" $arguments" -PropertyType String -Force | Out-Null

    # IShellLinkW keeps non-ASCII shortcut names and paths intact regardless of the system code page.
    Add-Type -TypeDefinition $source -ReferencedAssemblies System.Windows.Forms, System.Drawing -IgnoreWarnings
    [AutoShutdown.ShellLink]::Save($StartMenuLink, $Conhost, $arguments, $env:USERPROFILE, $AppTitle)

    # explorer.exe hands the launch to the existing shell, so the instance runs non-elevated even from an elevated installer.
    if (Test-Elevated) {
        Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList "`"$StartMenuLink`""
    }
    else {
        Start-Process -FilePath $StartMenuLink
    }

    Show-Message ("安装完成，已经在后台运行，默认开机自动启动。`n`n" +
        "$TrayHint 右键绿色电源图标可以调整等待时间、暂停、开关开机自动启动、退出或卸载。`n`n" +
        "退出后想再打开，在开始菜单里找 `"$AppTitle`"。`n`n" +
        "默认：屏幕关闭 30 分钟后关机。关机前有 60 秒倒计时，期间动一下鼠标或键盘即可取消。`n`n" +
        "注意：关机会强制关闭所有程序，没保存的内容会丢失。")
}

function Uninstall-App {
    if ((Stop-OtherInstances) -gt 0) { Undo-PendingShutdown }
    Remove-Autostart
    Remove-Item -LiteralPath $StartMenuLink -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $LegacyLink -Force -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt 5 -and (Test-Path -LiteralPath $InstallDir); $i++) {
        Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $InstallDir) { Start-Sleep -Milliseconds 500 }
    }
    Show-Message '已卸载，开机不会再自动启动。'
}

$source = @'
using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;
using System.Windows.Forms;
using Microsoft.Win32;

namespace AutoShutdown
{
    public static class ShellLink
    {
        [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
        class CShellLink { }

        [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("000214F9-0000-0000-C000-000000000046")]
        interface IShellLinkW
        {
            void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder file, int maxPath, IntPtr findData, int flags);
            void GetIDList(out IntPtr idList);
            void SetIDList(IntPtr idList);
            void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder name, int maxName);
            void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string name);
            void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder dir, int maxPath);
            void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string dir);
            void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder args, int maxPath);
            void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string args);
            void GetHotkey(out short hotkey);
            void SetHotkey(short hotkey);
            void GetShowCmd(out int showCmd);
            void SetShowCmd(int showCmd);
            void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder iconPath, int maxIconPath, out int icon);
            void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string iconPath, int icon);
            void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string relativePath, int reserved);
            void Resolve(IntPtr hwnd, int flags);
            void SetPath([MarshalAs(UnmanagedType.LPWStr)] string file);
        }

        const int SW_SHOWMINNOACTIVE = 7;

        public static void Save(string linkPath, string target, string arguments, string workingDirectory, string description)
        {
            IShellLinkW link = (IShellLinkW)new CShellLink();
            try
            {
                link.SetPath(target);
                link.SetArguments(arguments);
                link.SetWorkingDirectory(workingDirectory);
                link.SetDescription(description);
                link.SetShowCmd(SW_SHOWMINNOACTIVE);
                ((IPersistFile)link).Save(linkPath, true);
            }
            finally
            {
                Marshal.ReleaseComObject(link);
            }
        }
    }

    // Hidden top-level window that receives GUID_CONSOLE_DISPLAY_STATE notifications and suspend broadcasts.
    // Display state values: 0 = off, 1 = on, 2 = dimmed.
    public class DisplayStateWindow : NativeWindow, IDisposable
    {
        const int WM_POWERBROADCAST = 0x0218;
        const int PBT_APMSUSPEND = 0x0004;
        const int PBT_POWERSETTINGCHANGE = 0x8013;
        static readonly Guid DisplayStateGuid = new Guid("6FE69556-704A-47A0-8F24-C28D936FDA47");

        [DllImport("user32.dll", SetLastError = true)]
        static extern IntPtr RegisterPowerSettingNotification(IntPtr hRecipient, ref Guid powerSettingGuid, int flags);

        [DllImport("user32.dll", SetLastError = true)]
        static extern bool UnregisterPowerSettingNotification(IntPtr handle);

        IntPtr registration = IntPtr.Zero;

        public event Action<int> StateChanged;
        public event Action Suspending;

        public DisplayStateWindow()
        {
            CreateHandle(new CreateParams());
        }

        // Registration delivers the current state immediately, so it runs after event handlers are attached.
        public void Start()
        {
            Guid guid = DisplayStateGuid;
            registration = RegisterPowerSettingNotification(Handle, ref guid, 0);
            if (registration == IntPtr.Zero)
                throw new InvalidOperationException("无法接收屏幕开关通知（错误码 " + Marshal.GetLastWin32Error() + "）。");
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WM_POWERBROADCAST)
            {
                long evt = m.WParam.ToInt64();
                if (evt == PBT_POWERSETTINGCHANGE && m.LParam != IntPtr.Zero)
                {
                    Guid setting = (Guid)Marshal.PtrToStructure(m.LParam, typeof(Guid));
                    if (setting == DisplayStateGuid)
                    {
                        // POWERBROADCAST_SETTING layout: Guid (16 bytes), DataLength (4 bytes), Data.
                        int state = Marshal.ReadInt32(m.LParam, 20);
                        Action<int> handler = StateChanged;
                        if (handler != null) handler(state);
                    }
                }
                else if (evt == PBT_APMSUSPEND)
                {
                    Action handler = Suspending;
                    if (handler != null) handler();
                }
                m.Result = new IntPtr(1);
                return;
            }
            base.WndProc(ref m);
        }

        public void Dispose()
        {
            if (registration != IntPtr.Zero)
            {
                UnregisterPowerSettingNotification(registration);
                registration = IntPtr.Zero;
            }
            DestroyHandle();
        }
    }

    public class App : ApplicationContext
    {
        static readonly int[] Presets = { 2, 15, 30, 60, 120 };
        const int GraceSeconds = 60;
        const int MaxMinutes = 7 * 24 * 60;
        const uint ES_CONTINUOUS = 0x80000000;
        const uint ES_SYSTEM_REQUIRED = 0x00000001;
        const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
        const string ApprovedKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";
        const string RunValueName = "AutoShutdown";

        [StructLayout(LayoutKind.Sequential)]
        public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }

        [DllImport("user32.dll")]
        static extern bool GetLastInputInfo(ref LASTINPUTINFO info);

        [DllImport("kernel32.dll")]
        static extern uint SetThreadExecutionState(uint flags);

        readonly string configPath;
        readonly string scriptPath;
        readonly NotifyIcon tray;
        readonly DisplayStateWindow display;
        readonly Timer timer;
        readonly ToolStripMenuItem statusItem;
        readonly ToolStripMenuItem pauseItem;
        readonly ToolStripMenuItem autostartItem;
        readonly ToolStripMenuItem delayMenu;
        readonly Icon activeIcon;
        readonly Icon pausedIcon;

        int minutes = 30;
        bool paused;
        bool displayOff;
        uint displayOffSinceTick;
        bool shutdownPending;
        uint shutdownStartTick;
        bool sleepBlocked;

        public static void Run(string configPath, string scriptPath)
        {
            Application.EnableVisualStyles();
            Application.Run(new App(configPath, scriptPath));
        }

        public App(string configPath, string scriptPath)
        {
            this.configPath = configPath;
            this.scriptPath = scriptPath;
            LoadConfig();

            activeIcon = MakeIcon(Color.FromArgb(46, 160, 67));
            pausedIcon = MakeIcon(Color.FromArgb(140, 140, 140));

            statusItem = new ToolStripMenuItem();
            statusItem.Enabled = false;

            delayMenu = new ToolStripMenuItem("熄屏后等待多久关机");
            foreach (int preset in Presets)
            {
                int value = preset;
                ToolStripMenuItem item = new ToolStripMenuItem(FormatMinutes(value));
                item.Tag = value;
                item.Click += delegate { SetMinutes(value); };
                delayMenu.DropDownItems.Add(item);
            }

            pauseItem = new ToolStripMenuItem("暂停");
            pauseItem.Click += delegate { SetPaused(!paused); };

            autostartItem = new ToolStripMenuItem("开机自动启动");
            autostartItem.Click += delegate { SetAutostart(!IsAutostartEnabled()); };

            ToolStripMenuItem exitItem = new ToolStripMenuItem("退出");
            exitItem.Click += delegate { ExitThread(); };

            ToolStripMenuItem uninstallItem = new ToolStripMenuItem("卸载");
            uninstallItem.Click += delegate { Uninstall(); };

            ContextMenuStrip menu = new ContextMenuStrip();
            menu.Items.Add(statusItem);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(delayMenu);
            menu.Items.Add(pauseItem);
            menu.Items.Add(autostartItem);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(exitItem);
            menu.Items.Add(uninstallItem);
            menu.Opening += delegate { SyncState(); };

            tray = new NotifyIcon();
            tray.ContextMenuStrip = menu;
            tray.Icon = activeIcon;

            timer = new Timer();
            timer.Interval = 1000;
            timer.Tick += delegate { Check(); };

            display = new DisplayStateWindow();
            display.StateChanged += OnDisplayState;
            display.Suspending += OnSuspending;
            display.Start();

            tray.Visible = true;
            timer.Start();
            SyncState();
        }

        static uint Now()
        {
            return unchecked((uint)Environment.TickCount);
        }

        void OnDisplayState(int state)
        {
            bool off = state == 0;
            if (off && !displayOff)
            {
                displayOff = true;
                displayOffSinceTick = Now();
            }
            else if (!off)
            {
                displayOff = false;
            }
            Check();
            SyncState();
        }

        // Counting stops across sleep. The display-on notification after resume can arrive later than the first timer tick.
        void OnSuspending()
        {
            displayOff = false;
            CancelPendingShutdown(null);
            SyncState();
        }

        void Check()
        {
            if (shutdownPending)
            {
                // Only real user input cancels, since the shutdown notice itself may turn the display on.
                if (InputSince(shutdownStartTick))
                    CancelPendingShutdown("检测到操作，已取消关机。");
                return;
            }
            if (paused || !displayOff) return;
            uint elapsed = unchecked(Now() - displayOffSinceTick);
            if (elapsed >= (uint)minutes * 60000u)
                StartShutdown();
        }

        void StartShutdown()
        {
            uint start = Now();
            string comment = "屏幕已关闭 " + FormatMinutes(minutes) + "，电脑将在 " + GraceSeconds +
                             " 秒后关机。动一下鼠标或键盘即可取消。";
            int code = RunShutdownExe("/s /t " + GraceSeconds + " /c \"" + comment + "\"");
            if (code != 0)
            {
                displayOffSinceTick = Now();
                tray.ShowBalloonTip(4000, "熄屏自动关机", "无法发起关机（错误码 " + code + "）。", ToolTipIcon.Warning);
                SyncState();
                return;
            }
            shutdownStartTick = start;
            shutdownPending = true;
            SyncState();
        }

        void CancelPendingShutdown(string balloon)
        {
            if (!shutdownPending) return;
            RunShutdownExe("/a");
            shutdownPending = false;
            displayOffSinceTick = Now();
            if (balloon != null)
                tray.ShowBalloonTip(4000, "熄屏自动关机", balloon, ToolTipIcon.Info);
            SyncState();
        }

        static bool InputSince(uint tick)
        {
            LASTINPUTINFO info = new LASTINPUTINFO();
            info.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
            if (!GetLastInputInfo(ref info)) return false;
            return unchecked((int)(info.dwTime - tick)) > 0;
        }

        static int RunShutdownExe(string args)
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "shutdown.exe"), args);
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                using (Process p = Process.Start(psi))
                {
                    if (!p.WaitForExit(10000)) return -1;
                    return p.ExitCode;
                }
            }
            catch (Exception)
            {
                return -1;
            }
        }

        void SetPaused(bool value)
        {
            paused = value;
            if (paused) CancelPendingShutdown("已暂停，关机已取消。");
            displayOffSinceTick = Now();
            SyncState();
        }

        void SetMinutes(int value)
        {
            minutes = value;
            displayOffSinceTick = Now();
            SaveConfig();
            SyncState();
        }

        void Uninstall()
        {
            DialogResult answer = MessageBox.Show("确定要卸载熄屏自动关机吗？卸载后开机不会再自动启动。",
                "熄屏自动关机", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
            if (answer != DialogResult.Yes) return;

            ProcessStartInfo psi = new ProcessStartInfo(
                Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"),
                "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + scriptPath + "\" -Uninstall");
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.WorkingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            Process.Start(psi);
            ExitThread();
        }

        string LaunchCommand()
        {
            string system = Environment.SystemDirectory;
            return "\"" + Path.Combine(system, "conhost.exe") + "\" --headless \"" +
                   Path.Combine(system, @"WindowsPowerShell\v1.0\powershell.exe") +
                   "\" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + scriptPath + "\"";
        }

        // Autostart is on when the Run value exists and Task Manager has not marked it disabled.
        // StartupApproved data starts with an even byte when enabled and an odd byte when disabled.
        static bool IsAutostartEnabled()
        {
            try
            {
                using (RegistryKey run = Registry.CurrentUser.OpenSubKey(RunKeyPath))
                {
                    if (run == null || run.GetValue(RunValueName) == null) return false;
                }
                using (RegistryKey approved = Registry.CurrentUser.OpenSubKey(ApprovedKeyPath))
                {
                    if (approved == null) return true;
                    byte[] data = approved.GetValue(RunValueName) as byte[];
                    return data == null || data.Length == 0 || (data[0] & 1) == 0;
                }
            }
            catch (Exception)
            {
                return false;
            }
        }

        void SetAutostart(bool enabled)
        {
            try
            {
                using (RegistryKey run = Registry.CurrentUser.CreateSubKey(RunKeyPath))
                {
                    if (enabled) run.SetValue(RunValueName, LaunchCommand(), RegistryValueKind.String);
                    else run.DeleteValue(RunValueName, false);
                }
                using (RegistryKey approved = Registry.CurrentUser.OpenSubKey(ApprovedKeyPath, true))
                {
                    if (approved != null) approved.DeleteValue(RunValueName, false);
                }
                tray.ShowBalloonTip(3000, "熄屏自动关机", enabled ? "已开启开机自动启动。" : "已关闭开机自动启动。", ToolTipIcon.Info);
            }
            catch (Exception ex)
            {
                tray.ShowBalloonTip(4000, "熄屏自动关机", "设置开机自动启动失败：" + ex.Message, ToolTipIcon.Warning);
            }
            SyncState();
        }

        // Blocks idle sleep while counting or during the countdown. Display timeout, lid close and the power button are unaffected.
        void ApplySleepBlock()
        {
            bool want = shutdownPending || (displayOff && !paused);
            if (want == sleepBlocked) return;
            SetThreadExecutionState(want ? ES_CONTINUOUS | ES_SYSTEM_REQUIRED : ES_CONTINUOUS);
            sleepBlocked = want;
        }

        void SyncState()
        {
            ApplySleepBlock();

            string status;
            if (paused) status = "已暂停";
            else if (shutdownPending) status = "关机倒计时中";
            else status = "熄屏 " + FormatMinutes(minutes) + "后关机";

            statusItem.Text = "状态：" + status;
            tray.Text = "熄屏自动关机：" + status;
            tray.Icon = paused ? pausedIcon : activeIcon;
            pauseItem.Checked = paused;
            autostartItem.Checked = IsAutostartEnabled();
            foreach (ToolStripItem item in delayMenu.DropDownItems)
            {
                ToolStripMenuItem menuItem = item as ToolStripMenuItem;
                if (menuItem != null) menuItem.Checked = (int)menuItem.Tag == minutes;
            }
        }

        static string FormatMinutes(int m)
        {
            if (m >= 60 && m % 60 == 0) return (m / 60) + " 小时";
            return m + " 分钟";
        }

        void LoadConfig()
        {
            try
            {
                int value;
                if (File.Exists(configPath) && int.TryParse(File.ReadAllText(configPath).Trim(), out value) &&
                    value > 0 && value <= MaxMinutes)
                    minutes = value;
            }
            catch (Exception) { }
        }

        void SaveConfig()
        {
            try { File.WriteAllText(configPath, minutes.ToString()); }
            catch (Exception) { }
        }

        static Icon MakeIcon(Color color)
        {
            Bitmap bmp = new Bitmap(32, 32);
            using (Graphics g = Graphics.FromImage(bmp))
            using (SolidBrush brush = new SolidBrush(color))
            using (Pen pen = new Pen(Color.White, 3.5f))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.Clear(Color.Transparent);
                g.FillEllipse(brush, 1, 1, 30, 30);
                pen.StartCap = LineCap.Round;
                pen.EndCap = LineCap.Round;
                g.DrawArc(pen, 8, 9, 16, 16, -60, 300);
                g.DrawLine(pen, 16, 6, 16, 15);
            }
            return Icon.FromHandle(bmp.GetHicon());
        }

        protected override void ExitThreadCore()
        {
            CancelPendingShutdown(null);
            timer.Stop();
            display.Dispose();
            if (sleepBlocked) SetThreadExecutionState(ES_CONTINUOUS);
            tray.Visible = false;
            tray.Dispose();
            base.ExitThreadCore();
        }
    }
}
'@

try {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing

    if ($Install)   { Install-App;   return }
    if ($Uninstall) { Uninstall-App; return }

    # WaitOne gives a just-killed previous instance time to release the mutex.
    $mutex = New-Object System.Threading.Mutex($false, 'Local\AutoShutdownOnDisplayOff')
    $acquired = $false
    try { $acquired = $mutex.WaitOne(3000) }
    catch [System.Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) {
        Show-Message "已经在运行了。$TrayHint"
        return
    }

    try {
        Add-Type -TypeDefinition $source -ReferencedAssemblies System.Windows.Forms, System.Drawing -IgnoreWarnings
        [AutoShutdown.App]::Run((Join-Path $PSScriptRoot 'config.txt'), $PSCommandPath)
    }
    finally {
        $mutex.ReleaseMutex()
    }
}
catch {
    $text = "出错了：`n`n" + $_.Exception.Message
    try { Show-Message $text 'Error' } catch { Write-Host $text }
    exit 1
}
