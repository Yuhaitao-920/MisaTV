import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/logging/app_log.dart';
import '../../core/net/url_utils.dart';
import '../../core/platform/process_job.dart';
import '../../core/utils/file_url.dart';
import '../../models/site_config.dart';
import '../../models/vod.dart';
import '../movie_parser.dart';
import '../play_result_parser.dart';
import '../runtime_extension.dart';
import '../drive/drive_ext.dart';
import 'py_runtime.dart';

/// 蜘蛛 `localProxy` 的返回值（状态码 / 类型 / 正文 / 响应头）。
class SpiderProxyResult {
  const SpiderProxyResult({
    required this.status,
    required this.contentType,
    required this.body,
    this.headers = const {},
  });

  final int status;
  final String contentType;
  final String body;
  final Map<String, String> headers;

  String header(String name) {
    final key = name.toLowerCase();
    for (final e in headers.entries) {
      if (e.key.toLowerCase() == key) return e.value;
    }
    return '';
  }
}

/// 一次性 / 常驻调用共用的准备结果。
///
/// Android 走 Chaquopy 进程内调用，没有可执行文件，[exe] 为空。
typedef _PyReady = ({
  Directory dir,
  String exe,
  File script,
  String cls,
  String ext,
});

/// TVBox Python 蜘蛛（type=3，api 以 .py 结尾）。
///
/// 脚本下载到本地缓存：
/// - Windows：交给随包 runner.py + 按需下载的嵌入式 Python 进程执行；
/// - Android：交给 Chaquopy 内置的 CPython，在应用进程内执行同一份 runner.py。
class PySpiderService {
  PySpiderService({PyRuntime? runtime, this.driveTokens})
    : _runtimeOverride = runtime;

  final PyRuntime? _runtimeOverride;
  PyRuntime get runtime => _runtimeOverride ?? PyRuntime.instance;
  final Map<String, String> Function()? driveTokens;
  final Map<String, File> _scripts = {};

  /// Android 端进程内 Python 宿主（Chaquopy，见 PythonHostPlugin.kt）。
  static const _androidChannel = MethodChannel('com.kniephos.kniephos/python');

  static bool get _isAndroid => Platform.isAndroid;

  /// 播放期常驻的 Python 进程 / 实例（`runner.py --hold`）：脚本自带的本机取流服务是
  /// 进程内 daemon 线程，一次性进程拿到地址就退出会让播放器直接连接失败。
  _PyHost? _playHost;

  Future<CmsResult> home(SourceBean site) async {
    final text = await _invoke(site, 'homeContent', const []);
    _throwIfError(text);
    var items = MovieParser.toItems(
      MovieParser.parseJson(text).movie,
      site.key,
    );
    final classes = MovieParser.parseJson(text).classes;
    if (items.isEmpty) {
      final extra = await _invoke(site, 'homeVideoContent', const []);
      if (extra.trim().isNotEmpty) {
        final body = MovieParser.parseJson(extra);
        final extraItems = MovieParser.toItems(body.movie, site.key);
        if (extraItems.isNotEmpty) items = extraItems;
      }
    }
    if (items.isEmpty && classes.isNotEmpty) {
      try {
        final fallback = await category(site, classes.first.id, '1', const {});
        if (fallback.items.isNotEmpty) {
          return CmsResult(
            classes: classes,
            items: fallback.items,
            page: fallback.page,
            pagecount: fallback.pagecount == 0 ? 1 : fallback.pagecount,
            total: fallback.total == 0 ? fallback.items.length : fallback.total,
            homeFallback: true,
          );
        }
      } catch (_) {
        // 回退失败不影响分类浏览
      }
    }
    final body = MovieParser.parseJson(text);
    return CmsResult(
      classes: classes,
      items: items,
      page: body.movie?.page ?? 0,
      pagecount: body.movie?.pagecount ?? 0,
      total: body.movie?.recordcount ?? 0,
    );
  }

  Future<CmsResult> category(
    SourceBean site,
    String tid,
    String pg,
    Map<String, String> filters,
  ) async {
    final text = await _invoke(site, 'categoryContent', [
      tid,
      pg,
      jsonEncode(filters),
    ]);
    _throwIfError(text);
    if (text.trim().isEmpty) return const CmsResult();
    final body = MovieParser.parseJson(text);
    return CmsResult(
      items: MovieParser.toItems(body.movie, site.key),
      page: body.movie?.page ?? 0,
      pagecount: body.movie?.pagecount ?? 0,
      total: body.movie?.recordcount ?? 0,
    );
  }

  Future<VodDetail?> detail(SourceBean site, String id) async {
    final text = await _invoke(site, 'detailContent', [
      jsonEncode([id]),
    ]);
    _throwIfError(text);
    if (text.trim().isEmpty) return null;
    final body = MovieParser.parseJson(text);
    return MovieParser.toDetail(body.movie, site.key);
  }

  Future<List<VodItem>> search(SourceBean site, String keyword) async {
    final text = await _invoke(site, 'searchContent', [keyword, '', '1']);
    _throwIfError(text);
    if (text.trim().isEmpty) return const [];
    final body = MovieParser.parseJson(text);
    return MovieParser.toItems(body.movie, site.key);
  }

  Future<PlayResult?> play(
    SourceBean site,
    String flag,
    String id, {
    List<String> vipFlags = const [],
  }) async {
    // 旧的一集可能还挂着一只 Python 取流进程，先回收再起新的（端口也会复用）。
    await _releasePlayHost();
    final text = await _invokeHold(site, 'playerContent', [
      flag,
      id,
      jsonEncode(vipFlags),
    ]);
    if (text.trim().isEmpty) {
      await _releasePlayHost();
      return null;
    }
    final result = normalizeSpiderPlay(text, flag);
    // 只有指向脚本本机取流服务的地址依赖这只进程；直链 / 解析页立即释放。
    if (!_isLocalStreamUrl(result.url)) await _releasePlayHost();
    return result;
  }

  /// 应用退出：直接结束常驻取流进程 / 实例，不等脚本自己收尾。
  Future<void> shutdown() async {
    final host = _playHost;
    _playHost = null;
    await host?.killNow();
    if (_isAndroid) {
      try {
        await _androidChannel
            .invokeMethod('releaseAll')
            .timeout(const Duration(seconds: 2));
      } catch (_) {
        // 通道已销毁（应用退出最后阶段）或 Python 卡住时忽略
      }
    }
  }

  /// 播放地址是否指向 PY 脚本自己起的本机取流服务。
  static bool _isLocalStreamUrl(String url) {
    final host = Uri.tryParse(url.trim())?.host.toLowerCase() ?? '';
    return host == '127.0.0.1' ||
        host == 'localhost' ||
        host == '::1' ||
        host == '0.0.0.0';
  }

  /// 调用蜘蛛的 liveContent(url)，返回直播订阅原文。
  Future<String> live(SourceBean site, String url) async {
    final text = await _invoke(site, 'liveContent', [url]);
    _throwIfError(text);
    return text;
  }

  /// 调用蜘蛛的 localProxy(param)：直播频道地址多为 `/proxy?do=py&...`，
  /// 由蜘蛛在点击时返回 302 Location（动态签名 / 授权）。
  Future<SpiderProxyResult> proxy(
    SourceBean site,
    Map<String, String> params,
  ) async {
    final text = await _invoke(site, 'proxy', [jsonEncode(params)]);
    if (text.trim().isEmpty) {
      throw SourceException('直播蜘蛛没有返回代理结果');
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      throw SourceException('直播蜘蛛返回的代理结果无法解析');
    }
    if (decoded is! List || decoded.isEmpty) {
      throw SourceException('直播蜘蛛返回的代理结果格式错误');
    }
    final status = decoded[0] is num
        ? (decoded[0] as num).toInt()
        : int.tryParse('${decoded[0]}') ?? 200;
    final contentType = decoded.length > 1 ? '${decoded[1]}' : 'text/plain';
    var body = decoded.length > 2 ? decoded[2] : '';
    if (body is Map && body['base64'] != null) {
      try {
        body = utf8.decode(base64Decode('${body['base64']}'));
      } catch (_) {
        body = '';
      }
    }
    final headers = decoded.length > 3 && decoded[3] is Map
        ? (decoded[3] as Map).map(
            (k, v) => MapEntry(k.toString(), v.toString()),
          )
        : const <String, String>{};
    return SpiderProxyResult(
      status: status,
      contentType: contentType,
      body: '$body',
      headers: headers,
    );
  }

  // ---------------------------------------------------------------------------
  // 脚本缓存 / 进程调用
  // ---------------------------------------------------------------------------
  Future<File> _scriptFile(SourceBean site) async {
    final cached = _scripts[site.api];
    if (cached != null && cached.existsSync()) return cached;
    final base = _baseApi(site.api);
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'python_cache'));
    dir.createSync(recursive: true);
    final name = crypto.md5.convert(utf8.encode(base)).toString();
    final file = File(p.join(dir.path, '$name.py'));

    if (base.startsWith('file://')) {
      final path = filePathOf(base);
      final local = File(path);
      if (!local.existsSync()) throw SourceException('本地 .py 蜘蛛不存在：$path');
      _scripts[site.api] = local;
      return local;
    }

    // 远程脚本每次应用会话首次使用时都回源一次：源站可能替换了同一 URL 上的
    // 修复版脚本，不能再无条件复用旧磁盘缓存。回源失败才退回旧缓存，离线仍可用。
    final hasCache = file.existsSync() && file.lengthSync() > 8;
    final candidates = <String>[
      base,
      // 有缓存时只打原站，避免离线启动时为每个候选域名各等一次超时。
      if (!hasCache) ...githubMirrorUrls(normalizeHostUrl(base)),
    ];
    SourceException? lastError;
    for (final candidate in candidates) {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 6);
      try {
        final req = await client.getUrl(Uri.parse(normalizeHostUrl(candidate)));
        req.headers.set('User-Agent', 'okhttp/4.12.0');
        final res = await req.close();
        if (res.statusCode != 200) {
          await res.drain<void>();
          throw SourceException('PY 蜘蛛脚本下载失败（HTTP ${res.statusCode}）');
        }
        final bytes = await res.fold<List<int>>(
          <int>[],
          (acc, chunk) => acc..addAll(chunk),
        );
        if (bytes.length < 8) {
          throw SourceException('PY 蜘蛛脚本内容为空，源可能已失效');
        }
        final text = utf8.decode(bytes, allowMalformed: true);
        if (!RegExp(r'\bclass\s+\w+').hasMatch(text)) {
          throw SourceException('下载内容不是 PY 蜘蛛脚本');
        }
        file.writeAsBytesSync(bytes);
        _scripts[site.api] = file;
        return file;
      } on SourceException catch (e) {
        lastError = e;
      } catch (e) {
        lastError = SourceException('PY 蜘蛛脚本下载失败：$e');
      } finally {
        client.close(force: true);
      }
    }
    if (file.existsSync() && file.lengthSync() > 8) {
      _scripts[site.api] = file;
      return file;
    }
    throw lastError ?? SourceException('PY 蜘蛛脚本下载失败');
  }

  /// 订阅刷新 / 站点地址被编辑后丢掉本次会话的脚本缓存，下次使用会重新回源。
  void clearScriptCache() {
    _scripts.clear();
  }

  String _baseApi(String api) {
    final idx = api.indexOf('?');
    return idx >= 0 ? api.substring(0, idx) : api;
  }

  String _className(String api) {
    final idx = api.indexOf('?');
    if (idx < 0) return 'Spider';
    try {
      final query = Uri.splitQueryString(api.substring(idx + 1));
      final name = query['name'] ?? query['class'];
      if (name != null && name.trim().isNotEmpty) return name.trim();
    } catch (_) {
      // 查询串解析失败就用默认类名
    }
    return 'Spider';
  }

  /// 运行时 / 脚本 / 类名等公共准备（一次性调用与常驻取流共用）。
  Future<_PyReady> _prepare(SourceBean site) async {
    if (!await runtime.installed()) {
      final result = await RuntimeInstallPrompt.instance.ensure(
        RuntimeExtension.python,
      );
      if (result != RuntimePromptResult.ready) {
        throw SourceException(result.messageFor(RuntimeExtension.python));
      }
    }
    // 老版本装的运行时缺少 self.net / typing_extensions：升级后第一次调用时原地补齐。
    try {
      await runtime.ensurePatched();
    } catch (_) {
      // 离线补齐失败时继续用旧运行时，源会给出明确的缺少库/属性错误
    }
    final dir = await runtime.directory();
    final script = await _scriptFile(site);
    final cls = _className(site.api);
    final ext = enrichSpiderExt(site.ext, driveTokens?.call() ?? const {});
    if (_isAndroid) {
      // Chaquopy 内置解释器：没有 python.exe，runnerDir 由 Kotlin 侧加进 sys.path。
      return (dir: dir, exe: '', script: script, cls: cls, ext: ext);
    }
    final exe = p.join(dir.path, 'python.exe');
    if (!File(exe).existsSync()) {
      throw SourceException('Python 运行时缺少 python.exe，请在设置中重新安装');
    }
    return (dir: dir, exe: exe, script: script, cls: cls, ext: ext);
  }

  Map<String, String> _environment() => {
    // 直连模式：不再注入 ProxyRuntime.pythonEnv（HTTP_PROXY 等一律不设），
    // Python 蜘蛛直接出网，与 Win-box 行为一致。
    ...Platform.environment,
    'PYTHONIOENCODING': 'utf-8',
    'PYTHONUTF8': '1',
  };

  Future<String> _invoke(
    SourceBean site,
    String method,
    List<String> args,
  ) async {
    final ready = await _prepare(site);
    if (_isAndroid) {
      return _invokeAndroid(
        ready,
        method,
        args,
        Duration(seconds: site.timeout + 30),
      );
    }
    final arguments = <String>[
      '-X',
      'utf8',
      'runner.py',
      ready.script.path,
      ready.cls,
      method,
      ready.ext,
      ...args,
    ];
    try {
      final result = await Process.run(
        ready.exe,
        arguments,
        workingDirectory: ready.dir.path,
        environment: _environment(),
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(Duration(seconds: site.timeout + 30));
      final stdoutText = (result.stdout as String?)?.trim() ?? '';
      if (result.exitCode != 0) {
        throw SourceException(
          _errorText(stdoutText, (result.stderr as String?) ?? ''),
        );
      }
      if (stdoutText.isEmpty) {
        throw SourceException(_errorText('', (result.stderr as String?) ?? ''));
      }
      return stdoutText;
    } on TimeoutException {
      throw SourceException('PY 蜘蛛执行超时（$method）');
    } on ProcessException catch (e) {
      throw SourceException('Python 运行时启动失败：${e.message}');
    }
  }

  /// Android：调用 Chaquopy 进程内 runner（返回值是 runner.py 的统一信封）。
  Future<String> _invokeAndroid(
    _PyReady ready,
    String method,
    List<String> args,
    Duration timeout,
  ) => _androidInvoke('call', {
    'runnerDir': ready.dir.path,
    'script': ready.script.path,
    'className': ready.cls,
    'method': method,
    'ext': ready.ext,
    'argsJson': jsonEncode(args),
  }, timeout: timeout);

  /// Android：常驻一次播放调用。实例留在 Python 侧，脚本的本机取流线程继续活着。
  Future<String> _invokeHoldAndroid(
    SourceBean site,
    _PyReady ready,
    String method,
    List<String> args,
  ) async {
    final key = '${site.key}\u0000${site.api}';
    final text = await _androidInvoke('hold', {
      'key': key,
      'runnerDir': ready.dir.path,
      'script': ready.script.path,
      'className': ready.cls,
      'method': method,
      'ext': ready.ext,
      'argsJson': jsonEncode(args),
    }, timeout: Duration(seconds: site.timeout + 30));
    _playHost = _PyAndroidPlayHost(key, text);
    AppLog.i('py', '--hold 就绪（Android）method=$method key=${site.key}');
    return text;
  }

  Future<String> _androidInvoke(
    String method,
    Map<String, Object?> args, {
    required Duration timeout,
  }) async {
    try {
      final raw = await _androidChannel
          .invokeMethod<String>(method, args)
          .timeout(timeout);
      if (raw == null || raw.trim().isEmpty) {
        throw SourceException('Python 运行时没有返回结果');
      }
      dynamic decoded;
      try {
        decoded = jsonDecode(raw);
      } catch (_) {
        throw SourceException('Python 运行时返回格式错误');
      }
      if (decoded is! Map || decoded['ok'] != true) {
        final error = decoded is Map ? '${decoded['error'] ?? ''}' : '';
        throw SourceException(_errorText('', error));
      }
      return '${decoded['data'] ?? ''}';
    } on TimeoutException {
      throw SourceException('PY 蜘蛛执行超时（$method）');
    } on MissingPluginException {
      throw SourceException('Python 运行时未初始化（Android 内置运行库缺失）');
    } on PlatformException catch (e) {
      throw SourceException(_errorText('', e.message ?? e.code));
    }
  }

  /// 常驻取流：`runner.py --hold` 返回一次结果后继续活着，供脚本内建的本机流服务取流。
  Future<String> _invokeHold(
    SourceBean site,
    String method,
    List<String> args,
  ) async {
    final ready = await _prepare(site);
    if (_isAndroid) return _invokeHoldAndroid(site, ready, method, args);
    final host = await _PyPlayHost.start(
      exe: ready.exe,
      argv: [
        '-X',
        'utf8',
        'runner.py',
        '--hold',
        ready.script.path,
        ready.cls,
        method,
        ready.ext,
        ...args,
      ],
      workingDirectory: ready.dir.path,
      environment: _environment(),
    );
    try {
      final text = await host.firstResult(Duration(seconds: site.timeout + 30));
      AppLog.i('py', '--hold 就绪 method=$method pid=${host.pid}');
      _playHost = host;
      return text;
    } catch (e) {
      final tail = host.errorTail;
      await host.close();
      final friendly = tail.trim().isEmpty ? '$e' : _errorText('', tail);
      AppLog.w('py', '--hold 失败 method=$method: $friendly');
      throw SourceException(friendly);
    }
  }

  /// 播放结束 / 换集：关掉上一只常驻进程。
  Future<void> _releasePlayHost() async {
    final host = _playHost;
    _playHost = null;
    await host?.close();
  }

  String _errorText(String stdout, String stderr) {
    final text = '${stderr.trim()}\n${stdout.trim()}'.trim();
    if (text.isEmpty) return 'PY 蜘蛛执行失败';
    final module = RegExp(r"No module named '([^']+)'").firstMatch(text);
    if (module != null) {
      return '该 PY 蜘蛛缺少第三方库「${module.group(1)}」';
    }
    final lines = text
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    for (final line in lines) {
      if (line.contains('[SpiderRunner.ERROR]')) {
        return line.replaceFirst('[SpiderRunner.ERROR]', '').trim();
      }
    }
    return lines.isEmpty ? text : lines.last;
  }

  void _throwIfError(String text) {
    final t = text.trim();
    if (!t.startsWith('{')) return;
    try {
      final decoded = jsonDecode(t);
      if (decoded is Map && decoded['__error'] != null) {
        throw SourceException('蜘蛛返回错误：${decoded['__error']}');
      }
    } on SourceException {
      rethrow;
    } catch (_) {
      // 非 JSON 文本交给上层解析
    }
  }
}

/// 常驻播放宿主：Windows 是外部 Python 进程，Android 是 Chaquopy 进程内实例。
abstract class _PyHost {
  Future<String> firstResult(Duration timeout);
  Future<void> close();
  Future<void> killNow();
}

/// `runner.py --hold` 的常驻进程：先取一次结果，之后保持 Python 存活。
///
/// 与 JAR 的 `SpiderHost --hold` 同理：脚本把播放地址指向自己起的本机取流服务，
/// 进程一退端口就失效；宿主写 `quit` 或关闭 stdin 后进程自行结束。
class _PyPlayHost implements _PyHost {
  _PyPlayHost._(this.process, this._stdin, this._stdout, this._stderr);

  final Process process;
  final IOSink _stdin;
  final Stream<String> _stdout;
  final Stream<String> _stderr;

  final List<String> _errors = [];
  StreamSubscription<String>? _errSub;
  bool _closed = false;

  int get pid => process.pid;
  String get errorTail => _errors.join('\n');

  static Future<_PyPlayHost> start({
    required String exe,
    required List<String> argv,
    required String workingDirectory,
    required Map<String, String> environment,
  }) async {
    final process = await Process.start(
      exe,
      argv,
      workingDirectory: workingDirectory,
      environment: environment,
    );
    final host = _PyPlayHost._(
      process,
      process.stdin,
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      process.stderr.transform(utf8.decoder).transform(const LineSplitter()),
    );
    host._errSub = host._stderr.listen((line) {
      if (host._errors.length > 40) host._errors.removeAt(0);
      host._errors.add(line);
    }, onError: (Object _) {});
    // 监听器挂好后再收养，避免 MethodChannel 调用期间管道数据积压。
    await ProcessJob.adopt(process.pid);
    return host;
  }

  /// 读第一行结果（`runner.py --hold` 先打印结果，再挂住等 stdin）。
  @override
  Future<String> firstResult(Duration timeout) async {
    try {
      final line = await _stdout.first.timeout(timeout);
      return line.trim();
    } on TimeoutException {
      await close();
      throw TimeoutException('Python 取流进程超时未返回');
    } on StateError {
      await close();
      throw StateError('Python 取流进程无输出（可能已崩溃）');
    }
  }

  /// 播放结束 / 换集：让 Python 自行退出（写 quit → stdin 读完即结束）。
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      _stdin.writeln('quit');
      await _stdin.flush().timeout(const Duration(milliseconds: 500));
    } catch (_) {}
    try {
      await process.exitCode.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      try {
        process.kill();
      } catch (_) {}
    }
    await _errSub?.cancel();
  }

  /// 应用退出：不留给脚本收尾的时间，直接结束进程。
  @override
  Future<void> killNow() async {
    if (_closed) return;
    _closed = true;
    try {
      process.kill();
    } catch (_) {}
    await _errSub?.cancel();
  }
}

/// Android 常驻播放：结果已经由 `hold` 调用返回，宿主只需记住 key。
///
/// 释放时让 Python 侧丢弃蜘蛛实例（并尽量调 destroy）；脚本自己的取流线程
/// 与 Chaquopy 解释器同在一个应用进程里，不能像 Windows 那样靠杀进程回收。
class _PyAndroidPlayHost implements _PyHost {
  _PyAndroidPlayHost(this.key, this._result);

  final String key;
  final String _result;
  bool _released = false;

  @override
  Future<String> firstResult(Duration timeout) async => _result;

  @override
  Future<void> close() => _release();

  @override
  Future<void> killNow() => _release();

  Future<void> _release() async {
    if (_released) return;
    _released = true;
    try {
      await PySpiderService._androidChannel
          .invokeMethod('release', {'key': key})
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      // 通道已销毁（应用退出最后阶段）或 Python 卡住时忽略
    }
  }
}
