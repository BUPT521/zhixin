# 在真机上跑 20 万向量的向量检索基准。
#
# 用法：pwsh tools/vector_bench/run_bench.ps1 -Vectors 200000 -Scenarios zvec_flat_fp32,sqlite_f32
# 省略参数时用 config.json 的默认场景。脚本把配置推进外部私有目录、重开应用、
# 等 results.jsonl 出现 end 事件，再把结果拉到 tools/vector_bench/results/ 下。

param(
  [int]$Vectors = 200000,
  [int]$Dim = 1024,
  [int]$Queries = 100,
  [int]$TimeoutMinutes = 180,
  [string]$Scenarios = '',
  [int]$HnswEf = 100,
  [string]$HnswEfs = '100,400,1600',
  [int]$IvfNlist = 1024,
  [int]$IvfNprobe = 64,
  [string]$Dataset = 'uniform',
  [int]$Clusters = 512,
  [double]$Noise = 0.5
)

$ErrorActionPreference = 'Stop'
$package = 'com.zhixin.vectorbench'
$device = '3B164M00XU700000'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$remote = "/sdcard/Android/data/$package/files/vector_bench"
$local = Join-Path $root 'results'

function Invoke-Adb {
  param([string[]]$Arguments)
  $output = & adb -s $device @Arguments 2>&1
  if ($LASTEXITCODE -ne 0) { throw "adb $($Arguments -join ' ') 失败：$output" }
  return $output
}

$state = & adb -s $device get-state 2>&1
if ($state -ne 'device') { throw "设备未连接：$state" }

$config = [ordered]@{
  vectors              = $Vectors
  dim                  = $Dim
  queries              = $Queries
  topk                 = 10
  seed                 = 20261117
  memory_limit_mb      = 6144
  optimize_threads     = 4
  hnsw_ef              = $HnswEf
  hnsw_efs             = @($HnswEfs.Split(',') | ForEach-Object { [int]$_ })
  hnsw_m               = 16
  hnsw_ef_construction = 200
  ivf_nlist            = $IvfNlist
  ivf_nprobe           = $IvfNprobe
  dataset              = $Dataset
  clusters             = $Clusters
  noise                = $Noise
}
if ($Scenarios -ne '') { $config['scenarios'] = $Scenarios.Split(',') }

Invoke-Adb @('shell', 'svc', 'power', 'stayon', 'true') | Out-Null
Invoke-Adb @('shell', 'mkdir', '-p', $remote) | Out-Null
$tempConfig = Join-Path ([System.IO.Path]::GetTempPath()) 'vector_bench_config.json'
$config | ConvertTo-Json -Depth 5 | Set-Content -Path $tempConfig -Encoding utf8
Invoke-Adb @('push', $tempConfig, "$remote/config.json") | Out-Null
# 外部私有目录里的数据由应用自己清理：adb shell 删不掉应用创建的文件（LOG、LOCK、sst）。
Invoke-Adb @('shell', 'am', 'force-stop', $package) | Out-Null
$logcat = Start-Job -ScriptBlock {
  param($device)
  & adb -s $device logcat -c
  & adb -s $device logcat -s flutter:V
} -ArgumentList $device
Invoke-Adb @('shell', 'monkey', '-p', $package, '-c', 'android.intent.category.LAUNCHER', '1') | Out-Null

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$finished = $false
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 20
  $tail = & adb -s $device shell "tail -n 3 $remote/results.jsonl 2>/dev/null"
  $progress = & adb -s $device shell "wc -l $remote/results.jsonl 2>/dev/null"
  Write-Host ("[{0}] {1} 行；{2}" -f (Get-Date -Format 'HH:mm:ss'), ($progress -split ' ')[0], (($tail -join ' ') -replace '\s+', ' '))
  if (($tail -join "`n") -match '"event":"end"') { $finished = $true; break }
}

Stop-Job $logcat -ErrorAction SilentlyContinue
Receive-Job $logcat -ErrorAction SilentlyContinue | Select-Object -Last 40
Remove-Job $logcat -Force -ErrorAction SilentlyContinue

if (-not $finished) { throw "超过 $TimeoutMinutes 分钟仍未结束，结果留在设备上：$remote/results.jsonl" }

New-Item -ItemType Directory -Force -Path $local | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$target = Join-Path $local "results-$Dataset-$Vectors-$stamp.jsonl"
& adb -s $device pull "$remote/results.jsonl" $target | Out-Null
Write-Host "结果已保存：$target"
