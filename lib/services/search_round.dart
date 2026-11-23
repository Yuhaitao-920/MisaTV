/// 搜索轮次在 Zone 里的键。
///
/// JAR 蜘蛛的 serve host 是单线程顺序执行的，一轮搜索把上百个源一起派发时，
/// 超时后 UI 虽然已经放弃，排在后面的调用仍会继续跑几分钟，把 JVM 和缓存目录
/// 占满。搜索调用在 [zoneValues] 里带上轮次号，JAR 蜘蛛在真正起进程/发请求
/// 前比对当前轮次，过期就抛 [SearchCancelledException]，不再制造后台积压。
const Object searchRoundZoneKey = Object();

/// 搜索轮次已被新搜索 / 用户取消 / 时间预算到期作废。
class SearchCancelledException implements Exception {
  const SearchCancelledException();

  @override
  String toString() => '搜索已取消';
}
