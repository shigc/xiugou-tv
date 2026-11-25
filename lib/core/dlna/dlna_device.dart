/// DLNA 设备模型（UPnP MediaRenderer）。
class DlnaDevice {
  /// SSDP USN 唯一标识（同一设备可能回复多条 ST，按 USN 去重）。
  final String usn;

  /// 设备描述 XML 的 LOCATION 地址（http://ip:port/description.xml）。
  final String location;

  /// 友好名称（客厅电视 / Xiaomi-TV 等），来自设备描述 XML。
  final String friendlyName;

  /// AVTransport 控制地址（SOAP POST 目标），可能为 null（不支持投屏）。
  final String? avTransportControlUrl;

  const DlnaDevice({
    required this.usn,
    required this.location,
    required this.friendlyName,
    this.avTransportControlUrl,
  });

  /// 设备 IP（从 LOCATION 解析，用于展示）。
  String get host {
    final match = RegExp(r'//([^:/]+)').firstMatch(location);
    return match?.group(1) ?? location;
  }

  /// 是否具备可投屏能力（有 AVTransport 控制地址）。
  bool get isCastable =>
      avTransportControlUrl != null && avTransportControlUrl!.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is DlnaDevice && other.usn == usn;

  @override
  int get hashCode => usn.hashCode;

  @override
  String toString() => 'DlnaDevice($friendlyName @ $host)';
}
