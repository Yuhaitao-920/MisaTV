/// 轻量 ESM→CJS 正则级转换器（TVBox JS 蜘蛛脚本常见的模块形态）。
///
/// 设计约束：
/// - 只覆盖蜘蛛脚本常见写法，不追求完整 ESM 语义；
/// - 无法安全处理的语法（`export * from`）抛出 [EsmTransformException]，由上层降级；
/// - 不做完整词法分析，字符串/注释里的 `import` 可能被误改（现实极罕见）。
class EsmTransformException implements Exception {
  EsmTransformException(this.message);
  final String message;

  @override
  String toString() => message;
}

const _idSrc = r'[A-Za-z_$\u0080-\uFFFF][A-Za-z0-9_$\u0080-\uFFFF]*';
const _hasModuleSyntax = r'(^|[\n;])\s*(import|export)\b';

final _reImportDefaultNamed = RegExp(
  'import\\s+($_idSrc)\\s*,\\s*\\{([\\s\\S]*?)\\}\\s*from\\s*[\'"]([^\'"]+)[\'"]\\s*;?',
  unicode: true,
);
final _reImportNs = RegExp(
  'import\\s*\\*\\s*as\\s+($_idSrc)\\s+from\\s*[\'"]([^\'"]+)[\'"]\\s*;?',
  unicode: true,
);
final _reImportNamed = RegExp(
  'import\\s*\\{([\\s\\S]*?)\\}\\s*from\\s*[\'"]([^\'"]+)[\'"]\\s*;?',
  unicode: true,
);
final _reImportDefault = RegExp(
  'import\\s+($_idSrc)\\s+from\\s*[\'"]([^\'"]+)[\'"]\\s*;?',
  unicode: true,
);
final _reExportFunc = RegExp(
  'export\\s+(async\\s+)?function\\s+($_idSrc)',
  unicode: true,
);
final _reExportVar = RegExp(
  'export\\s+(const|let|var)\\s+($_idSrc)',
  unicode: true,
);
final _reExportDefault = RegExp(r'export\s+default\s*');
final _reExportFrom = RegExp(
  'export\\s*\\{([\\s\\S]*?)\\}\\s*from\\s*[\'"]([^\'"]+)[\'"]\\s*;?',
  unicode: true,
);
final _reExportLocal = RegExp(r'export\s*\{([\s\S]*?)\}\s*;?');
final _reImportSideEffect = RegExp('import\\s*[\'"]([^\'"]+)[\'"]\\s*;?');
final _reSpecifier = RegExp(
  '^($_idSrc)(?:\\s+as\\s+($_idSrc))?\$',
  unicode: true,
);

class _SpecPair {
  const _SpecPair(this.prop, this.name);
  final String prop;
  final String name;
}

List<_SpecPair> _splitSpecifiers(String raw) {
  final out = <_SpecPair>[];
  for (final piece in raw.split(',')) {
    final s = piece.trim();
    if (s.isEmpty) continue;
    final m = _reSpecifier.firstMatch(s);
    if (m != null) out.add(_SpecPair(m.group(1)!, m.group(2) ?? m.group(1)!));
  }
  return out;
}

String _jsonStr(String s) {
  final escaped = s
      .replaceAll(r'\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll('\n', r'\n');
  return '"$escaped"';
}

/// 把 ESM 源码转换为可在
/// `(function(module, exports, require, __filename){ ... })` 里执行的 CJS 代码。
String transformToCjs(String source, String moduleName) {
  try {
    if (!RegExp(_hasModuleSyntax).hasMatch(source) &&
        !source.contains('export default')) {
      return source;
    }
    var code = source;
    final tail = <String>[];
    var seq = 0;

    // 1) re-export：export { A, B as C } from 'p'
    code = code.replaceAllMapped(_reExportFrom, (m) {
      final names = m.group(1)!;
      final spec = m.group(2)!;
      final tmp = '_m${seq++}';
      final lines = ['const $tmp = require(${_jsonStr(spec)});'];
      for (final it in _splitSpecifiers(names)) {
        lines.add(
          'module.exports[${_jsonStr(it.name)}] = $tmp[${_jsonStr(it.prop)}];',
        );
      }
      return lines.join('\n');
    });

    // 2) export * from —— 无法安全展开
    if (RegExp(r'export\s*\*\s*from').hasMatch(code)) {
      throw EsmTransformException('不支持的语法 export * from（$moduleName）');
    }

    // 3) import
    code = code.replaceAllMapped(_reImportDefaultNamed, (m) {
      final def = m.group(1)!;
      final names = m.group(2)!;
      final spec = m.group(3)!;
      final tmp = '_m${seq++}';
      final lines = [
        'const $tmp = require(${_jsonStr(spec)});',
        'const $def = $tmp != null && $tmp.default !== undefined ? $tmp.default : $tmp;',
      ];
      for (final it in _splitSpecifiers(names)) {
        lines.add('const ${it.name} = $tmp[${_jsonStr(it.prop)}];');
      }
      return lines.join('\n');
    });
    code = code.replaceAllMapped(
      _reImportNs,
      (m) => 'const ${m.group(1)} = require(${_jsonStr(m.group(2)!)});',
    );
    code = code.replaceAllMapped(_reImportNamed, (m) {
      final names = m.group(1)!;
      final spec = m.group(2)!;
      final tmp = '_m${seq++}';
      final lines = ['const $tmp = require(${_jsonStr(spec)});'];
      for (final it in _splitSpecifiers(names)) {
        lines.add('const ${it.name} = $tmp[${_jsonStr(it.prop)}];');
      }
      return lines.join('\n');
    });
    code = code.replaceAllMapped(_reImportDefault, (m) {
      final def = m.group(1)!;
      final spec = m.group(2)!;
      final tmp = '_m${seq++}';
      return 'const $tmp = require(${_jsonStr(spec)});\n'
          'const $def = $tmp != null && $tmp.default !== undefined ? $tmp.default : $tmp;';
    });
    code = code.replaceAllMapped(
      _reImportSideEffect,
      (m) => 'require(${_jsonStr(m.group(1)!)});',
    );

    // 4) export default
    code = code.replaceAll(_reExportDefault, 'module.exports.default = ');

    // 5) export function / export async function
    code = code.replaceAllMapped(_reExportFunc, (m) {
      final aw = m.group(1) ?? '';
      final name = m.group(2)!;
      tail.add('module.exports[${_jsonStr(name)}] = $name;');
      return '${aw}function $name';
    });

    // 6) export const|let|var
    code = code.replaceAllMapped(_reExportVar, (m) {
      final kw = m.group(1)!;
      final name = m.group(2)!;
      tail.add('module.exports[${_jsonStr(name)}] = $name;');
      return '$kw $name';
    });

    // 7) export { A, B as C }（本地导出）
    code = code.replaceAllMapped(_reExportLocal, (m) {
      for (final it in _splitSpecifiers(m.group(1)!)) {
        tail.add('module.exports[${_jsonStr(it.name)}] = ${it.prop};');
      }
      return '';
    });

    return tail.isEmpty ? code : '$code\n${tail.join('\n')}';
  } on EsmTransformException {
    rethrow;
  } catch (e) {
    throw EsmTransformException('ESM→CJS 转换失败（$moduleName）: $e');
  }
}
