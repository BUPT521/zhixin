#Requires -Version 7.0
# 在 PLK110 上按顺序跑 zvec 索引的两种数据量：先生成，再冷打开并检索。
# 探针以 tool/adr_0022_probe.dart 为入口构建，构建时用 -Ptarget 指定入口，
# 应用 ID 带 .adr0022probe 后缀，与正式包并存，见 app/android/app/build.gradle.kts。
param(
  [Parameter(Mandatory)]
  [string]$Apk,
  [string]$Device,
  [switch]$SkipInstall,
  # 写入走刷新用的 replaceSource，两万条数据在真机上可能需要几分钟。
  [int]$TimeoutSeconds = 600
)

$ErrorActionPreference = 'Stop'
$package = 'com.zhixin.app.adr0022probe'
$component = "$package/com.zhixin.app.MainActivity"
$adbTarget = @()
if ($Device) { $adbTarget = @('-s', $Device) }

function Invoke-ProbeAdb {
  $output = & adb @adbTarget @args
  if ($LASTEXITCODE -ne 0) { throw "adb $($args -join ' ') 失败。" }
  return $output
}

$model = (Invoke-ProbeAdb shell getprop ro.product.model).Trim()
if ($model -ne 'PLK110') { throw "设备型号为 $model，探针要求 PLK110。" }

$sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { $env:ANDROID_SDK_ROOT }
if (!$sdk) { throw '请设置 ANDROID_HOME 或 ANDROID_SDK_ROOT。' }
$aapt = Get-ChildItem -LiteralPath (Join-Path $sdk 'build-tools') -Directory |
  Sort-Object { [version]$_.Name } -Descending |
  ForEach-Object { Join-Path $_.FullName 'aapt.exe' } |
  Where-Object { Test-Path -LiteralPath $_ } |
  Select-Object -First 1
if (!$aapt) { throw 'Android SDK 中没有找到 aapt.exe。' }

$apkPath = (Resolve-Path -LiteralPath $Apk).Path
$badging = & $aapt dump badging $apkPath
if ($LASTEXITCODE -ne 0 -or ($badging | Select-Object -First 1) -notmatch "^package: name='$([regex]::Escape($package))'") {
  throw "请选择以 tool/adr_0022_probe.dart 为入口构建的 APK，应用 ID 应为 $package。"
}
if ($SkipInstall) {
  Invoke-ProbeAdb shell pm path $package | Out-Null
} else {
  Invoke-ProbeAdb install -r $apkPath | Out-Host
}

function Measure-Index([int]$Size, [string]$Phase) {
  $route = "/adr0022/$Size/$Phase"
  $launch = Invoke-ProbeAdb shell am start -S -W -n $component --es route $route
  if ($launch -match '^LaunchState: UNKNOWN') {
    # PLK110 的安装器可能在更新后启动探针，等它完成后重启并重新传入参数。
    Start-Sleep -Seconds 2
    Invoke-ProbeAdb shell am force-stop $package | Out-Null
    $launch = Invoke-ProbeAdb shell am start -W -n $component --es route $route
  }
  $launch | Out-Host
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  while ([DateTime]::UtcNow -lt $deadline) {
    $probePid = & adb @adbTarget shell pidof $package
    if ($LASTEXITCODE -eq 0 -and $probePid -match '^\d+$') {
      $line = Invoke-ProbeAdb logcat -d "--pid=$probePid" -s 'flutter:I' |
        Where-Object { $_ -match 'ADR0022 ' } | Select-Object -Last 1
      if ($line -match 'ADR0022 ERROR (.*)$') { throw $Matches[1] }
      if ($line -match 'ADR0022 (\{.*\})$') {
        $json = $Matches[1]
        $metrics = $json | ConvertFrom-Json
        $expectedPhase = if ($Phase -eq 'seed') { 'seed' } else { 'open_and_query' }
        if ($metrics.engine -ne 'zvec' -or $metrics.vectors -ne $Size -or $metrics.phase -ne $expectedPhase) {
          throw "手机返回的相位与请求不同：$json"
        }
        if (!$metrics.cold_zvec_open) { throw 'zvec 在冷打开测量之前已经初始化。' }
        return $json
      }
    }
    Start-Sleep -Seconds 1
  }
  throw "zvec $Size $Phase 未在 $TimeoutSeconds 秒内完成。"
}

foreach ($size in 2000, 20000) {
  Measure-Index $size seed
  Measure-Index $size query
}
