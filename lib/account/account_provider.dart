import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:echo_pin/account/account_models.dart';
import 'package:echo_pin/account/api_client.dart';
import 'package:echo_pin/account/device_key.dart';
import 'package:echo_pin/core/echo_error.dart';
import 'package:echo_pin/services/key_value_store.dart';
import 'package:echopin_protocol/echopin_protocol.dart';
import 'package:flutter/foundation.dart';

enum AccountStage {
  /// No server configured: the app runs fully local, as it always has.
  disabled,
  signedOut,

  /// Registered; waiting for the 8-digit email code.
  verifying,
  signedIn,
}

/// Accounts on this device: sign-up, sign-in, tokens and the escrow key.
///
/// Offline-first: once signed in, the account and tokens are kept in the
/// OS keystore and the app treats you as signed in without a connection.
/// Only the server can sign you out (expired, revoked, disabled), and when
/// it does, [signedOutReason] says why in plain words.
class AccountProvider extends ChangeNotifier {
  AccountProvider({
    required KeyValueStore kv,
    required this.platform,
    required this.appVersion,
    this.secureKeyStorage = true,
    String pinnedCustodianKey = kCustodianKey,
    EchoPinApi? api,
    String serverUrl = kServerUrl,
    DateTime Function()? clock,
  }) : _kv = kv,
       _deviceKey = DeviceKeyStore(kv),
       _pinnedCustodian = _decodeKey(pinnedCustodianKey),
       _api =
           api ??
           (serverUrlAllowed(serverUrl)
               ? EchoPinApi(baseUrl: serverUrl)
               : null),
       _clock = clock ?? DateTime.now;

  final KeyValueStore _kv;
  final DeviceKeyStore _deviceKey;
  final EchoPinApi? _api;
  final DateTime Function() _clock;
  final String platform;
  final String appVersion;

  /// Whether this install keeps secrets in an OS keystore. Sent with the
  /// device registration; the server gives plain-storage devices shorter
  /// sessions, and the Account screen warns about it.
  final bool secureKeyStorage;

  /// Custodian public key built into the app, if any (see [kCustodianKey]).
  final List<int>? _pinnedCustodian;

  static const String _kAccount = 'echo_pin.account_v1';
  static const String _kEscrow = 'echo_pin.escrow_v1';
  static const String _kCustodianPrivate = 'echo_pin.custodian_private_v1';

  Account? _account;
  AuthTokens? _tokens;
  EscrowKey? _escrow;
  String? _pendingEmail;
  String? _signedOutReason;
  bool _loaded = false;
  bool _disposed = false;
  Future<AuthTokens>? _refreshing;

  bool get enabled => _api != null;
  bool get loaded => _loaded;
  Account? get account => _account;
  EscrowKey? get escrow => _escrow;
  String? get pendingEmail => _pendingEmail;
  String? get signedOutReason => _signedOutReason;
  String? get serverUrl => _api?.baseUrl;

  AccountStage get stage {
    if (!enabled) return AccountStage.disabled;
    if (_account != null && _tokens != null) return AccountStage.signedIn;
    if (_pendingEmail != null) return AccountStage.verifying;
    return AccountStage.signedOut;
  }

  bool get signedIn => stage == AccountStage.signedIn;

  /// Now, corrected by the server's clock (see [EchoPinApi.clockOffset]).
  /// Used for proof timestamps and token expiry, which the server judges
  /// by its own clock.
  DateTime _serverNow() =>
      _clock().toUtc().add(_api?.clockOffset ?? Duration.zero);

  EchoPinApi get _server {
    final EchoPinApi? api = _api;
    if (api == null) {
      throw const UnexpectedError('No EchoPin server is configured');
    }
    return api;
  }

  // ── Lifecycle ──────────────────────────────────────────────────────────

  Future<void> load() async {
    if (!enabled) {
      _loaded = true;
      _notify();
      return;
    }
    try {
      final String? raw = await _kv.read(_kAccount);
      if (raw != null) {
        final Map<String, dynamic> j = jsonDecode(raw) as Map<String, dynamic>;
        _account = Account.fromJson(j['account'] as Map<String, dynamic>);
        _tokens = AuthTokens.fromJson(j['tokens'] as Map<String, dynamic>);
      }
    } catch (_) {
      await _kv.delete(_kAccount);
    }
    try {
      final String? raw = await _kv.read(_kEscrow);
      if (raw != null) {
        _escrow = EscrowKey.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      }
    } catch (_) {
      await _kv.delete(_kEscrow);
    }
    _loaded = true;
    _notify();
    // Background: pick up role changes and the current escrow key. Failure
    // (offline) is fine; cached values stay in use.
    if (signedIn) unawaited(_quietly(refreshMe));
    unawaited(_quietly(ensureEscrow));
  }

  // ── Sign-up and verification ───────────────────────────────────────────

  Future<void> signUp({
    required String email,
    required String password,
    required String displayName,
  }) async {
    _requireEmail(email);
    if (displayName.trim().isEmpty) {
      throw const AccountError('invalid_name', 'Enter your name');
    }
    if (displayName.trim().length > ProtocolLimits.maxDisplayName) {
      throw AccountError(
        'invalid_name',
        'Names can be at most ${ProtocolLimits.maxDisplayName} characters',
      );
    }
    final String? weak = localPasswordProblem(password);
    if (weak != null) throw AccountError('weak_password', weak);
    await _server.post(
      '/v1/auth/register',
      body: <String, Object?>{
        'email': email.trim(),
        'password': password,
        'displayName': displayName.trim(),
      },
    );
    _pendingEmail = email.trim();
    _signedOutReason = null;
    _notify();
  }

  /// Confirms the sign-up. The server needs the password chosen at
  /// sign-up as well as the code, so nobody who re-registers the same
  /// address in between can get their password activated.
  Future<void> verifyEmail(String code, {required String password}) async {
    _requireCode(code);
    final String? email = _pendingEmail;
    if (email == null) throw const UnexpectedError('No sign-up in progress');
    await _server.post(
      '/v1/auth/verify-email',
      body: <String, Object?>{
        'email': email,
        'code': code.trim(),
        'password': password,
      },
    );
  }

  /// Picks up an unfinished sign-up (sign-in said the email isn't
  /// confirmed yet): remembers the address and sends a fresh code.
  Future<void> resumeVerification(String email) async {
    _pendingEmail = email.trim();
    _notify();
    try {
      await resendCode();
    } on EchoError {
      // Offline or rate limited: the code sent earlier may still work.
    }
  }

  Future<void> resendCode() async {
    final String? email = _pendingEmail;
    if (email == null) return;
    await _server.post(
      '/v1/auth/resend-code',
      body: <String, Object?>{'email': email},
    );
  }

  /// Leave the code screen (e.g. wrong address typed).
  void cancelVerification() {
    _pendingEmail = null;
    _notify();
  }

  // ── Sign-in ────────────────────────────────────────────────────────────

  /// Throws [AccountError] with code `totp_required` when the account has
  /// two-step sign-in; call again with [totp].
  Future<void> signIn({
    required String email,
    required String password,
    String? totp,
  }) async {
    _requireEmail(email);
    if (password.isEmpty) {
      throw const AccountError('invalid_password', 'Enter your password');
    }
    if ((totp ?? '').isNotEmpty && !RegExp(r'^\d{6}$').hasMatch(totp!.trim())) {
      throw const AccountError(
        'invalid_code',
        'The authenticator code is 6 digits',
      );
    }
    try {
      await _signIn(email: email, password: password, totp: totp);
    } on AccountError catch (e) {
      if (e.code == 'device_proof_invalid') {
        // Most likely the phone's clock: the failed answer taught us the
        // server's time, so try once more with the corrected clock.
        await _signIn(email: email, password: password, totp: totp);
        return;
      }
      // This device's key was removed from the account earlier. Signing in
      // again is a deliberate re-add: use a fresh key.
      if (e.code != 'device_revoked') rethrow;
      await _deviceKey.rotate();
      await _signIn(email: email, password: password, totp: totp);
    }
  }

  Future<void> _signIn({
    required String email,
    required String password,
    String? totp,
  }) async {
    final String norm = email.trim().toLowerCase();
    final SimpleKeyPair key = await _deviceKey.keyPair();
    // Before the first contact the offset is unknown (zero). If the clock
    // is far off the server answers device_proof_invalid, but that answer
    // carries a Date header, so one automatic retry fixes it.
    final int ts = _serverNow().millisecondsSinceEpoch;
    final List<int> sig = await DeviceProof.sign(
      deviceKey: key,
      purpose: 'login',
      subject: norm,
      timestampMs: ts,
    );
    final Map<String, dynamic> r = await _server.post(
      '/v1/auth/login',
      body: <String, Object?>{
        'email': norm,
        'password': password,
        if (totp != null && totp.trim().isNotEmpty) 'totp': totp.trim(),
        'device': <String, Object?>{
          'publicKey': base64.encode(await _deviceKey.publicKey()),
          'label': '$platform device',
          'platform': platform,
          'appVersion': appVersion,
          'secureStorage': secureKeyStorage,
        },
        'proofTimestamp': ts,
        'proofSignature': base64.encode(sig),
      },
    );
    _tokens = AuthTokens.fromJson(r);
    _account = Account.fromJson(r['account'] as Map<String, dynamic>);
    _pendingEmail = null;
    _signedOutReason = null;
    await _persist();
    _notify();
    unawaited(_quietly(ensureEscrow));
  }

  /// Signs out here and on the server. [reason], when given, is shown on
  /// the sign-in screen (e.g. after too many wrong account PINs).
  Future<void> signOut({String? reason}) async {
    final AuthTokens? t = _tokens;
    if (t != null) {
      try {
        await _server.post('/v1/auth/logout', token: t.accessToken);
      } catch (_) {
        // Offline or already invalid: signing out locally is what matters.
      }
    }
    await _clearSession(reason);
  }

  Future<void> forgotPassword(String email) {
    _requireEmail(email);
    return _server.post(
      '/v1/auth/password/forgot',
      body: <String, Object?>{'email': email.trim()},
    );
  }

  Future<void> resetPassword({
    required String email,
    required String code,
    required String newPassword,
  }) async {
    _requireEmail(email);
    _requireCode(code);
    final String? weak = localPasswordProblem(newPassword);
    if (weak != null) throw AccountError('weak_password', weak);
    await _server.post(
      '/v1/auth/password/reset',
      body: <String, Object?>{
        'email': email.trim(),
        'code': code.trim(),
        'newPassword': newPassword,
      },
    );
  }

  // ── Authorised requests ────────────────────────────────────────────────

  /// Sends an authenticated request, refreshing tokens as needed. Throws
  /// [OfflineError] when unreachable and [AccountError] when refused.
  Future<Map<String, dynamic>> authed(
    String method,
    String path, {
    Object? body,
  }) async {
    AuthTokens t = await _validTokens();
    try {
      return await _server.send(method, path, body: body, token: t.accessToken);
    } on AccountError catch (e) {
      if (e.status != 401) rethrow;
      t = await _refresh();
      return _server.send(method, path, body: body, token: t.accessToken);
    }
  }

  Future<AuthTokens> _validTokens() async {
    final AuthTokens? t = _tokens;
    if (t == null) {
      throw const AccountError(
        'unauthorized',
        'Sign in to continue',
        status: 401,
      );
    }
    if (t.accessUsableAt(_serverNow())) return t;
    return _refresh();
  }

  /// One refresh at a time: two concurrent refreshes with the same token
  /// would look like token theft to the server and sign the device out.
  Future<AuthTokens> _refresh() {
    final Future<AuthTokens>? inFlight = _refreshing;
    if (inFlight != null) return inFlight;
    final Future<AuthTokens> f = _doRefresh().whenComplete(
      () => _refreshing = null,
    );
    _refreshing = f;
    return f;
  }

  Future<AuthTokens> _doRefresh() async {
    final AuthTokens? t = _tokens;
    if (t == null) {
      throw const AccountError(
        'unauthorized',
        'Sign in to continue',
        status: 401,
      );
    }
    final int ts = _serverNow().millisecondsSinceEpoch;
    final List<int> sig = await DeviceProof.sign(
      deviceKey: await _deviceKey.keyPair(),
      purpose: 'refresh',
      subject: refreshSubject(t.refreshToken),
      timestampMs: ts,
    );
    try {
      final Map<String, dynamic> r = await _server.post(
        '/v1/auth/refresh',
        body: <String, Object?>{
          'refreshToken': t.refreshToken,
          'deviceId': t.deviceId,
          'proofTimestamp': ts,
          'proofSignature': base64.encode(sig),
        },
      );
      _tokens = AuthTokens.fromJson(r);
      await _persist();
      return _tokens!;
    } on AccountError catch (e) {
      // A bad proof is about this device's clock or key, not the session:
      // the server refused *before* using the refresh token, so it is
      // still good. Keep it and let the person fix the clock and retry,
      // rather than signing them out mid-emergency.
      if (e.code == 'device_proof_invalid') rethrow;
      if (e.status == 401 || e.status == 403) {
        await _clearSession(e.message);
      }
      rethrow;
    }
  }

  /// Must match the server: base64url(SHA-256(refresh token)).
  static String refreshSubject(String refreshToken) {
    return base64Url.encode(
      crypto.sha256.convert(utf8.encode(refreshToken)).bytes,
    );
  }

  // ── Profile, devices, two-step ─────────────────────────────────────────

  Future<void> refreshMe() async {
    final Map<String, dynamic> me = await authed('GET', '/v1/me');
    _account = Account.fromJson(me);
    await _persist();
    _notify();
  }

  Future<EscrowKey?> ensureEscrow() async {
    final EchoPinApi? api = _api;
    if (api == null) return null;
    try {
      final Map<String, dynamic> cfg = await api.get('/v1/config');
      final EscrowKey key = _pinCustodian(
        EscrowKey.fromJson(cfg['escrow'] as Map<String, dynamic>),
      );
      if (jsonEncode(key.toJson()) != jsonEncode(_escrow?.toJson())) {
        _escrow = key;
        await _kv.write(_kEscrow, jsonEncode(key.toJson()));
        _notify();
      }
    } on EchoError {
      // Offline: keep the cached key (possibly null until first contact).
    }
    return _escrow;
  }

  /// Decides which custodian key records are sealed to.
  ///
  /// SECURITY: a compromised server would like to drop the custodian key
  /// (so records are sealed only to keys it holds) or swap in its own.
  /// - A key built into the app always wins.
  /// - Otherwise, once this device has seen a custodian key, it never goes
  ///   back to single sealing: a config without one keeps the cached key.
  ///   A *different* key is accepted (organisations rotate them), so the
  ///   strongest setup builds the key into the app.
  EscrowKey _pinCustodian(EscrowKey fresh) {
    final List<int>? pinned = _pinnedCustodian;
    if (pinned != null) return fresh.withCustodian(pinned);
    if (!fresh.doubleSeal && (_escrow?.doubleSeal ?? false)) {
      return fresh.withCustodian(_escrow!.custodianPublicKey);
    }
    return fresh;
  }

  static List<int>? _decodeKey(String b64) {
    // Tolerate a dropped "=" pad or URL-safe alphabet: a key passed through
    // --dart-define or a host's settings page often loses one or the other.
    final String s = b64.trim();
    if (s.isEmpty) return null;
    try {
      final List<int> k = base64.decode(base64.normalize(s));
      return k.length == 32 ? k : null;
    } catch (_) {
      return null;
    }
  }

  // ── Custodian private keys (responders only) ───────────────────────────

  /// Imports a custodian key printed by `echopin_admin init-custodian`
  /// (`ECHOPIN-CUSTODIAN-1:…`). It stays in this device's secure storage
  /// and is never sent anywhere. Returns its key id.
  Future<String> importCustodianKey(String text) async {
    final String t = text.trim();
    const String prefix = 'ECHOPIN-CUSTODIAN-1:';
    if (!t.startsWith(prefix)) {
      throw const AccountError(
        'bad_custodian_key',
        'That is not an EchoPin custodian key. It starts with ECHOPIN-CUSTODIAN-1:',
      );
    }
    List<int> seed;
    try {
      seed = base64Url.decode(base64Url.normalize(t.substring(prefix.length)));
    } catch (_) {
      throw const AccountError(
        'bad_custodian_key',
        'That custodian key is damaged. Copy it again',
      );
    }
    if (seed.length != 32) {
      throw const AccountError(
        'bad_custodian_key',
        'That custodian key is damaged. Copy it again',
      );
    }
    final SimpleKeyPair kp = await X25519().newKeyPairFromSeed(seed);
    final String id = SealedBox.keyIdFor((await kp.extractPublicKey()).bytes);
    final Map<String, String> all = await _custodianPrivates();
    all[id] = base64.encode(seed);
    await _kv.write(_kCustodianPrivate, jsonEncode(all));
    _notify();
    return id;
  }

  /// Ids of the custodian keys on this device.
  Future<List<String>> custodianKeyIds() async =>
      (await _custodianPrivates()).keys.toList();

  Future<void> removeCustodianKey(String id) async {
    final Map<String, String> all = await _custodianPrivates();
    all.remove(id);
    await _kv.write(_kCustodianPrivate, jsonEncode(all));
    _notify();
  }

  /// Opens a record's inner seal, or returns null if this device doesn't
  /// hold that custodian key.
  Future<Map<String, dynamic>?> openInnerSeal({
    required String logId,
    required String custodianKeyId,
    required List<int> sealedInner,
  }) async {
    final String? seed = (await _custodianPrivates())[custodianKeyId];
    if (seed == null) return null;
    final SimpleKeyPair kp = await X25519().newKeyPairFromSeed(
      base64.decode(seed),
    );
    final List<int> clear = await SealedBox.open(
      recipient: kp,
      sealed: sealedInner,
      context: 'session-log-custodian:$logId',
    );
    return jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
  }

  Future<Map<String, String>> _custodianPrivates() async {
    try {
      final String? raw = await _kv.read(_kCustodianPrivate);
      if (raw == null) return <String, String>{};
      return (jsonDecode(raw) as Map<String, dynamic>).cast<String, String>();
    } catch (_) {
      return <String, String>{};
    }
  }

  Future<void> updateName(String name) async {
    final Map<String, dynamic> me = await authed(
      'PATCH',
      '/v1/me',
      body: <String, Object?>{'displayName': name.trim()},
    );
    _account = Account.fromJson(me);
    await _persist();
    _notify();
  }

  Future<void> changePassword(String current, String next) async {
    final String? weak = localPasswordProblem(next);
    if (weak != null) throw AccountError('weak_password', weak);
    await authed(
      'POST',
      '/v1/me/password',
      body: <String, Object?>{'currentPassword': current, 'newPassword': next},
    );
  }

  /// Returns `secret` (base32) and `otpauthUri` for the authenticator app.
  Future<Map<String, dynamic>> totpSetup() =>
      authed('POST', '/v1/me/totp/setup');

  Future<void> totpEnable(String code, {required String password}) async {
    await authed(
      'POST',
      '/v1/me/totp/enable',
      body: <String, Object?>{'code': code.trim(), 'password': password},
    );
    await refreshMe();
  }

  Future<void> totpDisable({
    required String password,
    required String code,
  }) async {
    await authed(
      'POST',
      '/v1/me/totp/disable',
      body: <String, Object?>{'password': password, 'code': code.trim()},
    );
    await refreshMe();
  }

  Future<List<Map<String, dynamic>>> devices() async {
    final Map<String, dynamic> r = await authed('GET', '/v1/me/devices');
    return (r['devices'] as List<dynamic>).cast<Map<String, dynamic>>();
  }

  Future<void> revokeDevice(String id) =>
      authed('DELETE', '/v1/me/devices/$id');

  Future<List<Map<String, dynamic>>> myReports() async {
    final Map<String, dynamic> r = await authed('GET', '/v1/me/reports');
    return (r['reports'] as List<dynamic>).cast<Map<String, dynamic>>();
  }

  // ── Internals ──────────────────────────────────────────────────────────

  Future<void> _persist() async {
    final Account? a = _account;
    final AuthTokens? t = _tokens;
    if (a == null || t == null) return;
    await _kv.write(
      _kAccount,
      jsonEncode(<String, Object?>{
        'account': a.toJson(),
        'tokens': t.toJson(),
      }),
    );
  }

  Future<void> _clearSession(String? reason) async {
    _account = null;
    _tokens = null;
    _signedOutReason = reason;
    await _kv.delete(_kAccount);
    _notify();
  }

  // Cheap local checks before a network round trip. The server repeats
  // them (it never trusts a client); these only make mistakes instant.
  static final RegExp _emailShape = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  static void _requireEmail(String email) {
    final String e = email.trim();
    if (e.isEmpty ||
        e.length > ProtocolLimits.maxEmail ||
        !_emailShape.hasMatch(e)) {
      throw const AccountError('invalid_email', 'Enter a valid email address');
    }
  }

  static void _requireCode(String code) {
    if (!RegExp(r'^\d{8}$').hasMatch(code.trim())) {
      throw const AccountError(
        'invalid_code',
        'The code from the email is 8 digits',
      );
    }
  }

  Future<void> _quietly(Future<Object?> Function() f) async {
    try {
      await f();
    } catch (_) {}
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Whether the app may talk to [url].
///
/// SECURITY: passwords and tokens travel in request bodies and headers, so
/// a release build only talks HTTPS. Plain `http://` is allowed in debug
/// and profile builds (a laptop server on the LAN) and for loopback
/// addresses. A release build pointed at `http://` behaves as if no server
/// were configured (fully local) rather than leak credentials.
bool serverUrlAllowed(String url) {
  if (url.isEmpty) return false;
  final Uri? u = Uri.tryParse(url);
  if (u == null || u.host.isEmpty) return false;
  if (u.scheme == 'https') return true;
  if (u.scheme != 'http') return false;
  const Set<String> loopback = <String>{
    'localhost',
    '127.0.0.1',
    '::1',
    '[::1]',
  };
  if (loopback.contains(u.host)) return true;
  if (!kReleaseMode) return true;
  debugPrint('EchoPin: refusing plain-http server $url in a release build');
  return false;
}

/// The same rules the server applies, checked first so a weak password is
/// caught without a round trip (and offline).
String? localPasswordProblem(String password) {
  if (password.length < ProtocolLimits.minPasswordLength) {
    return 'Use at least ${ProtocolLimits.minPasswordLength} characters';
  }
  if (password.length > ProtocolLimits.maxPasswordLength) {
    return 'Use at most ${ProtocolLimits.maxPasswordLength} characters';
  }
  if (password.split('').toSet().length < 4) {
    return 'That password is too repetitive';
  }
  return null;
}
