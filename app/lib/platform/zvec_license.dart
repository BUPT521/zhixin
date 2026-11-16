import 'package:flutter/foundation.dart';

/// 把 zvec C 库的第三方组件许可加入许可页；启动时调用一次。
///
/// zvec 的 Dart 包本身是 Apache-2.0，Flutter 的许可页会自动收集；C 库的发布包
/// 没有附带第三方许可清单，这里按 zvec 上游仓库 v0.8.0 的 thirdparty/ 目录与
/// NOTICE 文件补一份（ADR-0022 实施方案第 7 节）。
void registerZvecLicense() {
  LicenseRegistry.addLicense(() async* {
    yield const LicenseEntryWithLineBreaks(['zvec'], zvecLicenseText);
  });
}

/// 组件与版本取自 zvec v0.8.0 的 thirdparty/ 目录；Unicode 与 pyglass 两段
/// 许可证正文逐字取自同版本的 NOTICE 文件。
const String zvecLicenseText =
    '''zvec C 库（v0.8.0）以 Apache License 2.0 发布，包含以下第三方组件，各组件按自己的许可发布。

第三方组件
----------
arrow 21.0.0            Apache-2.0
rocksdb 8.1.1           Apache-2.0
glog 0.5.0              BSD-3-Clause
gflags 2.2.2            BSD-3-Clause
googletest 1.10.0       BSD-3-Clause
lz4 1.9.4               BSD-2-Clause
yaml-cpp 0.6.3          MIT
antlr4                  BSD-3-Clause
CRoaring 2.0.4          Apache-2.0
FastPFOR 0.4.0          Apache-2.0
sparsehash 2.0.4        BSD-3-Clause
magic_enum 0.9.7        MIT
RaBitQ-Library 0.7.0    Apache-2.0
cppjieba 5.6.7          MIT
limonp 1.0.2            MIT
utf8proc 2.11.3         MIT
snowball 3.1.1          BSD-3-Clause

完整许可原文见 zvec 上游仓库 v0.8.0 的 thirdparty/<组件>/ 目录：
https://github.com/alibaba/zvec/tree/v0.8.0/thirdparty

Unicode Character Database（Unicode License V3）
------------------------------------------------
UNICODE LICENSE V3 COPYRIGHT AND PERMISSION NOTICE
Copyright © 1991-2026 Unicode, Inc.
NOTICE TO USER: Carefully read the following legal agreement. BY DOWNLOADING,
INSTALLING, COPYING OR OTHERWISE USING DATA FILES, AND/OR SOFTWARE, YOU
UNEQUIVOCALLY ACCEPT, AND AGREE TO BE BOUND BY, ALL OF THE TERMS AND
CONDITIONS OF THIS AGREEMENT. IF YOU DO NOT AGREE, DO NOT DOWNLOAD, INSTALL,
COPY, DISTRIBUTE OR USE THE DATA FILES OR SOFTWARE.

Permission is hereby granted, free of charge, to any person obtaining a copy
of data files and any associated documentation (the "Data Files") or software
and any associated documentation (the "Software") to deal in the Data Files
or Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, and/or sell copies of the Data
Files or Software, and to permit persons to whom the Data Files or Software
are furnished to do so, provided that either (a) this copyright and
permission notice appear with all copies of the Data Files or Software, or
(b) this copyright and permission notice appear in associated Documentation.

THE DATA FILES AND SOFTWARE ARE PROVIDED "AS IS", WITHOUT WARRANTY OF ANY
KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF
THIRD PARTY RIGHTS.

IN NO EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS INCLUDED IN THIS NOTICE BE
LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT OR CONSEQUENTIAL DAMAGES, OR
ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER
IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THE DATA FILES OR SOFTWARE.

Except as contained in this notice, the name of a copyright holder shall not
be used in advertising or otherwise to promote the sale, use or other
dealings in these Data Files or Software without prior written authorization
of the copyright holder.

pyglass（MIT License，Copyright (c) 2023 zh Wang）
-------------------------------------------------
MIT License

Copyright (c) 2023 zh Wang

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.''';
