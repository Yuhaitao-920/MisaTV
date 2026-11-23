import 'dart:convert';

import 'package:xml/xml.dart';

import '../core/utils/text_utils.dart';
import '../models/vod.dart';

class CmsMovie {
  CmsMovie({
    this.page = 0,
    this.pagecount = 0,
    this.pagesize = 0,
    this.recordcount = 0,
    this.videos = const [],
  });
  final int page;
  final int pagecount;
  final int pagesize;
  final int recordcount;
  final List<CmsVideo> videos;
}

class CmsVideo {
  CmsVideo({
    required this.id,
    required this.name,
    this.tid = 0,
    this.type = '',
    this.pic = '',
    this.lang = '',
    this.area = '',
    this.year = 0,
    this.state = '',
    this.note = '',
    this.actor = '',
    this.director = '',
    this.des = '',
    this.tag = '',
    this.action = '',
    this.last = '',
    this.urlFlags = const [],
  });

  final String id;
  final String name;
  final int tid;
  final String type;
  final String pic;
  final String lang;
  final String area;
  final int year;
  final String state;
  final String note;
  final String actor;
  final String director;
  final String des;
  final String tag;
  final String action;
  final String last;

  /// (flag, 原始播放串)
  final List<(String, String)> urlFlags;
}

class CmsBody {
  CmsBody({this.classes = const [], this.movie});
  final List<SortClass> classes;
  final CmsMovie? movie;
}

class MovieParser {
  static CmsBody parse(String text, int type, String sourceKey) {
    if (type == 0) return parseXml(text);
    return parseJson(text);
  }

  static CmsBody parseXml(String text) {
    try {
      final doc = XmlDocument.parse(text);
      final rss = _findFirst(doc, 'rss');
      if (rss == null) return CmsBody();
      final classes = <SortClass>[];
      final classNode = _findFirst(rss, 'class');
      if (classNode != null) {
        for (final ty in classNode.findElements('ty')) {
          final id = ty.getAttribute('id')?.trim() ?? '';
          final name = ty.innerText.trim();
          if (id.isEmpty || name.isEmpty) continue;
          final flag = ty.getAttribute('flag');
          classes.add(SortClass(id: id, name: name, flag: flag));
        }
      }
      final listNode = _findFirst(rss, 'list');
      if (listNode == null) return CmsBody(classes: classes);
      final videos = <CmsVideo>[];
      for (final v in listNode.findElements('video')) {
        final urlFlags = <(String, String)>[];
        final dl = _findFirst(v, 'dl');
        if (dl != null) {
          for (final dd in dl.findElements('dd')) {
            final flag = dd.getAttribute('flag')?.trim() ?? '';
            final urls = dd.innerText.trim();
            if (flag.isNotEmpty && urls.isNotEmpty) urlFlags.add((flag, urls));
          }
        }
        videos.add(
          CmsVideo(
            id: _childText(v, 'id'),
            name: _childText(v, 'name'),
            tid: int.tryParse(_childText(v, 'tid')) ?? 0,
            type: _childText(v, 'type'),
            pic: normalizePic(_childText(v, 'pic')),
            lang: _childText(v, 'lang'),
            area: _childText(v, 'area'),
            year: int.tryParse(_childText(v, 'year')) ?? 0,
            state: _childText(v, 'state'),
            note: _childText(v, 'note'),
            actor: _childText(v, 'actor'),
            director: _childText(v, 'director'),
            des: _childText(v, 'des'),
            tag: _childText(v, 'tag'),
            action: _childText(v, 'action'),
            last: _childText(v, 'last'),
            urlFlags: urlFlags,
          ),
        );
      }
      return CmsBody(
        classes: classes,
        movie: CmsMovie(
          page: int.tryParse(listNode.getAttribute('page') ?? '') ?? 0,
          pagecount:
              int.tryParse(listNode.getAttribute('pagecount') ?? '') ?? 0,
          pagesize: int.tryParse(listNode.getAttribute('pagesize') ?? '') ?? 0,
          recordcount:
              int.tryParse(listNode.getAttribute('recordcount') ?? '') ?? 0,
          videos: videos,
        ),
      );
    } catch (_) {
      return CmsBody();
    }
  }

  static CmsBody parseJson(String text) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) return CmsBody();
      final root = Map<String, dynamic>.from(decoded);
      final classes = parseClasses(root);
      final listRaw = root['list'];
      final videos = <CmsVideo>[];
      if (listRaw is List) {
        for (final item in listRaw) {
          if (item is! Map) continue;
          final vod = Map<String, dynamic>.from(item);
          final playFrom = _s(vod['vod_play_from']);
          final playUrl = _s(vod['vod_play_url']);
          final flags = <(String, String)>[];
          if (playFrom.isNotEmpty && playUrl.isNotEmpty) {
            final fs = playFrom.split(r'$$$');
            final us = playUrl.split(r'$$$');
            final n = fs.length < us.length ? fs.length : us.length;
            for (var i = 0; i < n; i++) {
              final f = fs[i].trim();
              final u = us[i].trim();
              if (f.isNotEmpty && u.isNotEmpty) flags.add((f, u));
            }
          }
          videos.add(
            CmsVideo(
              id: normalizeId(vod['vod_id'], vod['vod_name']),
              name: _s(vod['vod_name']),
              tid: int.tryParse(_s(vod['type_id'])) ?? 0,
              type: _s(vod['type_name']),
              pic: normalizePic(vod['vod_pic']),
              lang: _s(vod['vod_lang']),
              area: _s(vod['vod_area']),
              year: int.tryParse(_s(vod['vod_year'])) ?? 0,
              state: _s(vod['vod_state']),
              note: _s(vod['vod_remarks']),
              actor: _s(vod['vod_actor']),
              director: _s(vod['vod_director']),
              des: _s(vod['vod_content']),
              tag: _s(vod['vod_tag']),
              action: _s(vod['action']),
              last: _s(vod['vod_time']),
              urlFlags: flags,
            ),
          );
        }
      }
      return CmsBody(
        classes: classes,
        movie: CmsMovie(
          page: int.tryParse(_s(root['page'])) ?? 0,
          pagecount: int.tryParse(_s(root['pagecount'])) ?? 0,
          pagesize: int.tryParse(_s(root['limit'])) ?? 0,
          recordcount: int.tryParse(_s(root['total'])) ?? 0,
          videos: videos,
        ),
      );
    } catch (_) {
      return CmsBody();
    }
  }

  static List<SortClass> parseClasses(Map<String, dynamic> root) {
    final raw = root['class'];
    final entries = <Map<String, dynamic>>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map) entries.add(Map<String, dynamic>.from(e));
      }
    } else if (raw is Map) {
      for (final e in raw.entries) {
        final v = e.value;
        if (v is Map) {
          entries.add({'type_id': e.key, ...Map<String, dynamic>.from(v)});
        } else {
          entries.add({'type_id': e.key, 'type_name': v?.toString() ?? ''});
        }
      }
    }
    final out = <SortClass>[];
    for (var i = 0; i < entries.length; i++) {
      final o = entries[i];
      final id = _s(o['type_id'] ?? o['id'] ?? o['tid']).trim();
      final name = _s(o['type_name'] ?? o['name'] ?? o['title']).trim();
      if (id.isEmpty || name.isEmpty) continue;
      final filters = _classFilters(root, o, id, i);
      out.add(
        SortClass(
          id: id,
          name: name,
          flag: o['type_flag']?.toString(),
          filters: filters,
        ),
      );
    }
    return out;
  }

  static List<FilterGroup> _classFilters(
    Map<String, dynamic> root,
    Map<String, dynamic> entry,
    String classId,
    int index,
  ) {
    final own = _parseFilters(entry['filters']);
    if (own.isNotEmpty) return own;
    final top = root['filters'];
    if (top is Map) {
      final map = Map<String, dynamic>.from(top);
      for (final key in [classId, index.toString()]) {
        if (key.isEmpty || key == '-1') continue;
        final byId = map[key];
        if (byId == null) continue;
        final groups = _parseFilters(byId);
        if (groups.isNotEmpty) return groups;
      }
      if (map.values.every((v) => v is Map)) return _parseFilters(map);
    }
    return const [];
  }

  static List<FilterGroup> _parseFilters(dynamic raw) {
    if (raw == null) return const [];
    if (raw is List) {
      final out = <FilterGroup>[];
      for (var i = 0; i < raw.length; i++) {
        final g = _toFilterGroup('$i', raw[i]);
        if (g.values.isNotEmpty) out.add(g);
      }
      return out;
    }
    if (raw is Map) {
      final out = <FilterGroup>[];
      for (final e in raw.entries) {
        final g = _toFilterGroup(e.key.toString(), e.value);
        if (g.values.isNotEmpty) out.add(g);
      }
      return out;
    }
    return const [];
  }

  static FilterGroup _toFilterGroup(String rawKey, dynamic raw) {
    final o = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    final valuesRaw = o['value'] is List
        ? o['value'] as List
        : (o['values'] is List ? o['values'] as List : const []);
    final values = <FilterOption>[];
    for (final it in valuesRaw) {
      final m = it is Map ? Map<String, dynamic>.from(it) : <String, dynamic>{};
      final n = _s(m['n'] ?? m['name'] ?? m['title'] ?? m['tab']);
      final rawV = m['v'] ?? m['value'] ?? m['val'];
      final v = rawV == null ? n : _s(rawV);
      if (n.isNotEmpty || v.isNotEmpty) {
        values.add(FilterOption(tab: _s(m['tab']), n: n, v: v));
      }
    }
    return FilterGroup(
      key: _s(o['key'] ?? o['k']).trim().isEmpty
          ? rawKey
          : _s(o['key'] ?? o['k']).trim(),
      name: _s(o['name'] ?? o['key'] ?? o['k']).trim().isEmpty
          ? rawKey
          : _s(o['name'] ?? o['key'] ?? o['k']).trim(),
      values: values,
    );
  }

  static List<VodItem> toItems(CmsMovie? movie, String sourceKey) {
    if (movie == null) return const [];
    return movie.videos.map((v) => toItem(v, sourceKey)).toList();
  }

  static VodItem toItem(CmsVideo v, String sourceKey) => VodItem(
    id: v.id,
    name: v.name,
    pic: v.pic,
    remarks: v.note,
    // 0 是「没有年份」，不能显示成封面角标「0」。
    year: v.year > 0 ? v.year.toString() : '',
    area: v.area,
    type: v.type,
    sourceKey: sourceKey,
    tag: v.tag,
  );

  static VodDetail? toDetail(CmsMovie? movie, String sourceKey) {
    if (movie == null || movie.videos.isEmpty) return null;
    // 网盘型加固源会在 detailContent 里直接返回一组 `vod_tag=folder`
    // 子目录（如「夸克网盘 51」）。它们不是可播条目，不能只取第一条
    // 当详情，否则页面只剩「暂无选集」。
    final folders = <VodItem>[
      for (final item in movie.videos)
        if (_isFolderTag(item.tag)) toItem(item, sourceKey),
    ];
    final playable = movie.videos
        .where((item) => !_isFolderTag(item.tag))
        .toList();
    final v = playable.isNotEmpty ? playable.first : movie.videos.first;
    final flags = <String>[];
    final episodes = <String, List<Episode>>{};
    for (final item in v.urlFlags) {
      final eps = parseEpisodes(item.$2);
      if (eps.isEmpty) continue;
      flags.add(item.$1);
      episodes[item.$1] = eps;
    }
    return VodDetail(
      id: v.id,
      name: v.name,
      pic: v.pic,
      type: v.type,
      year: v.year > 0 ? v.year.toString() : '',
      area: v.area,
      director: v.director,
      actor: v.actor,
      des: v.des,
      remarks: v.note,
      flags: flags,
      episodes: episodes,
      folders: folders,
      sourceKey: sourceKey,
    );
  }

  static bool _isFolderTag(String tag) {
    final value = tag.trim().toLowerCase();
    return value == '1' || value == 'folder';
  }

  static List<Episode> parseEpisodes(String urls) {
    final out = <Episode>[];
    if (urls.isEmpty) return out;
    for (final part in urls.split('#')) {
      final t = part.trim();
      if (t.isEmpty) continue;
      final i = t.indexOf(r'$');
      if (i < 0) {
        out.add(Episode(name: '第${out.length + 1}集', url: t));
      } else {
        final name = t.substring(0, i).trim();
        final url = t.substring(i + 1).trim();
        out.add(
          Episode(name: name.isEmpty ? '第${out.length + 1}集' : name, url: url),
        );
      }
    }
    return out;
  }

  static String normalizeId(dynamic rawId, dynamic rawName) {
    final id = _s(rawId).trim();
    if (id.isNotEmpty) return id;
    return _s(rawName).trim();
  }

  static String normalizePic(dynamic raw) {
    final s = _s(raw).trim();
    if (s.isEmpty) return '';
    final clean = splitUrlHeadersClean(s);
    return clean;
  }

  static String _s(dynamic v) => v == null ? '' : v.toString();

  static XmlElement? _findFirst(XmlNode node, String name) {
    for (final e in node.findAllElements(name)) {
      return e;
    }
    return null;
  }

  static String _childText(XmlElement el, String name) {
    for (final c in el.findElements(name)) {
      return c.innerText.trim();
    }
    return '';
  }
}
