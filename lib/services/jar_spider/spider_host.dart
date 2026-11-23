import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/platform/process_job.dart';

/// 折叠 JVM stderr 里的 Java 堆栈，并给重复异常降频。
///
/// 加固载荷里大量 `catch (Exception e) { e.printStackTrace(); }`，一条异常
/// 会刷 15–25 行；这些异常通常已被载荷自己捕获，数据不受影响。这里只压缩
/// 诊断显示（`errorTail`），首行与次数仍保留，不影响归因。
class JvmStderrFilter {
  JvmStderrFilter({this.spamThreshold = 20});

  final int spamThreshold;

  /// 异常首行 → 次数。首行常带 URL / id，按上限淘汰，淘汰只会让计数重来。
  final Map<String, int> _counts = <String, int>{};
  static const int _maxHeaders = 256;

  String? _header;
  int _frames = 0;
  String? _lastMeaningful;

  /// 最近一条有意义的 stderr（堆栈场景取首行）。
  String? get lastMeaningfulLine => _lastMeaningful;

  /// 喂入一行，返回需要保留的行（0 行 = 被折叠）。
  List<String> feed(String line) {
    if (_isJvmNoise(line)) return const <String>[];
    if (_header != null) {
      if (_isContinuation(line)) {
        _frames++;
        return const <String>[];
      }
      final closed = _closeBlock();
      return <String>[...closed, ...feed(line)];
    }
    if (_isHeader(line)) {
      _header = line;
      _frames = 0;
      _lastMeaningful = line;
      return const <String>[];
    }
    _lastMeaningful = line;
    return <String>[line];
  }

  /// 流结束（子进程退出）时冲掉未闭合的堆栈块。
  List<String> flush() => _header == null ? const <String>[] : _closeBlock();

  List<String> _closeBlock() {
    final header = _header!;
    final frames = _frames;
    _header = null;
    _frames = 0;

    final nth = (_counts[header] ?? 0) + 1;
    if (_counts.length >= _maxHeaders && !_counts.containsKey(header)) {
      _counts.remove(_counts.keys.first);
    }
    _counts[header] = nth;
    if (nth > spamThreshold && nth % spamThreshold != 0) {
      return const <String>[];
    }

    final buffer = StringBuffer(header);
    final details = <String>[
      if (frames > 0) '堆栈 $frames 行已折叠',
      if (nth > 1) '同类第 $nth 次',
    ];
    if (details.isNotEmpty) buffer.write('（${details.join('；')}）');
    return <String>[buffer.toString()];
  }

  static final RegExp _headerPattern = RegExp(
    r'^(?:Caused by:\s*)?(?:[A-Za-z_$][\w$]*\.)+[A-Za-z_$][\w$]*(?:Exception|Error)(?::.*)?$',
  );
  static final RegExp _threadHeaderPattern = RegExp(
    r'^Exception in thread "[^"]*"\s+(?:[A-Za-z_$][\w$]*\.)+[A-Za-z_$][\w$]*(?:Exception|Error)(?::.*)?$',
  );
  static final RegExp _framePattern = RegExp(r'^\s+at\s+\S');
  static final RegExp _morePattern = RegExp(r'^\s*\.\.\.\s+\d+\s+more\s*$');
  static final RegExp _causePattern = RegExp(r'^\s*Caused by:\s*\S');
  static final RegExp _suppressedPattern = RegExp(r'^\s*Suppressed:\s*\S');

  static bool _isHeader(String line) =>
      _headerPattern.hasMatch(line) || _threadHeaderPattern.hasMatch(line);

  static bool _isContinuation(String line) =>
      _framePattern.hasMatch(line) ||
      _morePattern.hasMatch(line) ||
      _causePattern.hasMatch(line) ||
      _suppressedPattern.hasMatch(line);

  /// JVM 自身的启动告警（`-noverify` 弃用、SecurityManager 弃用），
  /// 与站源无关，不进入 errorTail。
  static bool _isJvmNoise(String line) =>
      line.startsWith('OpenJDK 64-Bit Server VM warning') ||
      line.contains('-noverify were deprecated') ||
      line.startsWith('WARNING: System::setSecurityManager') ||
      line.startsWith(
        'WARNING: Please consider reporting this to the maintainers',
      );
}

/// 常驻取流进程：跑**一次**蜘蛛调用后不退出，把壳内的取流服务/宿主代理留在内存里。
///
/// 为什么必须常驻：加固壳源的 `playerContent` 返回的播放地址是**本机、且指向该 JVM**的：
///   · `http://127.0.0.1:<壳内端口>/chunk?id=…&thread=32&chunk=64` —— 壳自己的多线程取流服务；
///   · `http://127.0.0.1:<pp>/proxy?...` —— 宿主代理（`-Dtvbox.proxy.port`）。
/// 一次性进程打完结果就 `System.exit`，地址随即失效；所以播放链路必须让 JVM 活着，
/// 直到播放器关掉这一集（宿主写 `quit` 或关闭 stdin）。
///
/// 与浏览路径（`SpiderRunner` 一次性调用）的关系：浏览走一次性（快、无状态），
/// 只有真正要播的时候才拉起常驻进程，避免长期占用内存。
class JarSpiderHost {
  JarSpiderHost._(this._process, this._stdin, this._stdout, this._stderr);

  final Process _process;
  final IOSink _stdin;
  final Stream<String> _stdout;
  final Stream<String> _stderr;

  final List<String> _errors = [];
  final JvmStderrFilter _stderrFilter = JvmStderrFilter();
  StreamSubscription<String>? _errSub;
  bool _closed = false;
  bool _exited = false;

  /// 宿主代理实际端口（`-Dtvbox.proxy.port`；壳返回的 `do=pan` / `do=proxy` 地址要按它对齐）。
  int proxyPort = 0;

  /// 进程是否还活着（壳内守护线程退出/被杀时为 false）。
  bool get alive => !_closed && !_exited;

  int get pid => _process.pid;

  /// stderr 尾部（诊断用）。
  String get errorTail => _errors.join('\n');

  /// 拉起一个常驻进程并完成**第一次（也是唯一一次）**调用，返回结果 JSON 文本。
  ///
  /// [argv] 由调用方组装（含 `--hold`），这里只负责管道与生命周期。
  static Future<JarSpiderHost> start({
    required String java,
    required List<String> argv,
    required Duration timeout,
  }) async {
    final process = await Process.start(java, argv);
    final host = JarSpiderHost._(
      process,
      process.stdin,
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      process.stderr.transform(utf8.decoder).transform(const LineSplitter()),
    );
    host._errSub = host._stderr.listen((line) {
      final actual = hostProxyPortOf(line);
      if (actual != null) host.proxyPort = actual;
      for (final out in host._stderrFilter.feed(line)) {
        if (host._errors.length > 60) host._errors.removeAt(0);
        host._errors.add(out);
      }
    }, onError: (Object _) {});
    unawaited(process.exitCode.then((_) {
      host._exited = true;
      for (final out in host._stderrFilter.flush()) {
        if (host._errors.length > 60) host._errors.removeAt(0);
        host._errors.add(out);
      }
    }, onError: (Object _) {}));
    // 监听器挂好后再收养：MethodChannel 调用期间 JVM 可能已经在写启动日志。
    await ProcessJob.adopt(process.pid);
    return host;
  }

  /// 读第一行结果（`SpiderHost --hold` 在挂住之前会先 println + flush）。
  Future<String> firstResult(Duration timeout) async {
    try {
      final line = await _stdout.first.timeout(timeout);
      return line.trim();
    } on TimeoutException {
      await close();
      throw TimeoutException('常驻取流进程超时未返回');
    } on StateError {
      await close();
      throw StateError('常驻取流进程无输出（可能已崩溃）');
    }
  }

  /// 播放结束：让 JVM 自行退出（写 quit → 主线程收到后 `System.exit`）。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      _stdin.writeln('quit');
      await _stdin.flush().timeout(const Duration(seconds: 2));
      await _stdin.close().timeout(const Duration(seconds: 2));
    } catch (_) {
      // 进程可能已退出
    }
    try {
      await _process.exitCode.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      try {
        _process.kill();
      } catch (_) {}
    }
    await _errSub?.cancel();
  }

  /// 应用退出：不给壳内守护线程留时间，直接结束进程（`TerminateProcess`）。
  ///
  /// 关窗时用这个：等 JVM 自然退出会拖住应用退出，任务管理器里留下 java.exe / kniephos.exe。
  Future<void> killNow() async {
    if (_closed) return;
    _closed = true;
    try {
      _stdin.writeln('quit');
      await _stdin.flush().timeout(const Duration(milliseconds: 300));
    } catch (_) {}
    try {
      _process.kill();
    } catch (_) {}
    try {
      await _process.exitCode.timeout(const Duration(seconds: 2));
    } catch (_) {}
    // 取消流订阅必须带超时：JVM 被 kill 后管道仍可能挂着未读完的数据，
    // 无超时的 cancel() 会永远等下去，把「开始退出清理」卡死在这里。
    try {
      await _errSub?.cancel().timeout(const Duration(milliseconds: 500));
    } catch (_) {}
  }

  static String describe(List<String> errors) {
    final lines = errors
        .where((e) => e.trim().isNotEmpty)
        .where((e) => !e.startsWith('    at '))
        .where((e) => !e.startsWith('[android.'))
        .toList();
    if (lines.isEmpty) return '';
    final err = lines.lastWhere(
      (e) => e.contains('[SpiderHost.ERROR]'),
      orElse: () => lines.last,
    );
    return err.replaceFirst('[SpiderHost.ERROR]', '').trim();
  }
}

class ServeReply {
  const ServeReply({required this.ok, required this.data});
  final bool ok;
  final String data;
}

class ServeHostException implements Exception {
  ServeHostException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 常驻浏览/搜索进程：`SpiderHost --serve <jar>`，stdin 逐行 JSON 请求，stdout 逐行信封应答。
///
/// 相比「每次调用都起一个 JVM」，这里 JVM 启动、jar 类加载、蜘蛛 `init(ext)` 与
/// 实例池只付一次；同一份 jar 的多个站点可以连续复用。Kniephos fork 的 serve 是
/// **主线程顺序执行**（加固壳在池化线程上解析不出站点基址），所以并发度靠多开
/// 少量 host（见 JarSpiderService 的池），而不是单进程多线程。
class JarServeHost {
  JarServeHost._(this._process, this._stdin, this._stdout, this._stderr);

  final Process _process;
  final IOSink _stdin;
  final Stream<String> _stdout;
  final Stream<String> _stderr;

  final Map<String, Completer<ServeReply>> _pending = {};
  final List<String> _errors = [];
  final JvmStderrFilter _stderrFilter = JvmStderrFilter();
  StreamSubscription<String>? _outSub;
  StreamSubscription<String>? _errSub;
  int _seq = 0;
  bool _exited = false;
  bool _closed = false;

  /// 信封里回报的宿主代理端口（`pp`）。
  int proxyPort = 0;

  /// 已发出但尚未收到应答的请求数（含排队中的）。
  int inflight = 0;

  /// 其中属于聚合搜索的请求数。打开详情 / 播放时会优先结束这些请求，
  /// 让交互操作不再排在后台搜索后面。
  int searchInflight = 0;

  /// 最近一次成功应答时间：空闲较久后复用前先做一次轻量健康检查。
  DateTime lastUsedAt = DateTime.now();

  bool get alive => !_closed && !_exited;
  int get pid => _process.pid;
  String get errorTail => _errors.join('\n');

  static Future<JarServeHost> start({
    required String java,
    required List<String> argv,
  }) async {
    final process = await Process.start(java, argv);
    final host = JarServeHost._(
      process,
      process.stdin,
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      process.stderr.transform(utf8.decoder).transform(const LineSplitter()),
    );
    host._outSub = host._stdout.listen(host._onLine, onError: (Object _) {});
    host._errSub = host._stderr.listen((line) {
      final actual = hostProxyPortOf(line);
      if (actual != null) host.proxyPort = actual;
      for (final out in host._stderrFilter.feed(line)) {
        if (host._errors.length > 60) host._errors.removeAt(0);
        host._errors.add(out);
      }
    }, onError: (Object _) {});
    unawaited(process.exitCode.then((_) {
      host._exited = true;
      for (final out in host._stderrFilter.flush()) {
        if (host._errors.length > 60) host._errors.removeAt(0);
        host._errors.add(out);
      }
      host._failAll('常驻蜘蛛进程已退出');
    }, onError: (Object _) {}));
    // 监听器挂好后再收养：MethodChannel 调用期间 JVM 可能已经在写启动日志。
    await ProcessJob.adopt(process.pid);
    return host;
  }

  Future<ServeReply> call({
    required String className,
    required String method,
    required List<String> args,
    required Duration timeout,
  }) async {
    if (!alive) throw ServeHostException('常驻蜘蛛进程已退出');
    final id = 'r${_seq++}';
    final completer = Completer<ServeReply>();
    _pending[id] = completer;
    inflight++;
    try {
      try {
        _stdin.writeln(jsonEncode({
          'id': id,
          'className': className,
          'method': method,
          'args': args,
        }));
        await _stdin.flush();
      } catch (_) {
        // 进程已退出时管道会先断开、exitCode 还没回调：统一按 host 死亡处理，
        // 让上层换候选包 / 回退一次性进程，而不是把 StateError 抛给界面。
        _closed = true;
        try {
          _process.kill();
        } catch (_) {}
        throw ServeHostException('常驻蜘蛛进程已断开');
      }
      final reply = await completer.future.timeout(timeout);
      lastUsedAt = DateTime.now();
      return reply;
    } on TimeoutException {
      // 主线程被卡死的蜘蛛不会自行恢复：直接结束这个 host，后续请求换新进程。
      unawaited(killNow());
      throw ServeHostException('常驻蜘蛛调用超时（$method）');
    } finally {
      _pending.remove(id);
      inflight--;
    }
  }

  /// 轻量健康检查：`__ping__` 在 SpiderHost 里不加载蜘蛛类，只确认进程与
  /// stdin/stdout 管道仍然可用。失败返回 false（超时路径会顺带 kill 本 host）。
  Future<bool> ping({Duration timeout = const Duration(seconds: 2)}) async {
    if (!alive) return false;
    try {
      final reply = await call(
        className: '__ping__',
        method: '__ping__',
        args: const [],
        timeout: timeout,
      );
      return reply.ok;
    } catch (_) {
      return false;
    }
  }

  void _onLine(String line) {
    final text = line.trim();
    if (text.isEmpty) return;
    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return;
    }
    if (decoded is! Map) return;
    final id = (decoded['id'] ?? '').toString();
    final completer = _pending.remove(id);
    if (completer == null || completer.isCompleted) return;
    final pp = decoded['pp'];
    if (pp is num && pp.toInt() > 0) proxyPort = pp.toInt();
    completer.complete(ServeReply(
      ok: decoded['ok'] == true,
      data: (decoded['data'] ?? '').toString(),
    ));
  }

  void _failAll(String message) {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(ServeHostException(message));
    }
    _pending.clear();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      _stdin.writeln('quit');
      await _stdin.flush().timeout(const Duration(seconds: 1));
      await _stdin.close().timeout(const Duration(seconds: 2));
    } catch (_) {}
    try {
      await _process.exitCode.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      try {
        _process.kill();
      } catch (_) {}
    }
    await _outSub?.cancel();
    await _errSub?.cancel();
  }

  Future<void> killNow() async {
    if (_closed) return;
    _closed = true;
    try {
      _stdin.writeln('quit');
      await _stdin.flush().timeout(const Duration(milliseconds: 300));
    } catch (_) {}
    try {
      _process.kill();
    } catch (_) {}
    try {
      await _process.exitCode.timeout(const Duration(seconds: 2));
    } catch (_) {}
    // 同上：流订阅的 cancel 可能挂住，必须限时。
    try {
      await _outSub?.cancel().timeout(const Duration(milliseconds: 500));
    } catch (_) {}
    try {
      await _errSub?.cancel().timeout(const Duration(milliseconds: 500));
    } catch (_) {}
  }
}

/// 从 SpiderHost 的 stderr 里解析宿主代理**实际绑定端口**
/// （`[host-proxy] listening port=<p>`，见 assets/jvm/src/SpiderHost.java）。
///
/// `--hold` 只回一行结果、没有 serve 信封的 `pp` 字段；不读这行的话，
/// `-Dtvbox.proxy.port` 被占用而退化到临时端口时，宿主会把播放地址改写到
/// 那个**没人监听**的期望端口。
int? hostProxyPortOf(String line) {
  const marker = '[host-proxy] listening port=';
  final at = line.indexOf(marker);
  if (at < 0) return null;
  final match = RegExp(r'\d+').firstMatch(line.substring(at + marker.length));
  if (match == null) return null;
  return int.tryParse(match.group(0) ?? '');
}

/// 把加固壳返回的本机地址对齐到**当前** JVM 的端口。
///
/// 壳会按 `-Dtvbox.proxy.entry` 拼地址（旧版 Electron 宿主是 `http://127.0.0.1:9978/proxy/<port>`）；
/// 我们让入口直接指向 JVM 自己（`http://127.0.0.1:<port>/proxy`），但壳自己也可能吐出
/// 9978 / `-1` 这类「宿主端口」形态 —— 这里统一改写到本 JVM，否则播放器打过去是 ECONNREFUSED。
String rewriteLocalProxy(String url, int proxyPort) {
  if (proxyPort <= 0 || url.isEmpty) return url;
  final match = RegExp(
    r'^(https?://(?:127\.0\.0\.1|localhost)):(-?\d+)(/proxy/\d+|/proxy)?',
  ).firstMatch(url);
  if (match == null) return url;
  final port = int.tryParse(match.group(2) ?? '') ?? 0;
  if (port == proxyPort) {
    final tail = match.group(3) ?? '';
    if (tail.startsWith('/proxy/')) {
      return 'http://127.0.0.1:$proxyPort/proxy${url.substring(match.end)}';
    }
    return url;
  }
  // 只改「宿主端口」形态：9978（旧桌面宿主）与 -1 / 0（壳的占位值）。
  // 壳在找不到宿主代理时会直接吐 -1（`127.0.0.1:-1/proxy?...`），负号必须
  // 用 `-?\d+` 才能匹配；否则播放器拿到非法端口只会报
  // "invalid or unsupported media"。
  if (port != 9978 && port > 0) return url;
  // 只接管 /proxy 路由（group 3）；壳自己的 /chunk 等路径保持原样。
  if (match.group(3) == null) return url;
  final tail = url.substring(match.end);
  return 'http://127.0.0.1:$proxyPort/proxy$tail';
}

/// 从壳返回的播放 JSON 里挑出可播地址（`url` 支持数组形态）。
String pickPlayUrl(String rawJson) {
  try {
    final decoded = jsonDecode(rawJson);
    if (decoded is! Map) return '';
    final url = decoded['url'];
    if (url is List) {
      for (final item in url) {
        final text = '${item ?? ''}'.trim();
        if (text.isNotEmpty) return text;
      }
      return '';
    }
    return '${url ?? ''}'.trim();
  } catch (_) {
    return '';
  }
}