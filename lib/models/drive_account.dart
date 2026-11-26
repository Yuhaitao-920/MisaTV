class DriveAccount {
  const DriveAccount({
    required this.provider,
    required this.cookie,
    this.username = '',
    required this.updatedAt,
    this.extra = const {},
  });

  final String provider;
  final String cookie;
  final String username;
  final int updatedAt;

  /// 附加凭据（如 UC TV Token 的 token 与 deviceId）。
  final Map<String, String> extra;

  DriveAccount copyWith({
    String? cookie,
    String? username,
    int? updatedAt,
    Map<String, String>? extra,
  }) => DriveAccount(
    provider: provider,
    cookie: cookie ?? this.cookie,
    username: username ?? this.username,
    updatedAt: updatedAt ?? this.updatedAt,
    extra: extra ?? this.extra,
  );

  Map<String, dynamic> toJson() => {
    'provider': provider,
    'cookie': cookie,
    'username': username,
    'updatedAt': updatedAt,
    if (extra.isNotEmpty) 'extra': extra,
  };

  factory DriveAccount.fromJson(Map<String, dynamic> json) => DriveAccount(
    provider: (json['provider'] ?? '').toString(),
    cookie: (json['cookie'] ?? '').toString(),
    username: (json['username'] ?? '').toString(),
    updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
    extra:
        (json['extra'] as Map?)?.map(
          (k, v) => MapEntry(k.toString(), v.toString()),
        ) ??
        const {},
  );
}
