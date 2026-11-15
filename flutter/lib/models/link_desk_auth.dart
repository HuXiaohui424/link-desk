import 'dart:convert';

import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'platform_model.dart';

class LinkDeskEntitlements {
  final int maxDevices;
  final int maxConcurrentSessions;
  final bool fileTransfer;
  final bool portForward;

  const LinkDeskEntitlements({
    required this.maxDevices,
    required this.maxConcurrentSessions,
    required this.fileTransfer,
    required this.portForward,
  });

  factory LinkDeskEntitlements.fromJson(Map<String, dynamic> json) {
    return LinkDeskEntitlements(
      maxDevices: (json['max_devices'] as num?)?.toInt() ?? 0,
      maxConcurrentSessions:
          (json['max_concurrent_sessions'] as num?)?.toInt() ?? 0,
      fileTransfer: json['file_transfer'] == true,
      portForward: json['port_forward'] == true,
    );
  }
}

class LinkDeskUser {
  final String id;
  final String issuer;
  final String subject;
  final String displayName;
  final String planCode;
  final LinkDeskEntitlements entitlements;

  const LinkDeskUser({
    required this.id,
    required this.issuer,
    required this.subject,
    required this.displayName,
    required this.planCode,
    required this.entitlements,
  });

  factory LinkDeskUser.fromJson(Map<String, dynamic> json) {
    final plan = (json['plan'] as Map?)?.cast<String, dynamic>() ?? {};
    return LinkDeskUser(
      id: '${json['id'] ?? ''}',
      issuer: '${json['oidc_issuer'] ?? ''}',
      subject: '${json['oidc_subject'] ?? ''}',
      displayName: '${json['display_name'] ?? ''}',
      planCode: '${plan['code'] ?? 'free'}',
      entitlements: LinkDeskEntitlements.fromJson(
        (json['entitlements'] as Map?)?.cast<String, dynamic>() ?? {},
      ),
    );
  }
}

class LinkDeskDevice {
  final String deviceId;
  final String name;
  final bool online;
  final DateTime? lastSeenAt;

  const LinkDeskDevice({
    required this.deviceId,
    required this.name,
    required this.online,
    required this.lastSeenAt,
  });

  factory LinkDeskDevice.fromJson(Map<String, dynamic> json) {
    return LinkDeskDevice(
      deviceId: '${json['device_id'] ?? ''}',
      name: '${json['name'] ?? ''}',
      online: json['online'] == true,
      lastSeenAt: DateTime.tryParse('${json['last_seen_at'] ?? ''}'),
    );
  }
}

enum LinkDeskAuthState { signedOut, restoring, signedIn }

class LinkDeskAuthService extends GetxService {
  static const _serverUrlKey = 'link-desk-server-url';
  static const _accessTokenKey = 'link-desk-access-token';
  static const _refreshTokenKey = 'link-desk-refresh-token';
  static const _userKey = 'link-desk-user';
  static const _deviceIdKey = 'link-desk-device-id';
  static const _enforceAuthKey = 'link-desk-auth-required';

  final state = LinkDeskAuthState.signedOut.obs;
  final user = Rxn<LinkDeskUser>();
  final devices = <LinkDeskDevice>[].obs;
  final deviceId = ''.obs;
  final error = ''.obs;

  String get serverUrl {
    final configured = bind.mainGetLocalOption(key: _serverUrlKey).trim();
    return configured.isEmpty ? 'http://127.0.0.1:21119' : configured;
  }

  String get _accessToken =>
      bind.mainGetLocalOption(key: _accessTokenKey).trim();
  String get _refreshToken =>
      bind.mainGetLocalOption(key: _refreshTokenKey).trim();

  bool get isSignedIn =>
      state.value == LinkDeskAuthState.signedIn && _accessToken.isNotEmpty;

  bool get enforceAuth =>
      bind.mainGetLocalOption(key: _enforceAuthKey).toUpperCase() != 'N';

  bool canStartRemoteConnection() => !enforceAuth || isSignedIn;

  Future<void> restore() async {
    state.value = LinkDeskAuthState.restoring;
    error.value = '';
    final accessToken = _accessToken;
    final refreshToken = _refreshToken;
    if (accessToken.isEmpty && refreshToken.isEmpty) {
      _clearMemory();
      return;
    }
    if (accessToken.isNotEmpty && await _loadCurrentUser(accessToken)) {
      await loadDevices();
      if (devices.isEmpty) {
        await bindDevice();
      }
      return;
    }
    if (refreshToken.isNotEmpty && await refresh()) {
      await loadDevices();
      if (devices.isEmpty) {
        await bindDevice();
      }
      return;
    }
    await logout();
  }

  Future<bool> exchangeOidcIdentity({
    required String issuer,
    required String subject,
    String? displayName,
  }) async {
    error.value = '';
    final response = await _request(
      'POST',
      '/api/auth/oidc/exchange',
      body: {
        'issuer': issuer,
        'subject': subject,
        if (displayName != null) 'display_name': displayName,
      },
    );
    if (response == null || response.statusCode != 200) {
      error.value = _errorMessage(response);
      return false;
    }
    await _saveAuthResponse(_decode(response));
    return true;
  }

  Future<String?> startOidcLogin() async {
    final response = await _request(
      'GET',
      '/api/auth/oidc/start',
      authenticated: false,
    );
    if (response == null || response.statusCode != 200) {
      error.value = _errorMessage(response);
      return null;
    }
    final data = _decode(response);
    final url = '${data['authorization_url'] ?? ''}';
    if (url.isEmpty) {
      error.value = 'OIDC authorization URL is empty';
      return null;
    }
    final launched =
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    if (!launched) {
      error.value = 'Failed to open OIDC authorization URL';
      return null;
    }
    return '${data['state'] ?? ''}';
  }

  Future<bool> exchangeOidcCode({
    required String code,
    required String state,
  }) async {
    final response = await _request(
      'POST',
      '/api/auth/oidc/exchange-code',
      body: {'code': code, 'state': state},
      authenticated: false,
    );
    if (response == null || response.statusCode != 200) {
      error.value = _errorMessage(response);
      return false;
    }
    await _saveAuthResponse(_decode(response));
    return true;
  }

  Future<bool> refresh() async {
    if (_refreshToken.isEmpty) {
      return false;
    }
    final response = await _request(
      'POST',
      '/api/auth/refresh',
      body: {'refresh_token': _refreshToken},
      authenticated: false,
    );
    if (response == null || response.statusCode != 200) {
      _clearMemory();
      return false;
    }
    await _saveAuthResponse(_decode(response));
    return true;
  }

  Future<void> logout() async {
    await _request('POST', '/api/auth/logout');
    await bind.mainSetLocalOption(key: _accessTokenKey, value: '');
    await bind.mainSetLocalOption(key: _refreshTokenKey, value: '');
    await bind.mainSetLocalOption(key: _userKey, value: '');
    await bind.mainSetLocalOption(key: _deviceIdKey, value: '');
    _clearMemory();
  }

  Future<bool> loadDevices() async {
    final response = await _request('GET', '/api/devices');
    if (response == null || response.statusCode != 200) {
      error.value = _errorMessage(response);
      return false;
    }
    final values = jsonDecode(response.body) as List<dynamic>;
    devices.assignAll(values
        .whereType<Map>()
        .map((value) => LinkDeskDevice.fromJson(value.cast<String, dynamic>()))
        .toList());
    final storedDeviceId = bind.mainGetLocalOption(key: _deviceIdKey).trim();
    if (storedDeviceId.isNotEmpty &&
        devices.any((device) => device.deviceId == storedDeviceId)) {
      deviceId.value = storedDeviceId;
    } else if (devices.length == 1) {
      deviceId.value = devices.first.deviceId;
      await bind.mainSetLocalOption(
          key: _deviceIdKey, value: devices.first.deviceId);
    }
    return true;
  }

  Future<bool> bindDevice({String? name}) async {
    final response = await _request(
      'POST',
      '/api/devices/bind',
      body: {
        if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
      },
    );
    if (response == null || response.statusCode != 201) {
      error.value = _errorMessage(response);
      return false;
    }
    final data = _decode(response);
    final boundDevice = LinkDeskDevice(
      deviceId: '${data['device_id'] ?? ''}',
      name: name?.trim().isNotEmpty == true ? name!.trim() : 'Link-desk device',
      online: false,
      lastSeenAt: null,
    );
    devices
      ..removeWhere((device) => device.deviceId == boundDevice.deviceId)
      ..add(boundDevice);
    deviceId.value = boundDevice.deviceId;
    await bind.mainSetLocalOption(
        key: _deviceIdKey, value: boundDevice.deviceId);
    return boundDevice.deviceId.isNotEmpty;
  }

  Future<bool> heartbeat() async {
    if (!isSignedIn || deviceId.value.isEmpty) {
      return false;
    }
    final response = await _request(
      'POST',
      '/api/devices/${Uri.encodeComponent(deviceId.value)}/heartbeat',
    );
    if (response == null || response.statusCode != 204) {
      if (response?.statusCode == 401) {
        await refresh();
      }
      return false;
    }
    return true;
  }

  Future<String?> authorizeConnection(String targetDeviceId) async {
    if (!isSignedIn || targetDeviceId.trim().isEmpty) {
      return null;
    }
    final response = await _request(
      'POST',
      '/api/devices/${Uri.encodeComponent(targetDeviceId.trim())}/authorize',
    );
    if (response == null || response.statusCode != 200) {
      error.value = _errorMessage(response);
      return null;
    }
    final ticket = '${_decode(response)['ticket'] ?? ''}';
    return ticket.isEmpty ? null : ticket;
  }

  Future<bool> _loadCurrentUser(String token) async {
    final response = await _request(
      'GET',
      '/api/auth/me',
      token: token,
      authenticated: false,
    );
    if (response == null || response.statusCode != 200) {
      return false;
    }
    _setUser(LinkDeskUser.fromJson(_decode(response)));
    return true;
  }

  Future<void> _saveAuthResponse(Map<String, dynamic> json) async {
    await bind.mainSetLocalOption(
        key: _accessTokenKey, value: '${json['access_token'] ?? ''}');
    await bind.mainSetLocalOption(
        key: _refreshTokenKey, value: '${json['refresh_token'] ?? ''}');
    final userJson = (json['user'] as Map?)?.cast<String, dynamic>();
    if (userJson == null) {
      _clearMemory();
      return;
    }
    await bind.mainSetLocalOption(key: _userKey, value: jsonEncode(userJson));
    _setUser(LinkDeskUser.fromJson(userJson));
    state.refresh();
    if (await loadDevices() && devices.isEmpty) {
      await bindDevice();
    }
  }

  void _setUser(LinkDeskUser value) {
    user.value = value;
    state.value = LinkDeskAuthState.signedIn;
    error.value = '';
  }

  void _clearMemory() {
    user.value = null;
    devices.clear();
    deviceId.value = '';
    state.value = LinkDeskAuthState.signedOut;
  }

  Future<http.Response?> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    String? token,
    bool authenticated = true,
  }) async {
    try {
      final headers = <String, String>{'Content-Type': 'application/json'};
      if (authenticated) {
        final authToken = token ?? _accessToken;
        if (authToken.isEmpty) return null;
        headers['Authorization'] = 'Bearer $authToken';
      }
      final uri = Uri.parse('$serverUrl$path');
      if (method == 'GET') {
        return await http.get(uri, headers: headers);
      }
      return await http.post(
        uri,
        headers: headers,
        body: body == null ? null : jsonEncode(body),
      );
    } catch (e) {
      error.value = e.toString();
      return null;
    }
  }

  Map<String, dynamic> _decode(http.Response response) =>
      (jsonDecode(response.body) as Map).cast<String, dynamic>();

  String _errorMessage(http.Response? response) {
    if (response == null) return error.value;
    try {
      return '${_decode(response)['error'] ?? 'Link-desk request failed'}';
    } catch (_) {
      return 'Link-desk request failed (${response.statusCode})';
    }
  }
}
