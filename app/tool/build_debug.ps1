#Requires -Version 7.0
<#
.SYNOPSIS
在本机构建调试包，只留最新的一份，版本号带上当前提交编号。

.DESCRIPTION
构建产物整理到仓库根目录的 build/debug/，每次构建前清掉，目录里只剩这一次的
安装包、哈希与说明，装到手机上时不会拿错包。版本串读 pubspec.yaml 的 version，
按 debug 构建的打法加 -dev，再接上 HEAD 提交的前 7 位，例如 0.2.0-dev+3。

构建时把提交编号与产物路径写进 app/android/last_build.json，脚本异常退出之后
`android/gradlew assembleDebug` 与 Android Studio 再构建也带同一个编号；下一次
由本脚本构建、提交变了或者提交编号无法解析时删掉它。

服务地址：本机模拟器要用 http://10.0.2.2:8080 连本机的服务器，开发包默认连的
是线上实例，所以目标里有模拟器时自动带上。用 -ServerUrl 指定线上实例或局域网
地址；不想覆盖时用 -NoServerUrl。

.EXAMPLE
pwsh tool/build_debug.ps1
# 只打 arm64、装到已经连上的真机：
pwsh tool/build_debug.ps1 -Install
# 模拟器联调：走本机的服务器。
pwsh tool/build_debug.ps1 -ServerUrl http://10.0.2.2:8080 -Install
#>
[CmdletBinding()]
param(
  # 目标架构，默认与 CI 一致只出 arm64；模拟器要 x86_64 时写 android-x64。
  [string[]]$TargetPlatform = @('android-arm64'),
  # 构建之后覆盖到设备上；不指定设备时取已连上的第一台。
  [switch]$Install,
  [string]$Device,
  # 覆盖开发包默认连的知新服务地址，例如 http://10.0.2.2:8080。
  [string]$ServerUrl,
  # 不写服务地址，开发包连线上实例，登录已有账号。
  [switch]$NoServerUrl
)

$ErrorActionPreference = 'Stop'

$appDir = Split-Path -Parent $PSScriptRoot
$rootDir = Split-Path -Parent $appDir
$localProperties = Join-Path $appDir 'android\local.properties'
# Gradle 读这个文件，路径由本脚本维护；文件名以 .tmp 结尾，构建系统把它当临时文件。
$lastBuildFile = Join-Path $appDir 'android\last_build.json'
$outputDir = Join-Path $rootDir 'build\debug'

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

# 提交编号读不出来时只给警告：靠提交来源日志还原崩溃栈时缺的就是这一串，越早发现越好。
# 用 git.exe 的完整路径，免得按 PATH 里的命令做别名解析。
function Get-CurrentCommit {
  $git = Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if (-not $git) {
    Write-Warning '找不到 git，这一版不带提交号；提交编号是还原崩溃栈的依据，装之前先修好。'
    return ''
  }
  $commit = (& $git.Source -C $rootDir rev-parse --short=7 HEAD 2>$null | Select-Object -First 1)
  if ($LASTEXITCODE -ne 0 -or -not "$commit".Trim()) {
    Write-Warning '读不到当前提交编号，这一版不带提交号（检查是否在 git 仓库里）。'
    return ''
  }
  return "$commit".Trim()
}

# 上一次留下的构建信息：只在本脚本异常退出、Gradle 直接接手时有用。
function Read-LastBuild {
  if (-not (Test-Path $lastBuildFile)) { return $null }
  try {
    return Get-Content -Raw -Path $lastBuildFile | ConvertFrom-Json
  } catch {
    return $null
  }
}

$flutter = Resolve-Flutter
$commit = Get-CurrentCommit
$versionFull = (Get-Content (Join-Path $appDir 'pubspec.yaml') |
  Where-Object { $_ -match '^version:\s*\S' } |
  Select-Object -First 1) -replace '^version:\s*', ''
if (-not $versionFull) { throw 'pubspec.yaml 里没有 version 一行。' }
$versionBase = ($versionFull -split '\+', 2)[0]
$versionLabel = if ($commit) { "$versionBase-dev+$commit" } else { "$versionBase-dev" }

if (-not $NoServerUrl -and -not $ServerUrl -and
  ($TargetPlatform -contains 'android-x64' -or $TargetPlatform -contains 'android-x86')) {
  $ServerUrl = 'http://10.0.2.2:8080'
  Write-Host '目标里有模拟器：开发包连本机的服务器 http://10.0.2.2:8080，登录账户记在模拟器里。'
}

# 上一次的信息指向哪一份包：Gradle 只从这份文件读提交编号，内容坏掉时删掉，
# 免得下一次构建读到半截 JSON。
$lastBuild = Read-LastBuild
if (-not $lastBuild) {
  Remove-Item -LiteralPath $lastBuildFile -Force -ErrorAction SilentlyContinue
}

# 只留最新的一份：先清目录，构建失败时也不留着旧包冒充这一版。
if (Test-Path $outputDir) { Remove-Item -LiteralPath $outputDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

$defines = @('--debug')
foreach ($platform in $TargetPlatform) { $defines += @('--target-platform', $platform) }
# 提交编号不在这里传：flutter build 把 -P 当成自己的参数，传不过去，编号由 Gradle 从
# 刚写下的 last_build.json 里读，与之后直接跑 gradlew 走的是同一条路。
if ($ServerUrl) {
  # http 地址只在显式开启明文联调的构建里可用，与 ServerClient 的判断一致。
  $defines += "--dart-define=ZHIXIN_SERVER_URL=$($ServerUrl.TrimEnd('/'))"
  if ($ServerUrl -match '^http://') { $defines += '--dart-define=ZHIXIN_ALLOW_INSECURE_SERVER=true' }
}

Write-Host "构建调试包 $versionLabel（$($TargetPlatform -join '、')）……"
$startedAt = Get-Date
# 构建之前就把这一版的信息写下来：Gradle 从这里读提交编号写进 Dart 侧，之后直接跑
# gradlew 或 Android Studio 也沿用，直到下一次由本脚本构建。
$lastBuild = @{
  commit = $commit
  server_url = $ServerUrl
  target_platform = ($TargetPlatform -join ',')
  apk_path = (Join-Path $outputDir "zhixin-debug-$versionLabel.apk")
  sha256 = ''
  version = $versionLabel
  started_at = $startedAt.ToUniversalTime().ToString('o')
  finished_at = ''
}
$lastBuild | ConvertTo-Json | Set-Content -LiteralPath $lastBuildFile -Encoding utf8NoBOM

Push-Location $appDir
try {
  & $flutter build apk @defines
  $built = $LASTEXITCODE -eq 0
} finally {
  Pop-Location
}
if (-not $built) { throw '构建失败，没有留下安装包；build/debug/ 已经清空。' }

$apk = Join-Path $appDir 'build\app\outputs\flutter-apk\app-debug.apk'
if (-not (Test-Path $apk)) { throw "构建命令成功，但没有找到 $apk。" }
$apkName = Split-Path -Leaf $lastBuild.apk_path
$apkPath = $lastBuild.apk_path
Move-Item -LiteralPath $apk -Destination $apkPath
$sha256 = (Get-FileHash -LiteralPath $apkPath -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath (Join-Path $outputDir "$apkName.sha256") -Value "$sha256  $apkName" -Encoding utf8NoBOM

$builtAt = Get-Date
$lastBuild.sha256 = $sha256
$lastBuild.finished_at = $builtAt.ToUniversalTime().ToString('o')
$lastBuild | ConvertTo-Json | Set-Content -LiteralPath $lastBuildFile -Encoding utf8NoBOM

$summary = @"
# 知新调试包 $versionLabel

| 项 | 值 |
|---|---|
| 版本 | $versionLabel |
| 提交 | $commit |
| 服务地址 | $(if ($ServerUrl) { $ServerUrl } else { '线上实例（默认）' }) |
| 目标 | $($TargetPlatform -join '、') |
| 大小 | $([math]::Round((Get-Item $apkPath).Length / 1MB, 1)) MB |
| SHA-256 | $sha256 |
| 构建于 | $($builtAt.ToString('yyyy-MM-dd HH:mm:ss')) |

安装包 $apkName 与 .sha256 都在 build/debug/，下一次构建会删掉这一份。
"@
Set-Content -LiteralPath (Join-Path $outputDir 'build.md') -Value $summary -Encoding utf8NoBOM

Write-Host "调试包：$apkPath"
Write-Host "版本 $versionLabel，提交 $commit，SHA-256 $sha256"

if (-not $Install) { return }

$sdk = Resolve-AndroidSdk
$adb = Join-Path $sdk 'platform-tools\adb.exe'
$adbTarget = @()
if ($Device) {
  $adbTarget = @('-s', $Device)
} else {
  $ready = (& $adb devices 2>$null | Select-Object -Skip 1 | Where-Object { $_ -match '^(\S+)\s+device$' })
  if (-not $ready) { throw '没有已连上的设备：先启动模拟器或者插上真机并打开 USB 调试，再用 -Device 指定。' }
  $adbTarget = @('-s', ($ready | Select-Object -First 1).Split()[0])
}
# 覆盖同一个应用的旧安装，数据保留；首次安装到新设备时就是全新的一份。
& $adb @adbTarget install -r $apkPath
if ($LASTEXITCODE -ne 0) { throw '安装失败，安装包保留在 build/debug/。' }
Write-Host "已装到 $($adbTarget -join ' ')。"
