# -*- coding: utf-8 -*-
# PythonRunner 的 CPython3 等价实现（桌面版 .py 蜘蛛运行时）。
#
# argv 契约与 resources/jvm/PythonRunner.java 完全一致（供 JarSpiderBridge.callPython 复用解析）：
#   runner.py <pyPath> <className> <method> [ext] [args...]
#    - argv[0] 一定是本脚本的绝对路径（spawn python.exe runner.py ...）
#    - [ext] 喂给 init()（首个可调用实参，可缺省）
#    - 之后按方法签名取实参（categoryContent/detailContent/searchContent/playerContent 等）
#
# 输出协议（与 Jython 版一致，bridge 的 extractSpiderReason / [SpiderRunner.ERROR] 提取零改动）：
#   - 正常：结果 json.dumps 到 stdout
#   - 失败：`[SpiderRunner.ERROR] <type>: <msg>` + traceback 到 stderr，退出码 1
#
# ★ 嵌入式 Python（python-3.11.x-embed-amd64）的 python311._pth 是只读隔离的：
#   不加载 site-packages、忽略 PYTHONPATH。因此这里**必须**用绝对路径手动注入 sys.path：
#   [pythonDir/Lib, pythonDir/Lib/site-packages, runnerDir/base, 脚本所在目录]
#   （pythonDir = runner.py 所在目录；embed 包结构为 python.exe + python311.zip + Lib/）。

import json
import os
import sys
import traceback
import inspect
import base64
import threading

# ---- 1. sys.path 注入（必须在 import 第三方库/脚本之前） ----
def _dir_of(p):
    return os.path.dirname(os.path.abspath(p))

# 以 runner.py 自身位置为准：桌面端是 `python runner.py`（argv[0] = 脚本路径），
# 安卓端是 Chaquopy 从应用私有目录 `import runner`，两种情况下 __file__ 都指向本文件。
RUNNER_DIR = _dir_of(__file__)
PY_DIR = RUNNER_DIR  # embed 包：runner.py 与 python.exe 同目录
# runner 落盘目录即为 embed 根目录（python.exe + python311.zip + Lib/ + base/ 同层），
# 因此把 PY_DIR 本身加入 sys.path 即可让 `import base.spider`（base/ 子目录）命中；
# Lib 与 site-packages 也一并显式注入（embed 的 _pth 隔离不自动加载）。
for _p in [
    PY_DIR,
    os.path.join(PY_DIR, 'Lib'),
    os.path.join(PY_DIR, 'Lib', 'site-packages'),
]:
    if os.path.isdir(_p) and _p not in sys.path:
        sys.path.insert(0, _p)

# ★ stdout 专供「结果/信封」：蜘蛛自己的 print()（base.spider.log 等）会与结果/信封
#   拼进同一行 → 宿主侧按行分帧解析失败 → 常驻池挂起到超时（用户侧「半天搜不出来」）。
#   这里先抓住真正的 stdout 句柄，main() 里再把 sys.stdout 换成 stderr。
_REAL_OUT = sys.stdout


def _windows_ca_bundle():
    """Requests uses certifi alone; include Windows-trusted server CAs without disabling TLS verification."""
    if os.name != 'nt' or os.environ.get('REQUESTS_CA_BUNDLE'):
        return
    try:
        import ssl
        import certifi
        with open(certifi.where(), 'rb') as f:
            pem = f.read() + b'\n'
        for store in ('ROOT', 'CA'):
            for cert, encoding, trust in ssl.enum_certificates(store):
                if encoding == 'x509_asn' and (trust is True or '1.3.6.1.5.5.7.3.1' in trust):
                    pem += ssl.DER_cert_to_PEM_cert(cert).encode('ascii')
        path = os.path.join(PY_DIR, 'windows-ca.pem')
        existing = b''
        if os.path.exists(path):
            with open(path, 'rb') as f:
                existing = f.read()
        if existing != pem:
            tmp = path + '.' + str(os.getpid())
            with open(tmp, 'wb') as f:
                f.write(pem)
            os.replace(tmp, path)
        os.environ['REQUESTS_CA_BUNDLE'] = path
    except (ImportError, OSError):
        pass  # Keep certifi verification if the optional Windows store cannot be read.


def _fail(err):
    sys.stderr.write('[SpiderRunner.ERROR] %s: %s\n' % (type(err).__name__, err))
    traceback.print_exc(file=sys.stderr)
    sys.exit(1)


def _invoke(sp, name, *args):
    fn = getattr(sp, name, None)
    if fn is None:
        raise AttributeError('method not found: %s' % name)
    return fn(*args)


def _invoke_variants(sp, name, variants):
    fn = getattr(sp, name, None)
    if fn is None:
        raise AttributeError('method not found: %s' % name)
    signature = inspect.signature(fn)
    for args in variants:
        try:
            signature.bind(*args)
        except TypeError:
            continue
        # Do not retry a TypeError raised inside the source itself.
        return fn(*args)
    raise TypeError('unsupported signature for %s: %s' % (name, signature))


# 部分直播蜘蛛在 homeContent 里用 process_douyu / process_bili 预热分类数据，
# 数据只存在当前进程；分类页是另一个一次性进程，必须按平台重新预热。
_PLATFORM_STATE = (
    ('douyu', 'dyufdata', 'process_douyu'),
    ('bili', 'blfdata', 'process_bili'),
    ('douyin', 'dyifdata', 'process_douyin'),
    ('kugou', 'kgdata', 'process_kugou'),
    ('ks', 'ksdata', 'process_ks'),
)


def _ensure_platform_state(sp, tid, extend):
    """分类页依赖首页预热的平台数据时，在当前进程重新拉一次。"""
    if not isinstance(extend, dict) or not extend.get('cate'):
        return
    text = str(tid or '').lower()
    if 'click' in text:
        return
    for key, attr, method in _PLATFORM_STATE:
        if key not in text:
            continue
        if hasattr(sp, attr):
            return
        fn = getattr(sp, method, None)
        if fn is None:
            return
        try:
            fn()
        except Exception:
            # 预热失败由源自己的错误处理决定，不阻断分类调用
            pass
        return


def _load_script(py_path):
    """读取并编译 py 脚本一次，返回其模块命名空间（脚本目录注入 sys.path）。"""
    script_dir = _dir_of(py_path)
    if script_dir not in sys.path:
        sys.path.insert(0, script_dir)
    ns = {'__file__': os.path.abspath(py_path), '__name__': 'winbox_spider'}
    with open(py_path, 'r', encoding='utf-8-sig') as f:
        src = f.read()
    exec(compile(src, py_path, 'exec'), ns)
    return ns


def _new_instance(ns, class_name):
    cls = ns.get(class_name)
    if cls is None:
        raise SystemExit('Python 类不存在: %s' % class_name)
    return cls()


def _call_method(sp, method, rest):
    """方法分派（对齐 Jython PythonRunner.java）。rest 为实参数组（下标 0 起即方法参数，与 argv 中 [ext] 之后对齐）。"""
    if method == 'homeContent':
        return _invoke_variants(sp, 'homeContent', [(True,), ()])
    if method == 'homeVideoContent':
        return _invoke(sp, 'homeVideoContent')
    if method == 'categoryContent':
        tid = rest[0] if len(rest) > 0 else ''
        pg = rest[1] if len(rest) > 1 else '1'
        extend = rest[2] if len(rest) > 2 else '{}'
        try:
            extend_obj = json.loads(extend) if extend else {}
        except (ValueError, TypeError):
            extend_obj = {}
        _ensure_platform_state(sp, tid, extend_obj)
        try:
            return _invoke(sp, 'categoryContent', tid, (pg or '1'), True, extend_obj)
        except AttributeError as error:
            # 平台预热仍然失败时（接口被风控/临时超时），返回空分类而不是整页报错。
            if any(name in str(error) for name, _, _ in _PLATFORM_STATE):
                return {'page': pg or '1', 'pagecount': 1, 'limit': 0, 'total': 0, 'list': []}
            raise
    if method == 'detailContent':
        ids = rest[0] if len(rest) > 0 else '[]'
        try:
            ids_obj = json.loads(ids) if ids else []
        except (ValueError, TypeError):
            ids_obj = []
        return _invoke(sp, 'detailContent', ids_obj)
    if method == 'searchContent':
        key = rest[0] if len(rest) > 0 else ''
        pg = rest[2] if len(rest) > 2 and rest[2].strip() else '1'
        return _invoke_variants(sp, 'searchContent', [(key, False, pg), (key, False), (key,)])
    if method == 'playerContent':
        flag = rest[0] if len(rest) > 0 else ''
        pid = rest[1] if len(rest) > 1 else ''
        vip = rest[2] if len(rest) > 2 else '[]'
        try:
            vip_obj = json.loads(vip) if vip else []
        except (ValueError, TypeError):
            vip_obj = []
        return _invoke(sp, 'playerContent', flag, pid, vip_obj)
    if method == 'liveContent':
        return _invoke(sp, 'liveContent', rest[0] if len(rest) > 0 else '')
    if method == 'proxy':
        params = json.loads(rest[0]) if rest else {}
        fn = 'proxy' if 'proxy' in type(sp).__dict__ else 'localProxy'
        result = _invoke(sp, fn, params)
        if isinstance(result, (list, tuple)) and len(result) >= 3 and isinstance(result[2], bytes):
            result = list(result)
            result[2] = {'base64': base64.b64encode(result[2]).decode('ascii')}
        return result
    raise SystemExit('unknown method: %s' % method)


def _serialize(result, real_out=_REAL_OUT):
    """结果序列化：dict/list → json；已 JSON 字符串原样透传；末尾换行。

    ★ 一律写 real_out（真正的 stdout 句柄）：蜘蛛自己的 print() 已被重定向到 stderr
    （见 main），否则它的日志碎片会与结果/信封拼成同一行 → 宿主侧 JSON 解析失败 →
    常驻池挂起到超时（用户侧表现「半天搜不出来」）。
    """
    out = result
    if isinstance(out, str):
        try:
            parsed = json.loads(out)
            json.dumps(parsed)  # 校验可解析
            out = parsed
        except (ValueError, TypeError):
            pass  # 非 JSON 字符串，交给 dumps 兜底
    real_out.write(json.dumps(out, ensure_ascii=False) if not isinstance(out, str) else out)
    real_out.write('\n')
    real_out.flush()


# ★ 蜘蛛实例缓存（2026-09-24）：键 = (类名, ext)。与 Java 侧 SpiderPool 同理 ——
#   源脚本的 init(ext) 可能要解析配置/建会话，每请求重建会让首次与后续都变慢；
#   这里缓存实例复用；同一键并发时各自新建（Python 无锁，够用）。
_INSTANCES = {}
_INSTANCE_LOCK = threading.Lock()


def _acquire(ns, py_path, class_name, ext):
    key = (os.path.abspath(py_path), class_name, ext or '')
    with _INSTANCE_LOCK:
        sp = _INSTANCES.pop(key, None)
    if sp is None:
        sp = _new_instance(ns, class_name)
        try:
            sp.init(ext)
        except (AttributeError, TypeError):
            pass
    return key, sp


def _release(key, sp, broken):
    if broken:
        return
    with _INSTANCE_LOCK:
        if len(_INSTANCES) > 64:
            _INSTANCES.clear()
        _INSTANCES[key] = sp


# ---- 进程内入口（Android / Chaquopy） ------------------------------------------
# 与 -serve / --hold 共用 _call_method，但结果通过返回值交给宿主，不写 stdout：
# 进程内 stdout 是 Logcat，不能当协议通道。异常一律转成 {"ok": false, "error": ...}，
# 让 Dart 侧继续复用桌面进程版的错误归类逻辑。

_SCRIPT_CACHE = {}
_SCRIPT_LOCK = threading.Lock()
_HOLDS = {}
_HOLD_LOCK = threading.Lock()


def _load_script_cached(py_path):
    """同一脚本按 mtime 缓存编译结果；脚本被替换后清掉旧实例（类还是旧代码）。"""
    path = os.path.abspath(py_path)
    mtime = os.path.getmtime(path)
    with _SCRIPT_LOCK:
        cached = _SCRIPT_CACHE.get(path)
        if cached is not None and cached[0] == mtime:
            return cached[1]
    ns = _load_script(path)
    with _SCRIPT_LOCK:
        _SCRIPT_CACHE[path] = (mtime, ns)
        with _INSTANCE_LOCK:
            for key in [k for k in _INSTANCES if k[0] == path]:
                _INSTANCES.pop(key, None)
    return ns


def _error_text(error):
    detail = ''.join(
        traceback.format_exception(type(error), error, error.__traceback__)
    )
    return '[SpiderRunner.ERROR] %s: %s\n%s' % (
        type(error).__name__,
        error,
        detail,
    )


def _ok(data):
    return json.dumps({'ok': True, 'data': data}, ensure_ascii=False)


def _fail_envelope(error):
    return json.dumps(
        {'ok': False, 'error': _error_text(error)},
        ensure_ascii=False,
    )


def _args_of(args_json):
    try:
        args = json.loads(args_json) if args_json else []
    except (ValueError, TypeError):
        args = []
    if not isinstance(args, list):
        args = [args]
    return [str(a) for a in args]


def inproc_call(script, class_name, method, ext, args_json):
    """进程内一次性调用：返回 JSON 信封。"""
    try:
        path = os.path.abspath(str(script))
        if not os.path.exists(path):
            raise SystemExit('pyPath 不存在：%s' % path)
        ns = _load_script_cached(path)
        key, sp = _acquire(ns, path, str(class_name), str(ext or ''))
        broken = False
        try:
            data = _serialize_raw(
                _call_method(sp, str(method), _args_of(args_json))
            )
        except BaseException:
            broken = True
            raise
        finally:
            if broken:
                # 失败实例不回收：脚本可能已经起了本机取流线程，先尽量关掉。
                _destroy_instance(sp)
            else:
                _release(key, sp, False)
        return _ok(data)
    except BaseException as error:
        return _fail_envelope(error)


def inproc_hold(key, script, class_name, method, ext, args_json):
    """常驻一次播放调用：结果返回后实例留在 _HOLDS，脚本的本机取流线程继续活着。"""
    try:
        path = os.path.abspath(str(script))
        if not os.path.exists(path):
            raise SystemExit('pyPath 不存在：%s' % path)
        ns = _load_script_cached(path)
        sp = _new_instance(ns, str(class_name))
        try:
            sp.init(str(ext or ''))
        except (AttributeError, TypeError):
            pass
        try:
            data = _serialize_raw(
                _call_method(sp, str(method), _args_of(args_json))
            )
        except BaseException:
            _destroy_instance(sp)
            raise
        hold_key = str(key or 'default')
        with _HOLD_LOCK:
            old = _HOLDS.pop(hold_key, None)
            _HOLDS[hold_key] = sp
        if old is not None:
            _destroy_instance(old)
        return _ok(data)
    except BaseException as error:
        return _fail_envelope(error)


def inproc_held_call(key, method, args_json):
    with _HOLD_LOCK:
        sp = _HOLDS.get(str(key or 'default'))
    if sp is None:
        return _fail_envelope(RuntimeError('常驻蜘蛛实例不存在或已释放'))
    try:
        data = _serialize_raw(_call_method(sp, str(method), _args_of(args_json)))
        return _ok(data)
    except BaseException as error:
        return _fail_envelope(error)


def _destroy_instance(sp):
    for name in ('destroy', 'close'):
        fn = getattr(sp, name, None)
        if callable(fn):
            try:
                fn()
            except Exception:
                pass
            return


def inproc_release(key):
    with _HOLD_LOCK:
        sp = _HOLDS.pop(str(key or 'default'), None)
    if sp is not None:
        _destroy_instance(sp)
    return _ok('')


def inproc_release_all():
    with _HOLD_LOCK:
        holds = list(_HOLDS.values())
        _HOLDS.clear()
    for sp in holds:
        _destroy_instance(sp)
    return _ok('')


def inproc_reset():
    inproc_release_all()
    with _SCRIPT_LOCK:
        _SCRIPT_CACHE.clear()
    with _INSTANCE_LOCK:
        _INSTANCES.clear()
    return _ok('')


def _serve(py_path, class_name):
    """常驻模式：脚本只编译一次，stdin 逐行读 JSON 请求 {id, method, args}，单行 JSON 信封应答。
    每请求新蜘蛛实例（复用 Python 进程、不复用实例，避免跨请求状态串扰）；init(ext) 每请求执行。
    信封：{"id": ..., "ok": true|false, "data": "结果(JSON字符串)"} —— data 经 json.dumps 转义内嵌换行，
    物理单行，行协议不被结果内容打穿。读到 EOF 或请求体 {"quit":true} 退出。
    """
    ns = _load_script(py_path)
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        req_id = ''
        ok = False
        data = ''
        try:
            req = json.loads(line)
            if not isinstance(req, dict):
                raise ValueError('bad request: %r' % line)
            if req.get('quit'):
                break
            req_id = str(req.get('id', ''))
            method = str(req.get('method', ''))
            args = req.get('args') or []
            if not isinstance(args, list):
                args = [args]
            rest = [str(a) for a in args]
            # ★ 预热探针：脚本已在 _serve 入口编译完成；
            #   __warm__ 进一步预建实例（含 init(ext)）进缓存，首次进源/搜索免付 init。
            if method == '__ping__':
                ok = True
                data = ''
            elif method == '__warm__':
                key, sp = _acquire(ns, py_path, class_name, rest[0] if rest else '')
                _release(key, sp, False)
                ok = True
            else:
                key, sp = _acquire(ns, py_path, class_name, rest[0] if len(rest) > 0 else '')
                broken = False
                try:
                    data = _serialize_raw(_call_method(sp, method, rest[1:] if len(rest) > 1 else []))
                    ok = True
                except BaseException:
                    broken = True
                    raise
                finally:
                    _release(key, sp, broken)
        except SystemExit as e:
            data = 'SystemExit: %s' % e
        except Exception as e:
            data = '%s: %s' % (type(e).__name__, e)
        # ★ 单行 JSON 信封（data 内嵌 \n 由 json.dumps 转义）
        _REAL_OUT.write(json.dumps({'id': req_id, 'ok': ok, 'data': data}, ensure_ascii=False) + '\n')
        _REAL_OUT.flush()


def _serialize_raw(result):
    """把蜘蛛返回值转成可 JSON 传输的字符串：dict/list → json；str 原样。"""
    if isinstance(result, str):
        return result
    return json.dumps(result, ensure_ascii=False)


def _hold(py_path, class_name, method, rest):
    """打完一次结果后不退出，直到宿主写 quit / 关闭 stdin。

    .py 源常把 `playerContent` 的播放地址指向脚本自己起的本机 HTTP 取流服务；
    该服务是进程内 daemon 线程，进程一退端口就没了，播放器只会拿到连接失败。
    """
    ns = _load_script(py_path)
    sp = _new_instance(ns, class_name)
    ext = rest[0] if rest else ''
    try:
        sp.init(ext)
    except (AttributeError, TypeError):
        pass
    result = _call_method(sp, method, rest[1:])
    _serialize(result)
    try:
        for line in sys.stdin:
            if line.strip().lower() in ('quit', 'exit', '{"quit":true}'):
                break
    except (OSError, ValueError):
        pass


def main():
    # 蜘蛛 print() → stderr：结果/信封走 _REAL_OUT，行协议不被日志碎片打穿
    sys.stdout = sys.stderr
    _windows_ca_bundle()
    argv = list(sys.argv[1:])
    # `--hold` 允许出现在任意位置（宿主可能把开关放在中间/尾部）。
    # 之前固定按 argv[1] 判定，顺序一变就会把 '--hold' 当成 pyPath 去 open()，
    # 报 FileNotFoundError: '--hold'，取流进程必然失败。
    hold = '--hold' in argv
    if hold:
        argv = [a for a in argv if a != '--hold']
    # 常驻服务模式：runner.py -serve <pyPath> <className>
    if len(argv) >= 3 and argv[0] == '-serve':
        _serve(argv[1], argv[2])
        return
    if not argv:
        raise SystemExit('usage: runner.py [--hold] <pyPath> <className> <method> [ext] [args...]')
    py_path = argv[0]
    if not os.path.exists(py_path):
        raise SystemExit('pyPath 不存在：%s' % py_path)
    class_name = argv[1] if len(argv) > 1 else 'Spider'
    method = argv[2] if len(argv) > 2 else ''
    # 取流常驻：跑完一次结果后挂住，等宿主 quit / 关 stdin。
    if hold:
        _hold(py_path, class_name, method, argv[3:])
        return
    ext = argv[3] if len(argv) > 3 else ''
    ns = _load_script(py_path)
    sp = _new_instance(ns, class_name)
    # init(ext) no-op 容错（部分脚本不实现 init）
    try:
        sp.init(ext)
    except (AttributeError, TypeError):
        pass
    # 方法分派：argv[4..] 即实参（与一次性协议对齐：ext 之后全是方法实参）
    rest = argv[4:]
    result = _call_method(sp, method, rest)
    _serialize(result)


if __name__ == '__main__':
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:
        _fail(e)
