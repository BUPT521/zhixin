import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart' hide Material, MaterialPage;

import 'theme.dart';

import '../app_scope.dart';
import '../domain/models/material.dart';
import 'zhixin_sheet.dart';
import 'zhixin_toast.dart';

/// 一次材料页码选择。
class MaterialSelection {
  const MaterialSelection({
    required this.materialId,
    required this.materialTitle,
    required this.pageNo,
  });

  final int materialId;
  final String materialTitle;
  final int pageNo;

  String get label => '《$materialTitle》第 $pageNo 页';
}

/// 选择材料与页码；没有材料时提示先去记录里导入。
Future<MaterialSelection?> showMaterialPicker(
  BuildContext context, {
  int? initialMaterialId,
  int? initialPageNo,
}) async {
  final scope = AppScope.of(context);
  final materials = await scope.materialService.list();
  if (!context.mounted) return null;
  if (materials.isEmpty) {
    showToast(context, '暂无材料。前往“记录 → 材料”导入页面。');
    return null;
  }
  final material = await showZhixinSheet<Material>(
    context: context,
    builder: (context) => ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        Text('这次依据哪份材料', style: context.zhixin.text.titleMedium),
        const SizedBox(height: 8),
        for (final item in materials)
          forui.FTile(
            prefix: Icon(
              item.id == initialMaterialId
                  ? FLucideIcons.circleDot
                  : FLucideIcons.bookOpen,
            ),
            title: Text(item.title),
            subtitle: Text(
              '${item.kindLabel} · ${item.pageCount} ${item.isDocx ? '个片段' : '页'}'
              '${item.sourceRef == null ? '' : ' · ${item.sourceRef}'}',
            ),
            onPress: () => Navigator.of(context).pop(item),
          ),
      ],
    ),
  );
  if (material == null || !context.mounted) return null;

  final pages = await scope.materialService.pages(material.id);
  if (!context.mounted) return null;
  if (pages.isEmpty) {
    showToast(context, '这份材料还没有页面');
    return null;
  }
  final page = await showZhixinSheet<MaterialPage>(
    context: context,
    builder: (context) => ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        Text('《${material.title}》的哪一页', style: context.zhixin.text.titleMedium),
        const SizedBox(height: 8),
        for (final item in pages)
          forui.FTile(
            prefix: Icon(
              item.pageNo == initialPageNo
                  ? FLucideIcons.circleDot
                  : FLucideIcons.fileText,
            ),
            title: Text(
              '第 ${item.pageNo} ${material.isDocx ? '个片段' : '页'}'
              '${item.label == null ? '' : ' · ${item.label}'}',
            ),
            subtitle: Text(
              item.preview,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            onPress: () => Navigator.of(context).pop(item),
          ),
      ],
    ),
  );
  if (page == null) return null;
  return MaterialSelection(
    materialId: material.id,
    materialTitle: material.title,
    pageNo: page.pageNo,
  );
}
