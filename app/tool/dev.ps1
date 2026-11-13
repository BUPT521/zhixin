#Requires -Version 7.0
<#
.SYNOPSIS
在本机模拟器或者已经连上的设备上运行知新，改完代码按 r 热重载，不必重新打包装到手机。

.EXAMPLE
pwsh tool/dev.ps1
#>
[CmdletBinding()]
param(
  # AVD 名称，默认取 emulator -list-avds 里的第一个。
  [string]$Avd,
  # 直接指定设备序列号，跳过查找与启动模拟器。
  [string]$Device,
  # 等模拟器开机的最长秒数。
  [int]$TimeoutSeconds = 300,
  # 不调整模拟器窗口的大小与位置。
  [switch]$NoFit
)

$ErrorActionPreference = 'Stop'

$appDir = Split-Path -Parent $PSScriptRoot
$localProperties = Join-Path $appDir 'android\local.properties'

function Get-PropertyValue {
  param([string]$Path, [string]$Key)
  if (-not (Test-Path $Path)) { return $null }
  $line = Get-Content $Path |
    Where-Object { $_ -match "^\s*$([regex]::Escape($Key))\s*=" } |
    Select-Object -First 1
  if (-not $line) { return $null }
  $value = ($line -split '=', 2)[1].Trim()
  # local.properties 里的 Windows 路径写成反斜杠双写。
  return $value -replace '\\\\', '\'
}

function Resolve-Flutter {
  $command = Get-Command flutter -ErrorAction SilentlyContinue
  if ($command) { return $command.Source }
  $sdk = Get-PropertyValue -Path $localProperties -Key 'flutter.sdk'
  if ($sdk) {
    $candidate = Join-Path $sdk 'bin\flutter.bat'
    if (Test-Path $candidate) { return $candidate }
  }
  throw '找不到 flutter：把它加进 PATH，或者在 app/android/local.properties 里写好 flutter.sdk。'
}

function Resolve-AndroidSdk {
  foreach ($name in 'ANDROID_HOME', 'ANDROID_SDK_ROOT') {
    $value = [Environment]::GetEnvironmentVariable($name)
    if ($value -and (Test-Path $value)) { return $value }
  }
  $sdk = Get-PropertyValue -Path $localProperties -Key 'sdk.dir'
  if ($sdk -and (Test-Path $sdk)) { return $sdk }
  throw '找不到 Android SDK：设置 ANDROID_HOME，或者在 app/android/local.properties 里写好 sdk.dir。'
}

# 模拟器按物理像素决定窗口大小、按逻辑像素决定位置，在 2 倍缩放的屏幕上会开到
# 屏幕之外，标题栏拖不到。这里按工作区的比例把它收进屏幕，尺寸比例保持原样。
function Set-EmulatorWindowFit {
  if (-not ('EmuWindow' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class EmuWindow
{
    delegate bool EnumProc(IntPtr h, IntPtr l);

    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern bool SystemParametersInfo(uint action, uint param, ref RECT value, uint winIni);
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();

    [StructLayout(LayoutKind.Sequential)]
    struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    static IntPtr FindWindow()
    {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) =>
        {
            if (!IsWindowVisible(h)) return true;
            var title = new StringBuilder(256);
            GetWindowText(h, title, 256);
            if (title.ToString().StartsWith("Android Emulator"))
            {
                found = h;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    // 返回窗口原来的尺寸与位置；窗口本来就在工作区里时不改动，返回空字符串。
    public static string Fit()
    {
        SetProcessDPIAware();
        IntPtr h = FindWindow();
        if (h == IntPtr.Zero) return "no-window";

        RECT window;
        GetWindowRect(h, out window);
        int width = window.Right - window.Left;
        int height = window.Bottom - window.Top;

        RECT work = new RECT();
        SystemParametersInfo(0x0030, 0, ref work, 0);

        bool inside = window.Left >= work.Left && window.Top >= work.Top
            && window.Right <= work.Right && window.Bottom <= work.Bottom
            && height <= (work.Bottom - work.Top) * 0.95;
        if (inside) return "";

        int targetHeight = (int)((work.Bottom - work.Top) * 0.88);
        int targetWidth = (int)Math.Round(targetHeight * (double)width / height);
        // 缩放比例决定边距：右边留 64 逻辑像素，下边贴着工作区；窗口放到右下角，
        // 不挡住左边编辑区，标题栏也留在屏幕里。
        double scale = GetDpiForWindow(h) / 96.0;
        int marginRight = (int)Math.Round(64 * scale);
        int marginBottom = (int)Math.Round(8 * scale);
        int x = work.Right - targetWidth - marginRight;
        int y = work.Bottom - targetHeight - marginBottom;
        const uint flags = 0x0004 | 0x0010; // SWP_NOZORDER | SWP_NOACTIVATE
        SetWindowPos(h, IntPtr.Zero, x, y, targetWidth, targetHeight, flags);
        return string.Format("{0}x{1} -> {2}x{3}", width, height, targetWidth, targetHeight);
    }
}
'@
  }
  $result = [EmuWindow]::Fit()
  switch ($result) {
    'no-window' { return }
    '' { return }
    default { Write-Host "模拟器窗口超出屏幕，已收到右下角：$result" }
  }
}

$flutter = Resolve-Flutter
$sdk = Resolve-AndroidSdk
$adb = Join-Path $sdk 'platform-tools\adb.exe'
$emulator = Join-Path $sdk 'emulator\emulator.exe'

function Get-ReadySerial {
  $lines = & $adb devices 2>$null | Select-Object -Skip 1
  foreach ($line in $lines) {
    if ($line -match '^(\S+)\s+device$') { return $Matches[1] }
  }
  return $null
}

if (-not $Device) {
  $serial = Get-ReadySerial
  if ($serial) {
    Write-Host "已经在运行的设备：$serial"
  } else {
    if (-not (Test-Path $emulator)) {
      throw "找不到模拟器组件：$emulator。用 SDK Manager 装上 emulator，或直接用 -Device 指定一台已连上的设备。"
    }
    $available = @(& $emulator -list-avds 2>$null | Where-Object { $_ -match '^\S+$' -and $_ -notmatch '^(INFO|WARNING|ERROR)' })
    if (-not $Avd) {
      $Avd = $available | Select-Object -First 1
      if (-not $Avd) {
        throw '没有可用的 AVD：先用 Android Studio 的 Device Manager 建一台，或者用 -Avd 指定名称。'
      }
    } elseif ($available -notcontains $Avd) {
      throw "没有名为 $Avd 的 AVD，现有的是：$($available -join '、')。"
    }

    Write-Host "启动模拟器 $Avd，等它开机完成……"
    # 单独起进程，脚本退出或按 q 之后模拟器继续留着，下一次直接连上。
    Start-Process -FilePath $emulator -ArgumentList @('-avd', $Avd, '-no-boot-anim') | Out-Null

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $serial = $null
    while (-not $serial -and (Get-Date) -lt $deadline) {
      Start-Sleep -Seconds 2
      $candidate = Get-ReadySerial
      if ($candidate) {
        $boot = & $adb -s $candidate shell getprop sys.boot_completed 2>$null
        if ("$boot".Trim() -eq '1') { $serial = $candidate }
      }
    }
    if (-not $serial) {
      throw "等了 $TimeoutSeconds 秒，模拟器还没开机完成。可以在模拟器窗口里看看，或者加大 -TimeoutSeconds。"
    }
    Write-Host "模拟器已开机：$serial"
  }
} else {
  $serial = $Device
}

if (-not $NoFit -and $serial -like 'emulator-*') { Set-EmulatorWindowFit }

Set-Location $appDir
Write-Host '改完代码按 r 热重载，按 R 热重启，按 q 退出。'
& $flutter run -d $serial
exit $LASTEXITCODE
