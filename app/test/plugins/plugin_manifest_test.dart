import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/plugins/runtime/plugin_manifest.dart';

PluginManifest capability({
  String id = 'timetable',
  String name = '课表导入',
  String version = '1.0.0',
  String description = '从三种来源导入课表。',
  PluginPermissions permissions = PluginPermissions.none,
}) => PluginManifest(
  id: id,
  name: name,
  version: version,
  description: description,
  kind: PluginKind.capability,
  permissions: permissions,
);

PluginManifest persona({
  String id = 'persona',
  String name = '人格',
  String version = '1.0.0',
  String description = '改变搭子的语气与讲解风格。',
  PluginPermissions permissions = PluginPermissions.none,
}) => PluginManifest(
  id: id,
  name: name,
  version: version,
  description: description,
  kind: PluginKind.persona,
  permissions: permissions,
);

void main() {
  test('合格的清单没有错误，权限按四项分别声明', () {
    final manifest = capability(
      permissions: const PluginPermissions(
        networkDomains: ['api.example.com'],
        readDataScopes: ['timetable'],
        writeTypes: ['timetable'],
        callModel: true,
      ),
    );
    expect(manifest.validate(), isEmpty);
    expect(
      manifest.permissions.declared,
      PluginPermission.values,
      reason: '四项都声明时按网络、读取、写入、模型的顺序列出',
    );
    expect(manifest.permissions.allows(PluginPermission.callModel), isTrue);
  });

  test('标识、名称、版本与说明不合格时返回可读的错误', () {
    expect(
      capability(id: 'Bad_ID').validate(),
      contains(contains('插件标识只能用半角小写字母、数字与连字符')),
    );
    expect(
      capability(id: '-timetable').validate(),
      contains(contains('插件标识只能用半角小写字母、数字与连字符')),
    );
    expect(capability(id: '课表').validate(), isNotEmpty);
    expect(capability(name: '  ').validate(), contains('插件名称不能为空'));
    expect(capability(version: '').validate(), contains('插件版本不能为空'));
    expect(
      capability(version: '1.0').validate(),
      contains(contains('插件版本写成三段数字')),
    );
    expect(capability(description: '').validate(), contains('插件说明不能为空'));
  });

  test('人格插件不得声明四项权限中的任何一项', () {
    for (final permissions in [
      const PluginPermissions(networkDomains: ['api.example.com']),
      const PluginPermissions(readDataScopes: ['timetable']),
      const PluginPermissions(writeTypes: ['timetable']),
      const PluginPermissions(callModel: true),
    ]) {
      final errors = persona(permissions: permissions).validate();
      expect(errors, hasLength(1));
      expect(errors.single, contains('人格插件不能声明权限'));
    }
    expect(
      persona(
        permissions: const PluginPermissions(
          networkDomains: ['api.example.com'],
          callModel: true,
        ),
      ).validate().single,
      allOf(contains('网络访问'), contains('调用模型')),
      reason: '错误里列出全部已声明的权限项',
    );
    expect(persona().validate(), isEmpty, reason: '人格插件不声明权限时清单合格');
  });

  test('网络域名只写主机名，读取范围与写入类型不能为空', () {
    final errors = capability(
      permissions: const PluginPermissions(
        networkDomains: ['https://api.example.com/v1', ''],
        readDataScopes: [''],
        writeTypes: [' '],
      ),
    ).validate();
    expect(errors, hasLength(4));
    expect(errors.join('；'), contains('不带协议、路径或空格'));
    expect(errors.join('；'), contains('读取数据的范围不能为空'));
    expect(errors.join('；'), contains('可以提交的写入类型不能为空'));
  });
}
