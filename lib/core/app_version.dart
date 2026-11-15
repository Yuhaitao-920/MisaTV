/// 应用版本号：与 `pubspec.yaml` 的 `version:` 保持一致（有测试守护）。
const String kAppVersion = '1.1.0';

/// 检查更新走的仓库（改成自己的 fork，更新检测/下载链接都指向它）。
const String kGithubRepo = 'Yuhaitao-920/MisaTV';

/// 更新弹窗里的「网盘下载」地址。
const String kUpdateNetdiskUrl =
    'https://1824896562.share.123pan.cn/123pan/syh2jv-wt26h?pwd=Misa#';

/// release 页面（下载不到资产时的兜底）。
const String kReleasesUrl = 'https://github.com/$kGithubRepo/releases/latest';
