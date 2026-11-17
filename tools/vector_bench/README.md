# vector_bench

20 万条 1024 维向量的向量检索基准，只在 Android 真机上运行。它测两件事：zvec 0.8.0 的 Flat、HNSW、IVF 三种索引在 FP16、INT8、INT4 量化下的写入、建索引、磁盘、内存、延迟与召回；sqlite-vec 0.1.9 的 float32、int8、bit 三种存储在同一份数据上的同样指标。测得的结论写在 [docs/向量检索基准.md](../../docs/向量检索基准.md)，原始数据在 [results](results/)。

## 与主工程的关系

这是一个独立的 Flutter 应用，不加入 `app/` 的依赖。sqlite-vec 需要把 C 源码编译进 APK，如果加进主工程会随每次构建携带这个原生库；独立应用只安装一次，与正式包并存，测完可以单独卸载。

## 构建与运行

```powershell
cd tools/vector_bench
flutter build apk --release --target-platform android-arm64
adb install -r build/app/outputs/flutter-apk/app-release.apk

# 均匀随机分布，全部场景
pwsh run_bench.ps1 -Vectors 200000 -Queries 100

# 聚集分布，指定场景与 HNSW 的 ef
pwsh run_bench.ps1 -Vectors 200000 -Dataset clusters -Clusters 512 -Noise 0.5 `
  -Scenarios zvec_flat_fp32,zvec_flat_int8,sqlite_f32 -HnswEfs 100,400,1600
```

`run_bench.ps1` 把配置推进设备的外部私有目录，重开应用，等 `results.jsonl` 出现结束标记，再把结果拉到 `results/`。设备需要先用 `adb devices` 确认，脚本里的序列号是 PLK110 的，换设备时改脚本顶部的 `$device`。

## 配置

配置文件是 `config.json`，由脚本生成，字段如下。省略时用 `lib/main.dart` 里 `BenchConfig` 的默认值。

| 字段 | 含义 | 默认 |
|---|---|---|
| `vectors` | 向量条数 | 200000 |
| `dim` | 维度 | 1024 |
| `queries` | 查询条数 | 100 |
| `topk` | 每种索引取回的条数，也是 recall 的口径 | 10 |
| `seed` | 线性同余生成器的种子 | 20261117 |
| `dataset` | `uniform` 每个分量独立均匀取值；`clusters` 在中心上叠加扰动 | uniform |
| `clusters` | `clusters` 分布的中心数 | 512 |
| `noise` | `clusters` 分布每个分量的扰动幅度 | 0.5 |
| `memory_limit_mb` | zvec 引擎内存上限 | 6144 |
| `optimize_threads` | zvec 建索引的线程数；查询线程固定为 1，与应用一致 | 4 |
| `hnsw_ef` | HNSW 首档查询 ef，也是重开后首次查询用的值 | 100 |
| `hnsw_efs` | HNSW 依次测量的 ef，各跑一遍全部查询 | 100,400,1600 |
| `hnsw_m` / `hnsw_ef_construction` | HNSW 建图参数 | 16 / 200 |
| `ivf_nlist` / `ivf_nprobe` | IVF 的聚类数与查询探测数 | 1024 / 64 |
| `scenarios` | 要跑的场景名 | 见下 |

## 场景

| 场景名 | 索引 | 量化 |
|---|---|---|
| `zvec_flat_fp32` | zvec Flat | 无 |
| `zvec_flat_fp16` | zvec Flat | FP16 |
| `zvec_flat_int8` | zvec Flat | INT8 |
| `zvec_flat_int4` | zvec Flat | INT4 |
| `zvec_hnsw_fp32` / `_fp16` / `_int8` / `_int4` / `_rabitq` | zvec HNSW | 对应量化 |
| `zvec_ivf_fp32` / `_int8` | zvec IVF | 无 / INT8 |
| `sqlite_f32` | sqlite-vec `vec0` | float32 |
| `sqlite_int8` | sqlite-vec `vec0` | int8，`vec_quantize_int8('unit')` |
| `sqlite_bit` | sqlite-vec `vec0` | bit，`vec_quantize_binary()` |

`zvec_hnsw_rabitq` 在 Android arm64 上会失败：zvec 0.8.0 的 RaBitQ 不支持这个平台，结果里记录 `notSupported`，保留它用来说明这一条不可用。

## 指标口径

每个场景先删掉同名目录，再新建 collection 或数据库，按 1000 条一批写入。写入耗时是全部批次的和，优化耗时是 `optimize()`（HNSW/IVF 在这里建图或聚类），磁盘是场景目录（sqlite 是库文件与 WAL）的大小，内存取 `ProcessInfo.currentRss` 与 `maxRss`。查询先跑 5 条预热，再计时 100 条，p50/p95 按这 100 条计算，计时范围包含取出主键的部分。

真值在设备上用 Dart 暴力算余弦（100 条查询 × 20 万条，约 41 秒），recall@10 是各查询命中真值的条数占比；因此 Flat FP32 的召回必然是 1.000，可以与它自己的结果互相校验。

## 结果的读法

`results/` 下按分布各有一份 JSONL，每行一个场景，字段与上面的口径对应。HNSW 的行还有 `ef_sweep`，记录每一档 ef 的延迟与召回。`reopen_ms` 与 `first_query_ms` 是关掉再打开索引、发出第一条查询的耗时，此时系统页缓存是热的，不代表冷启动。

## 已知限制

数据是合成的。均匀随机在 1024 维上是最难的情况；聚集分布用 512 个中心加扰动生成，k-means 的划分与生成方式高度吻合，会让 IVF 的召回看起来很好。两者都不能替代用应用自己的嵌入模型在真实材料上做的评测，真实的召回要在应用里补测。

基准的优化线程是 4，应用里是 1，HNSW 与 IVF 的建索引时间因此偏乐观；写入走外部私有目录，应用的实际索引在内部存储，写入时间可能略慢。设备连续跑分后会降频，同一配置换一轮重测差 10%～30% 属于正常。

sqlite-vec 的 `unit` 量化把每个分量映射到 [-1,1] 的 256 级，超出范围的值被截断；聚集数据的分量到 ±1.5，所以那一行的召回偏低主要来自截断，不是量化本身。
