/// Web 版没有子进程，也没有 Windows Job Object。
class ProcessJob {
  const ProcessJob._();

  static Future<bool> adopt(int pid) async => false;
}
