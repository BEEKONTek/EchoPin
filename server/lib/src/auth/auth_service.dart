import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:echopin_protocol/echopin_protocol.dart';
import 'package:logging/logging.dart';

import '../api/http.dart';
import '../db/database.dart';
import '../mail/mailer.dart';
import '../security/audit.dart';
import '../security/keys.dart';
import '../security/rate_limit.dart';
import '../security/tokens.dart';
import 'breach_check.dart';
import 'passwords.dart';
import 'totp.dart';

final Logger _log = Logger('auth');

/// The authenticated caller of a request.
class AuthContext {
  const AuthContext({
    required this.accountId,
    required this.email,
    required this.displayName,
    required this.role,
    required this.deviceId,
    required this.authSessionId,
    required this.ip,
    this.twoStep = false,
    this.staffTwoStepRequired = false,
  });

  final String accountId;
  final String email;
  final String displayName;
  final AccountRole role;
  final String deviceId;
  final String authSessionId;
  final String ip;

  /// Whether this account has two-step sign-in switched on.
  final bool twoStep;

  /// Server policy: staff roles only count when two-step is on.
  final bool staffTwoStepRequired;

  AuditActor get actor => AuditActor(id: accountId, label: email, ip: ip);

  /// Refuses callers below [min]. Every console method calls this itself.
  ///
  /// SECURITY: staff accounts (responder, admin) can open sealed emergency
  /// records. When the server requires it (the default), such a role only
  /// takes effect once two-step sign-in is on, so a phished or reused
  /// password alone never reaches those records.
  void require(AccountRole min) {
    if (!role.atLeast(min)) throw ApiException.forbidden;
    if (min != AccountRole.member && staffTwoStepRequired && !twoStep) {
      throw const ApiException(
        403,
        'two_step_required',
        'Turn on two-step sign-in (Account → Two-step sign-in) to use the '
            'console. Staff accounts can open emergency records, so a '
            'password alone is not enough',
      );
    }
  }
}

class IssuedTokens {
  const IssuedTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.accessExpiresAt,
    required this.refreshExpiresAt,
    required this.deviceId,
  });

  final String accessToken;
  final String refreshToken;
  final DateTime accessExpiresAt;
  final DateTime refreshExpiresAt;
  final String deviceId;

  Map<String, Object?> toJson() => <String, Object?>{
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'accessExpiresAt': accessExpiresAt,
    'refreshExpiresAt': refreshExpiresAt,
    'deviceId': deviceId,
  };
}

class DeviceRegistration {
  const DeviceRegistration({
    required this.publicKey,
    required this.label,
    required this.platform,
    this.appVersion,
    this.secureStorage = true,
  });

  final List<int> publicKey;
  final String label;
  final String platform;
  final String? appVersion;

  /// False when the app had to keep its device key in plain app storage
  /// (no OS keystore). Such devices get shorter refresh tokens.
  final bool secureStorage;
}

/// Accounts, sign-in, tokens and second factors.
///
/// Every time comes from [clock] (never SQL `now()`), so expiry and lockout
/// behave identically in tests and production.
class AuthService {
  AuthService({
    required Db db,
    required ServerKeys keys,
    required Mailer mailer,
    required AuditLog audit,
    PasswordHasher hasher = const PasswordHasher(),
    Limiter? limiter,
    BreachChecker breachChecker = const NoBreachChecker(),
    DateTime Function()? clock,
    this.accessTtl = const Duration(minutes: 30),
    this.refreshTtl = const Duration(days: 30),
    this.plainStorageRefreshTtl = const Duration(days: 7),
    this.codeTtl = const Duration(minutes: 15),
    this.maxDevices = 20,
    this.mailInBackground = true,
    this.minPublicResponse = const Duration(milliseconds: 600),
    this.requireStaffTwoStep = false,
  }) : _db = db,
       _keys = keys,
       _mailer = mailer,
       _audit = audit,
       _hasher = hasher,
       _limiter = limiter ?? RateLimiter(clock: clock),
       _breach = breachChecker,
       _clock = clock ?? DateTime.now;

  final Db _db;
  final ServerKeys _keys;
  final Mailer _mailer;
  final AuditLog _audit;
  final PasswordHasher _hasher;
  final Limiter _limiter;
  final BreachChecker _breach;
  final DateTime Function() _clock;
  final Duration accessTtl;
  final Duration refreshTtl;

  /// Refresh lifetime for devices whose key sits in plain storage.
  final Duration plainStorageRefreshTtl;
  final Duration codeTtl;
  final int maxDevices;

  /// Send code emails without waiting for the mail provider.
  ///
  /// SECURITY: waiting would make "this email has an account" visibly
  /// slower than "it doesn't" (and a mail error would only ever surface for
  /// real accounts). Failures are logged and written to the audit log.
  final bool mailInBackground;

  /// Public endpoints that must not reveal whether an email is registered
  /// (register, resend, forgot, verify, reset) take at least this long, so
  /// the different amounts of work behind the scenes don't show in timing.
  final Duration minPublicResponse;

  /// See [AuthContext.require].
  final bool requireStaffTwoStep;

  static const int lockAfterFailures = 5;
  static const int maxCodeAttempts = 5;

  DateTime get _now => _clock().toUtc();

  // ── Registration and verification ──────────────────────────────────────

  /// Always answers the same way, and in about the same time, whether or
  /// not the email is taken, so the endpoint can't be used to discover who
  /// has an account. The existing owner gets a heads-up email instead.
  Future<void> register({
    required String email,
    required String password,
    required String displayName,
    required String ip,
  }) => _uniformTime(() async {
    final String norm = normalizeEmail(email);
    final String name = cleanDisplayName(displayName);
    final String? weak = passwordProblem(password, email: norm);
    if (weak != null) throw ApiException(400, 'weak_password', weak);
    await _limit('register-ip:$ip', 10, const Duration(hours: 1));
    await _limit('register-email:$norm', 5, const Duration(hours: 1));
    await _rejectBreached(password);

    final Row? existing = await _accountByEmail(norm);
    final DateTime now = _now;
    // Hash in every branch: skipping it for taken emails would make them
    // answer ~100 ms faster, which is exactly the leak we're avoiding.
    final String hash = await _hasher.hash(password);
    if (existing != null && existing['status'] != 'pending') {
      await _mail(
        norm,
        'Someone tried to create an EchoPin account with your email',
        'You already have an EchoPin account. If this was you, sign in '
            'instead or reset your password. If not, you can ignore this.',
      );
      return;
    }
    final String accountId = await _db.tx((DbSession tx) async {
      if (existing == null) {
        final Row row = (await tx.one(
          '''insert into accounts
               (email, email_normalized, display_name, password_hash,
                created_at, updated_at)
             values (@email, @norm, @name, @hash, @now, @now) returning id''',
          <String, Object?>{
            'email': email.trim(),
            'norm': norm,
            'name': name,
            'hash': hash,
            'now': now,
          },
        ))!;
        await _audit.recordIn(
          tx,
          AuditActor(id: row['id'] as String, label: norm, ip: ip),
          'account.registered',
          target: row['id'] as String,
        );
        return row['id'] as String;
      }
      // Still pending: the newest sign-up's password wins, but activating
      // it needs the code *and* this password (see verifyEmail).
      await tx.execute(
        '''update accounts set display_name = @name, password_hash = @hash,
             updated_at = @now where id = @id::uuid''',
        <String, Object?>{
          'name': name,
          'hash': hash,
          'now': now,
          'id': existing['id'],
        },
      );
      return existing['id'] as String;
    });
    await _issueCode(accountId, norm, 'verify');
  });

  Future<void> resendVerification({required String email, required String ip}) =>
      _uniformTime(() async {
        final String norm = normalizeEmail(email);
        await _limit('resend-ip:$ip', 10, const Duration(hours: 1));
        await _limit('resend-email:$norm', 3, const Duration(minutes: 15));
        final Row? a = await _accountByEmail(norm);
        if (a != null && a['status'] == 'pending') {
          await _issueCode(a['id'] as String, norm, 'verify');
        }
      });

  /// Activates a pending account. Needs the emailed code *and* the
  /// password chosen at sign-up.
  ///
  /// SECURITY: why the password? Re-registering a still-pending email
  /// replaces its password (so someone who mistyped theirs can start
  /// again). Without this check an attacker could register a victim's
  /// address right after the victim did: the victim then types the code
  /// from their inbox and unknowingly activates an account whose password
  /// the attacker chose ("account pre-hijacking"). Requiring the password
  /// here means only the person who set it can switch the account on.
  ///
  /// The code is checked first (it burns an attempt) so this endpoint can't
  /// be used to guess passwords without access to the inbox. Unknown,
  /// active and pending emails all get the same "wrong or expired" answer.
  Future<void> verifyEmail({
    required String email,
    required String code,
    required String password,
    required String ip,
  }) => _uniformTime(() async {
    final String norm = normalizeEmail(email);
    await _limit('verify-ip:$ip', 20, const Duration(minutes: 10));
    final Row? a = await _accountByEmail(norm);
    if (a == null || a['status'] != 'pending') throw _badCode;
    final String id = a['id'] as String;
    await _consumeCode(id, 'verify', code);
    // Read the hash again *after* the code is used: it may have changed.
    final Row fresh = (await _db.one(
      'select password_hash from accounts where id = @id::uuid',
      <String, Object?>{'id': id},
    ))!;
    final String hash = fresh['password_hash'] as String;
    if (!await _hasher.verify(password, hash)) {
      throw const ApiException(
        409,
        'password_mismatch',
        'That password does not match this sign-up. Create the account '
            'again with the password you want; we will send a new code',
      );
    }
    await _db.tx((DbSession tx) async {
      // `password_hash = @hash` makes this a compare-and-set: if someone
      // re-registered in the last few milliseconds, nothing is activated.
      final int n = await tx.execute(
        '''update accounts set status = 'active', email_verified_at = @now,
             updated_at = @now
           where id = @id::uuid and status = 'pending' and password_hash = @hash''',
        <String, Object?>{'now': _now, 'id': id, 'hash': hash},
      );
      if (n == 0) {
        throw const ApiException(409, 'password_mismatch',
            'This sign-up changed while you were confirming it. Create the account again');
      }
      await _audit.recordIn(
        tx,
        AuditActor(id: id, label: norm, ip: ip),
        'account.verified',
        target: id,
      );
    });
  });

  // ── Sign-in and tokens ─────────────────────────────────────────────────

  /// Signs in with email, password, a device proof and (if enabled) an
  /// authenticator code.
  ///
  /// Order matters:
  /// 1. Per-IP limit.
  /// 2. Device proof. Cheap, and it tells us whether this is one of the
  ///    account's own registered devices.
  /// 3. Lockout. SECURITY: the lock is kept per *email* in
  ///    `login_throttle`, for addresses with and without accounts alike, so
  ///    "locked" never reveals that an address is registered. And the
  ///    account's **own devices skip the lock**. Anyone can lock an email
  ///    by typing wrong passwords, but only from devices the account has
  ///    never used, so a stranger can't keep the owner out of their own
  ///    phone. Known devices are rate limited per device key instead.
  /// 4. Password, status, second factor, then tokens.
  Future<(IssuedTokens, Map<String, Object?>)> login({
    required String email,
    required String password,
    String? totpCode,
    required DeviceRegistration device,
    required int proofTimestampMs,
    required List<int> proofSignature,
    required String ip,
  }) async {
    final String norm = normalizeEmail(email);
    await _limit('login-ip:$ip', 30, const Duration(minutes: 10));
    final DateTime now = _now;

    final bool proofOk = await DeviceProof.verify(
      publicKey: device.publicKey,
      signature: proofSignature,
      purpose: 'login',
      subject: norm,
      timestampMs: proofTimestampMs,
      now: now,
    );
    if (!proofOk) {
      throw const ApiException(
        400,
        'device_proof_invalid',
        'This device could not prove its identity. Check the date and time '
            'on your phone, then try again',
      );
    }

    final Row? a = await _accountByEmail(norm);
    final bool knownDevice = a != null &&
        await _db.one(
              '''select 1 as x from devices where account_id = @a::uuid
                   and public_key = @k and revoked_at is null''',
              <String, Object?>{'a': a['id'], 'k': Uint8List.fromList(device.publicKey)},
            ) !=
            null;
    if (knownDevice) {
      await _limit('login-device:${base64.encode(device.publicKey)}', 10, const Duration(minutes: 10));
    } else {
      await _limit('login-email:$norm', 10, const Duration(minutes: 10));
      final DateTime? lockedUntil = await _lockedUntil(norm);
      if (lockedUntil != null && lockedUntil.isAfter(now)) {
        throw _locked(lockedUntil.difference(now));
      }
    }

    if (a == null) {
      await _hasher.dummyVerify(password);
      await _recordFailure(norm, null, ip);
      throw _badCredentials;
    }
    final String id = a['id'] as String;
    if (!await _hasher.verify(password, a['password_hash'] as String)) {
      if (!knownDevice) await _recordFailure(norm, id, ip);
      throw _badCredentials;
    }
    switch (a['status']) {
      case 'pending':
        throw const ApiException(
          403,
          'email_unverified',
          'Confirm your email first. We sent you a code',
        );
      case 'disabled':
        throw _disabled;
    }

    final Uint8List? totpEnc = a['totp_secret_enc'] as Uint8List?;
    int? totpStep;
    if (totpEnc != null) {
      if (totpCode == null || totpCode.trim().isEmpty) {
        throw const ApiException(
          401,
          'totp_required',
          'Enter the 6-digit code from your authenticator app',
        );
      }
      final List<int> secret = await _keys.decryptData(totpEnc, context: 'totp:$id');
      totpStep = Totp.verify(
        secret,
        totpCode,
        now,
        lastUsedStep: a['totp_last_step'] as int?,
      );
      if (totpStep == null) {
        if (!knownDevice) await _recordFailure(norm, id, ip);
        throw const ApiException(
          401,
          'totp_invalid',
          'That authenticator code is not right. Codes change every 30 seconds',
        );
      }
    }

    final IssuedTokens tokens = await _db.tx((DbSession tx) async {
      if (totpStep != null) {
        // Compare-and-set on the last used step. Two sign-ins racing with
        // the same code both passed the check above; only one may win, or a
        // code seen over someone's shoulder could be used twice.
        final int n = await tx.execute(
          '''update accounts set totp_last_step = @step where id = @id::uuid
               and (totp_last_step is null or totp_last_step < @step)''',
          <String, Object?>{'step': totpStep, 'id': id},
        );
        if (n == 0) {
          throw const ApiException(401, 'totp_invalid',
              'That authenticator code was already used. Wait for the next one');
        }
      }
      await tx.execute(
        'update accounts set last_login_at = @now where id = @id::uuid',
        <String, Object?>{'now': now, 'id': id},
      );
      // A success from a *new* device ends any lock. A success from a known
      // device leaves it, so the owner signing in on their phone doesn't
      // hand an ongoing attacker a fresh set of guesses.
      if (!knownDevice) {
        await tx.execute('delete from login_throttle where email = @e', <String, Object?>{'e': norm});
      }
      final (String deviceId, bool secure) = await _upsertDevice(tx, id, device, now);
      final IssuedTokens t = await _createSession(
        tx,
        accountId: id,
        deviceId: deviceId,
        family: null,
        now: now,
        secureStorage: secure,
      );
      await _audit.recordIn(
        tx,
        AuditActor(id: id, label: norm, ip: ip),
        'auth.login',
        target: deviceId,
        detail: <String, Object?>{
          'device': device.label,
          'platform': device.platform,
          if (!device.secureStorage) 'keyStorage': 'plain',
        },
      );
      return t;
    });
    return (tokens, (await accountJson(id))!);
  }

  Future<IssuedTokens> refresh({
    required String refreshToken,
    required String deviceId,
    required int proofTimestampMs,
    required List<int> proofSignature,
    required String ip,
  }) async {
    await _limit('refresh-ip:$ip', 120, const Duration(minutes: 10));
    final DateTime now = _now;
    final Uint8List hash = Tokens.hash(refreshToken);

    // A detected reuse must revoke the family and *commit* before we
    // refuse, so the transaction returns an outcome instead of throwing.
    final Object outcome = await _db.tx((DbSession tx) async {
      final Row? s = await tx.one(
        '''select s.id, s.account_id, s.device_id, s.family, s.replaced_by,
                  s.revoked_at, s.refresh_expires_at, d.public_key, d.secure_storage,
                  d.revoked_at as device_revoked, a.status, a.email_normalized
             from auth_sessions s
             join devices d on d.id = s.device_id
             join accounts a on a.id = s.account_id
            where s.refresh_hash = @h
            for update of s''',
        <String, Object?>{'h': hash},
      );
      if (s == null) return _invalidRefresh;
      if (s['replaced_by'] != null) {
        await tx.execute(
          '''update auth_sessions set revoked_at = @now,
               revoked_reason = 'refresh_reuse'
             where family = @f::uuid and revoked_at is null''',
          <String, Object?>{'now': now, 'f': s['family']},
        );
        await _audit.recordIn(
          tx,
          AuditActor(
            id: s['account_id'] as String,
            label: s['email_normalized'] as String,
            ip: ip,
          ),
          'auth.refresh_reuse_detected',
          target: s['device_id'] as String,
          detail: const <String, Object?>{'effect': 'token family revoked'},
        );
        return const ApiException(
          401,
          'session_revoked',
          'For your safety this device was signed out. Sign in again',
        );
      }
      if (s['revoked_at'] != null) {
        return const ApiException(401, 'session_revoked', 'Sign in again to continue');
      }
      if ((s['refresh_expires_at'] as DateTime).isBefore(now)) {
        return const ApiException(
          401,
          'session_expired',
          'You have been away a while. Sign in again',
        );
      }
      if (s['device_id'] != deviceId) return _invalidRefresh;
      if (s['device_revoked'] != null) {
        return const ApiException(
          401,
          'device_revoked',
          'This device was removed from your account. Sign in again',
        );
      }
      if (s['status'] != 'active') return _disabled;
      final bool proofOk = await DeviceProof.verify(
        publicKey: s['public_key'] as List<int>,
        signature: proofSignature,
        purpose: 'refresh',
        subject: refreshSubject(refreshToken),
        timestampMs: proofTimestampMs,
        now: now,
      );
      if (!proofOk) {
        return const ApiException(
          401,
          'device_proof_invalid',
          'This device could not prove its identity. Check the date and time '
              'on your phone, then sign in again',
        );
      }
      final IssuedTokens t = await _createSession(
        tx,
        accountId: s['account_id'] as String,
        deviceId: deviceId,
        family: s['family'] as String,
        now: now,
        replacing: s['id'] as String,
        secureStorage: s['secure_storage'] as bool,
      );
      await tx.execute(
        'update devices set last_seen_at = @now where id = @id::uuid',
        <String, Object?>{'now': now, 'id': deviceId},
      );
      return t;
    });
    if (outcome is ApiException) throw outcome;
    return outcome as IssuedTokens;
  }

  /// What a refresh proof signs: a digest of the token, so the secret
  /// itself never appears in signed material.
  static String refreshSubject(String refreshToken) =>
      base64Url.encode(sha256.convert(utf8.encode(refreshToken)).bytes);

  Future<AuthContext> authenticate(String? authorization, String ip) async {
    if (authorization == null || !authorization.startsWith('Bearer ')) {
      throw ApiException.unauthorized;
    }
    final String token = authorization.substring(7).trim();
    if (token.isEmpty) throw ApiException.unauthorized;
    final DateTime now = _now;
    final Row? r = await _db.one(
      '''select s.id as sid, s.device_id, a.id, a.email_normalized,
                a.display_name, a.role, d.last_seen_at,
                a.totp_secret_enc is not null as two_step
           from auth_sessions s
           join accounts a on a.id = s.account_id
           join devices d on d.id = s.device_id
          where s.access_hash = @h and s.revoked_at is null
            and s.replaced_by is null and s.access_expires_at > @now
            and a.status = 'active' and d.revoked_at is null''',
      <String, Object?>{'h': Tokens.hash(token), 'now': now},
    );
    if (r == null) throw ApiException.unauthorized;
    final DateTime lastSeen = r['last_seen_at'] as DateTime;
    if (now.difference(lastSeen) > const Duration(minutes: 5)) {
      unawaited(
        _db
            .execute(
              'update devices set last_seen_at = @now where id = @id::uuid',
              <String, Object?>{'now': now, 'id': r['device_id']},
            )
            .catchError((Object _) => 0),
      );
    }
    return AuthContext(
      accountId: r['id'] as String,
      email: r['email_normalized'] as String,
      displayName: r['display_name'] as String,
      role: AccountRole.fromWire(r['role']) ?? AccountRole.member,
      deviceId: r['device_id'] as String,
      authSessionId: r['sid'] as String,
      ip: ip,
      twoStep: r['two_step'] as bool,
      staffTwoStepRequired: requireStaffTwoStep,
    );
  }

  Future<void> logout(AuthContext ctx) async {
    await _db.execute(
      '''update auth_sessions set revoked_at = @now, revoked_reason = 'logout'
         where id = @id::uuid and revoked_at is null''',
      <String, Object?>{'now': _now, 'id': ctx.authSessionId},
    );
  }

  // ── Passwords ──────────────────────────────────────────────────────────

  /// Same answer, in about the same time, for every address.
  Future<void> forgotPassword({required String email, required String ip}) =>
      _uniformTime(() async {
        final String norm = normalizeEmail(email);
        await _limit('forgot-ip:$ip', 10, const Duration(hours: 1));
        await _limit('forgot-email:$norm', 3, const Duration(minutes: 15));
        final Row? a = await _accountByEmail(norm);
        if (a != null && a['status'] == 'active') {
          await _issueCode(a['id'] as String, norm, 'reset');
        }
      });

  Future<void> resetPassword({
    required String email,
    required String code,
    required String newPassword,
    required String ip,
  }) => _uniformTime(() async {
    final String norm = normalizeEmail(email);
    await _limit('reset-ip:$ip', 20, const Duration(minutes: 10));
    final String? weak = passwordProblem(newPassword, email: norm);
    if (weak != null) throw ApiException(400, 'weak_password', weak);
    await _rejectBreached(newPassword);
    final Row? a = await _accountByEmail(norm);
    if (a == null || a['status'] != 'active') throw _badCode;
    final String id = a['id'] as String;
    await _consumeCode(id, 'reset', code);
    final String hash = await _hasher.hash(newPassword);
    await _db.tx((DbSession tx) async {
      await tx.execute(
        'update accounts set password_hash = @hash, updated_at = @now where id = @id::uuid',
        <String, Object?>{'hash': hash, 'now': _now, 'id': id},
      );
      // Proving control of the inbox ends any sign-in lock.
      await tx.execute('delete from login_throttle where email = @e', <String, Object?>{'e': norm});
      await _revokeAll(tx, id, 'password_reset');
      await _audit.recordIn(
        tx,
        AuditActor(id: id, label: norm, ip: ip),
        'auth.password_reset',
        target: id,
      );
    });
  });

  Future<void> changePassword(
    AuthContext ctx, {
    required String current,
    required String next,
  }) async {
    await _limit('change-pw:${ctx.accountId}', 5, const Duration(minutes: 15));
    final Row a = (await _db.one(
      'select password_hash from accounts where id = @id::uuid',
      <String, Object?>{'id': ctx.accountId},
    ))!;
    if (!await _hasher.verify(current, a['password_hash'] as String)) {
      throw const ApiException(400, 'wrong_password', 'Your current password is not right');
    }
    final String? weak = passwordProblem(next, email: ctx.email);
    if (weak != null) throw ApiException(400, 'weak_password', weak);
    await _rejectBreached(next);
    final String hash = await _hasher.hash(next);
    await _db.tx((DbSession tx) async {
      await tx.execute(
        'update accounts set password_hash = @hash, updated_at = @now where id = @id::uuid',
        <String, Object?>{'hash': hash, 'now': _now, 'id': ctx.accountId},
      );
      await _revokeAll(tx, ctx.accountId, 'password_changed', except: ctx.authSessionId);
      await _audit.recordIn(tx, ctx.actor, 'auth.password_changed', target: ctx.accountId);
    });
  }

  // ── Two-factor ─────────────────────────────────────────────────────────

  Future<Map<String, Object?>> totpSetup(AuthContext ctx) async {
    final Row a = (await _db.one(
      'select totp_secret_enc from accounts where id = @id::uuid',
      <String, Object?>{'id': ctx.accountId},
    ))!;
    if (a['totp_secret_enc'] != null) {
      throw const ApiException(
        409,
        'totp_already_enabled',
        'Two-step sign-in is already on. Turn it off first to set it up again',
      );
    }
    final List<int> secret = Totp.newSecret();
    await _db.execute(
      'update accounts set totp_pending_enc = @enc where id = @id::uuid',
      <String, Object?>{
        'enc': await _keys.encryptData(secret, context: 'totp-pending:${ctx.accountId}'),
        'id': ctx.accountId,
      },
    );
    return <String, Object?>{
      'secret': Totp.base32(secret),
      'otpauthUri': Totp.otpauthUri(secret: secret, account: ctx.email),
    };
  }

  /// Turns two-step sign-in on. Needs the current password as well as a
  /// code from the new authenticator.
  ///
  /// SECURITY: without the password, anyone who got hold of an access
  /// token for 30 minutes could switch on two-step with *their own*
  /// authenticator and lock the real owner out of every new sign-in.
  Future<void> totpEnable(AuthContext ctx, String code, {required String password}) async {
    await _limit('totp-on:${ctx.accountId}', 5, const Duration(minutes: 15));
    final Row a = (await _db.one(
      'select totp_pending_enc, password_hash from accounts where id = @id::uuid',
      <String, Object?>{'id': ctx.accountId},
    ))!;
    if (!await _hasher.verify(password, a['password_hash'] as String)) {
      throw const ApiException(400, 'wrong_password', 'Your password is not right');
    }
    final Uint8List? pending = a['totp_pending_enc'] as Uint8List?;
    if (pending == null) {
      throw const ApiException(409, 'totp_not_started', 'Start two-step setup first');
    }
    final List<int> secret = await _keys.decryptData(
      pending,
      context: 'totp-pending:${ctx.accountId}',
    );
    final int? step = Totp.verify(secret, code, _now);
    if (step == null) {
      throw const ApiException(
        400,
        'totp_invalid',
        'That code is not right. Check the time on your phone and use the newest code',
      );
    }
    await _db.tx((DbSession tx) async {
      await tx.execute(
        '''update accounts set totp_secret_enc = @enc, totp_pending_enc = null,
             totp_last_step = @step, updated_at = @now where id = @id::uuid''',
        <String, Object?>{
          'enc': await _keys.encryptData(secret, context: 'totp:${ctx.accountId}'),
          'step': step,
          'now': _now,
          'id': ctx.accountId,
        },
      );
      await _audit.recordIn(tx, ctx.actor, 'auth.totp_enabled', target: ctx.accountId);
    });
  }

  Future<void> totpDisable(
    AuthContext ctx, {
    required String password,
    required String code,
  }) async {
    await _limit('totp-off:${ctx.accountId}', 5, const Duration(minutes: 15));
    final Row a = (await _db.one(
      'select password_hash, totp_secret_enc, totp_last_step from accounts where id = @id::uuid',
      <String, Object?>{'id': ctx.accountId},
    ))!;
    final Uint8List? enc = a['totp_secret_enc'] as Uint8List?;
    if (enc == null) return;
    if (!await _hasher.verify(password, a['password_hash'] as String)) {
      throw const ApiException(400, 'wrong_password', 'Your password is not right');
    }
    final List<int> secret = await _keys.decryptData(enc, context: 'totp:${ctx.accountId}');
    if (Totp.verify(secret, code, _now, lastUsedStep: a['totp_last_step'] as int?) == null) {
      throw const ApiException(400, 'totp_invalid', 'That authenticator code is not right');
    }
    await _db.tx((DbSession tx) async {
      await tx.execute(
        '''update accounts set totp_secret_enc = null, totp_last_step = null,
             updated_at = @now where id = @id::uuid''',
        <String, Object?>{'now': _now, 'id': ctx.accountId},
      );
      await _audit.recordIn(tx, ctx.actor, 'auth.totp_disabled', target: ctx.accountId);
    });
  }

  // ── Profile and devices ────────────────────────────────────────────────

  Future<Map<String, Object?>?> accountJson(String id) async {
    final Row? a = await _db.one(
      '''select id, email, display_name, role, status, created_at, last_login_at,
                totp_secret_enc is not null as totp_enabled
           from accounts where id = @id::uuid''',
      <String, Object?>{'id': id},
    );
    if (a == null) return null;
    return <String, Object?>{
      'id': a['id'],
      'email': a['email'],
      'displayName': a['display_name'],
      'role': a['role'],
      'status': a['status'],
      'totpEnabled': a['totp_enabled'],
      'createdAt': a['created_at'],
      'lastLoginAt': a['last_login_at'],
    };
  }

  Future<void> updateProfile(AuthContext ctx, {required String displayName}) async {
    await _db.execute(
      'update accounts set display_name = @n, updated_at = @now where id = @id::uuid',
      <String, Object?>{
        'n': cleanDisplayName(displayName),
        'now': _now,
        'id': ctx.accountId,
      },
    );
  }

  Future<List<Map<String, Object?>>> devices(String accountId) async {
    final List<Row> rows = await _db.query(
      '''select id, label, platform, app_version, created_at, last_seen_at, revoked_at,
                secure_storage
           from devices where account_id = @id::uuid
          order by revoked_at nulls first, last_seen_at desc''',
      <String, Object?>{'id': accountId},
    );
    return rows
        .map(
          (Row r) => <String, Object?>{
            'id': r['id'],
            'label': r['label'],
            'platform': r['platform'],
            'appVersion': r['app_version'],
            'createdAt': r['created_at'],
            'lastSeenAt': r['last_seen_at'],
            'revokedAt': r['revoked_at'],
            'secureStorage': r['secure_storage'],
          },
        )
        .toList();
  }

  Future<void> revokeDevice(String accountId, String deviceId, AuditActor actor) async {
    await _db.tx((DbSession tx) async {
      final int n = await tx.execute(
        '''update devices set revoked_at = @now
           where id = @d::uuid and account_id = @a::uuid and revoked_at is null''',
        <String, Object?>{'now': _now, 'd': deviceId, 'a': accountId},
      );
      if (n == 0) throw ApiException.notFound('That device');
      await tx.execute(
        '''update auth_sessions set revoked_at = @now, revoked_reason = 'device_revoked'
           where device_id = @d::uuid and revoked_at is null''',
        <String, Object?>{'now': _now, 'd': deviceId},
      );
      await _audit.recordIn(tx, actor, 'device.revoked', target: deviceId,
          detail: <String, Object?>{'account': accountId});
    });
  }

  /// Signs an account out everywhere (admin action or password change).
  Future<int> revokeAllSessions(String accountId, String reason) =>
      _db.tx((DbSession tx) => _revokeAll(tx, accountId, reason));

  // ── Internals ──────────────────────────────────────────────────────────

  Future<void> _limit(String key, int limit, Duration window) async {
    final Duration? wait = await _limiter.hit(key, limit: limit, window: window);
    if (wait != null) throw ApiException.tooMany(wait);
  }

  /// Runs [body] and makes sure the whole thing takes at least
  /// [minPublicResponse], success or failure. Used by endpoints whose
  /// answer must not reveal whether an email is registered: without it,
  /// "no such account" returns noticeably sooner than "account found, code
  /// stored and mailed".
  Future<T> _uniformTime<T>(Future<T> Function() body) async {
    final Stopwatch sw = Stopwatch()..start();
    try {
      return await body();
    } finally {
      final Duration left = minPublicResponse - sw.elapsed;
      if (left > Duration.zero) await Future<void>.delayed(left);
    }
  }

  /// Refuses passwords seen in public breaches (see [BreachChecker]).
  Future<void> _rejectBreached(String password) async {
    final int n = await _breach.timesBreached(password);
    if (n > 0) {
      throw ApiException(
        400,
        'breached_password',
        'This password has appeared in a data breach${n > 1 ? ' $n times' : ''}, so '
            'attackers try it first. Choose a different one (a short phrase works well)',
      );
    }
  }

  Future<Row?> _accountByEmail(String norm) => _db.one(
    '''select id, status, password_hash, totp_secret_enc, totp_last_step
         from accounts where email_normalized = @e''',
    <String, Object?>{'e': norm},
  );

  /// When sign-ins for [norm] from unknown devices are paused, or null.
  Future<DateTime?> _lockedUntil(String norm) async {
    final Row? r = await _db.one(
      'select locked_until from login_throttle where email = @e',
      <String, Object?>{'e': norm},
    );
    return r?['locked_until'] as DateTime?;
  }

  /// Counts a wrong password or authenticator code for [norm] (with or
  /// without an account), pausing sign-ins from unknown devices after
  /// [lockAfterFailures]: 15 minutes, doubling with each further failure,
  /// capped at a day. Failures older than a day are forgotten.
  ///
  /// SECURITY: the row is locked (`for update`) while it is read and
  /// written, so 50 wrong guesses sent at the same moment are counted as 50,
  /// not as 1. Unknown emails are counted too: that is what makes their
  /// "locked" answer identical to a real account's.
  Future<void> _recordFailure(String norm, String? accountId, String ip) async {
    final DateTime now = _now;
    final (int failures, DateTime? lockUntil) = await _db.tx((DbSession tx) async {
      await tx.execute(
        '''insert into login_throttle (email, failures, updated_at) values (@e, 0, @now)
           on conflict (email) do nothing''',
        <String, Object?>{'e': norm, 'now': now},
      );
      final Row r = (await tx.one(
        'select failures, updated_at from login_throttle where email = @e for update',
        <String, Object?>{'e': norm},
      ))!;
      final bool stale = now.difference(r['updated_at'] as DateTime) > const Duration(days: 1);
      final int failures = (stale ? 0 : r['failures'] as int) + 1;
      DateTime? lockUntil;
      if (failures >= lockAfterFailures) {
        final int exp = (failures - lockAfterFailures).clamp(0, 7);
        final int minutes = (15 * (1 << exp)).clamp(15, 24 * 60);
        lockUntil = now.add(Duration(minutes: minutes));
      }
      await tx.execute(
        '''update login_throttle set failures = @f, locked_until = @l, updated_at = @now
           where email = @e''',
        <String, Object?>{'f': failures, 'l': lockUntil, 'now': now, 'e': norm},
      );
      return (failures, lockUntil);
    });
    if (lockUntil != null && accountId != null) {
      await _audit.record(
        _db,
        AuditActor(id: accountId, label: 'login', ip: ip),
        'auth.locked',
        target: accountId,
        detail: <String, Object?>{'failures': failures, 'until': lockUntil.toIso8601String()},
      );
    }
  }

  /// Registers or refreshes the device; returns its id and whether its key
  /// is in secure storage.
  Future<(String, bool)> _upsertDevice(
    DbSession tx,
    String accountId,
    DeviceRegistration d,
    DateTime now,
  ) async {
    final Row? existing = await tx.one(
      'select id, revoked_at from devices where account_id = @a::uuid and public_key = @k',
      <String, Object?>{'a': accountId, 'k': Uint8List.fromList(d.publicKey)},
    );
    if (existing != null) {
      if (existing['revoked_at'] != null) {
        throw const ApiException(
          403,
          'device_revoked',
          'This device was removed from your account. Sign in again to add it back',
        );
      }
      await tx.execute(
        '''update devices set label = @l, platform = @p, app_version = @v,
             secure_storage = @sec, last_seen_at = @now where id = @id::uuid''',
        <String, Object?>{
          'l': d.label,
          'p': d.platform,
          'v': d.appVersion,
          'sec': d.secureStorage,
          'now': now,
          'id': existing['id'],
        },
      );
      return (existing['id'] as String, d.secureStorage);
    }
    final Row count = (await tx.one(
      'select count(*)::int as n from devices where account_id = @a::uuid and revoked_at is null',
      <String, Object?>{'a': accountId},
    ))!;
    if ((count['n'] as int) >= maxDevices) {
      throw ApiException(
        409,
        'too_many_devices',
        'Your account is on $maxDevices devices already. Remove one in '
            'Account → Devices first',
      );
    }
    final Row row = (await tx.one(
      '''insert into devices
           (account_id, public_key, label, platform, app_version, secure_storage,
            created_at, last_seen_at)
         values (@a::uuid, @k, @l, @p, @v, @sec, @now, @now) returning id''',
      <String, Object?>{
        'a': accountId,
        'k': Uint8List.fromList(d.publicKey),
        'l': d.label,
        'p': d.platform,
        'v': d.appVersion,
        'sec': d.secureStorage,
        'now': now,
      },
    ))!;
    return (row['id'] as String, d.secureStorage);
  }

  Future<IssuedTokens> _createSession(
    DbSession tx, {
    required String accountId,
    required String deviceId,
    required String? family,
    required DateTime now,
    String? replacing,
    bool secureStorage = true,
  }) async {
    final String access = Tokens.random();
    final String refresh = Tokens.random();
    final DateTime accessExp = now.add(accessTtl);
    // A key in plain storage is easier to copy off the device, so its
    // sessions expire sooner and need a fresh password more often.
    final DateTime refreshExp = now.add(secureStorage ? refreshTtl : plainStorageRefreshTtl);
    final Row row = (await tx.one(
      '''insert into auth_sessions
           (account_id, device_id, family, access_hash, refresh_hash,
            access_expires_at, refresh_expires_at, created_at)
         values (@a::uuid, @d::uuid, coalesce(@f::uuid, gen_random_uuid()),
                 @ah, @rh, @ae, @re, @now)
         returning id''',
      <String, Object?>{
        'a': accountId,
        'd': deviceId,
        'f': family,
        'ah': Tokens.hash(access),
        'rh': Tokens.hash(refresh),
        'ae': accessExp,
        're': refreshExp,
        'now': now,
      },
    ))!;
    if (replacing != null) {
      await tx.execute(
        '''update auth_sessions set replaced_by = @new::uuid, revoked_at = @now,
             revoked_reason = 'rotated' where id = @old::uuid''',
        <String, Object?>{'new': row['id'], 'now': now, 'old': replacing},
      );
    }
    return IssuedTokens(
      accessToken: access,
      refreshToken: refresh,
      accessExpiresAt: accessExp,
      refreshExpiresAt: refreshExp,
      deviceId: deviceId,
    );
  }

  Future<int> _revokeAll(
    DbSession tx,
    String accountId,
    String reason, {
    String? except,
  }) {
    return tx.execute(
      '''update auth_sessions set revoked_at = @now, revoked_reason = @r
         where account_id = @a::uuid and revoked_at is null
           and (@except::uuid is null or id <> @except::uuid)''',
      <String, Object?>{'now': _now, 'r': reason, 'a': accountId, 'except': except},
    );
  }

  /// Most codes one account can be sent per purpose in 24 hours.
  static const int maxCodesPerDay = 10;

  /// Emails a fresh 6-digit code, replacing any unused one.
  ///
  /// SECURITY: each code allows [maxCodeAttempts] guesses. Without a cap on
  /// how many codes can be issued, an attacker could ask for code after
  /// code and keep guessing. The in-memory rate limiter resets whenever
  /// the server restarts (free hosts restart often), so the cap is counted
  /// in the database: at most 10 codes × 5 guesses = 50 guesses a day
  /// against a one-in-a-million code. When the cap is reached, nothing is
  /// sent, silently, so the endpoints still don't reveal which emails have
  /// accounts.
  Future<void> _issueCode(String accountId, String email, String purpose) async {
    final String code = Tokens.emailCode();
    final DateTime now = _now;
    final Row recent = (await _db.one(
      '''select count(*)::int as n from email_codes
          where account_id = @a::uuid and purpose = @p and created_at > @since''',
      <String, Object?>{'a': accountId, 'p': purpose, 'since': now.subtract(const Duration(days: 1))},
    ))!;
    if ((recent['n'] as int) >= maxCodesPerDay) {
      _log.warning('Daily $purpose code limit reached for account $accountId; not sending');
      return;
    }
    await _db.tx((DbSession tx) async {
      await tx.execute(
        '''update email_codes set used_at = @now
           where account_id = @a::uuid and purpose = @p and used_at is null''',
        <String, Object?>{'now': now, 'a': accountId, 'p': purpose},
      );
      await tx.execute(
        '''insert into email_codes (account_id, purpose, code_hash, expires_at, created_at)
           values (@a::uuid, @p, @h, @exp, @now)''',
        <String, Object?>{
          'a': accountId,
          'p': purpose,
          'h': Tokens.codeHash(accountId, purpose, code),
          'exp': now.add(codeTtl),
          'now': now,
        },
      );
    });
    final int minutes = codeTtl.inMinutes;
    if (purpose == 'verify') {
      await _mail(
        email,
        'Your EchoPin code: $code',
        'Your EchoPin verification code is $code\n\n'
            'It works for $minutes minutes. If you did not sign up, ignore this.',
      );
    } else {
      await _mail(
        email,
        'Reset your EchoPin password: $code',
        'Your EchoPin password reset code is $code\n\n'
            'It works for $minutes minutes. If you did not ask for this, '
            'ignore it; your password stays the same.',
      );
    }
  }

  /// Uses up the newest code for [purpose] if [code] matches.
  ///
  /// SECURITY: every failure (no code, expired, used up, wrong) gives the
  /// same [_badCode] answer. Saying "4 tries left" would confirm to anyone
  /// who triggered a reset that the address has an account. Attempts are
  /// still counted and enforced; the person just isn't told the number.
  Future<void> _consumeCode(String accountId, String purpose, String code) async {
    final String clean = code.replaceAll(RegExp(r'\s'), '');
    final DateTime now = _now;
    final bool ok = await _db.tx((DbSession tx) async {
      final Row? c = await tx.one(
        '''select id, code_hash, attempts, expires_at from email_codes
            where account_id = @a::uuid and purpose = @p and used_at is null
            order by created_at desc limit 1 for update''',
        <String, Object?>{'a': accountId, 'p': purpose},
      );
      if (c == null) return false;
      if ((c['expires_at'] as DateTime).isBefore(now) ||
          (c['attempts'] as int) >= maxCodeAttempts) {
        return false;
      }
      final bool match = constantTimeEquals(
        Tokens.codeHash(accountId, purpose, clean),
        c['code_hash'] as List<int>,
      );
      if (!match) {
        await tx.execute(
          'update email_codes set attempts = attempts + 1 where id = @id',
          <String, Object?>{'id': c['id']},
        );
        return false;
      }
      await tx.execute(
        'update email_codes set used_at = @now where id = @id',
        <String, Object?>{'now': now, 'id': c['id']},
      );
      return true;
    });
    if (!ok) throw _badCode;
  }

  /// Sends an email. With [mailInBackground] the caller doesn't wait, so
  /// response time and errors look the same for every address; a failure
  /// is logged and audited (Console → Audit, `mail.failed`) so admins can
  /// see that mail is broken.
  Future<void> _mail(String to, String subject, String text) async {
    Future<void> send() => _mailer.send(OutgoingMail(to: to, subject: subject, text: text));
    if (!mailInBackground) {
      try {
        await send();
      } catch (e) {
        _log.severe('Mail to $to failed', e);
        throw const ApiException(
          503,
          'mail_failed',
          'We could not send the email right now. Try again in a few minutes',
        );
      }
      return;
    }
    unawaited(send().catchError((Object e) async {
      _log.severe('Mail to $to failed', e);
      try {
        await _audit.record(_db, const AuditActor.system('mail'), 'mail.failed',
            detail: <String, Object?>{'to': to, 'error': '$e'.split('\n').first});
      } catch (_) {}
    }));
  }

  static const ApiException _badCode = ApiException(
    400,
    'invalid_code',
    'That code is wrong or has expired. Use the newest email from EchoPin, '
        'or ask for a new code',
  );

  static const ApiException _badCredentials = ApiException(
    401,
    'invalid_credentials',
    'That email and password do not match',
  );
  static const ApiException _disabled = ApiException(
    403,
    'account_disabled',
    'This account has been switched off. Contact your EchoPin administrator',
  );
  static const ApiException _invalidRefresh = ApiException(
    401,
    'invalid_refresh',
    'Sign in again to continue',
  );

  static ApiException _locked(Duration wait) => ApiException(
    423,
    'locked',
    'Too many wrong attempts. Try again in ${(wait.inMinutes + 1)} minutes, '
        'or reset your password',
    extra: <String, Object?>{'retryAfterSeconds': wait.inSeconds + 1},
  );
}

/// Deliberately stricter than RFC 5322. Commas, semicolons, angle
/// brackets, quotes and control characters are refused. They are legal
/// in exotic addresses, but they are exactly what turns "send a code to
/// this address" into "send it to that address too" in mail headers.
final RegExp _emailShape = RegExp(
  r'^[A-Za-z0-9.!#$%&*+/=?^_`{|}~\-]{1,64}@[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?'
  r'(?:\.[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?)*\.[A-Za-z]{2,}$',
);

/// Lower-cases and validates an email. The normalised form is the account
/// key, so `Ana@Example.com` and `ana@example.com` are one account.
String normalizeEmail(String raw) {
  final String e = raw.trim().toLowerCase();
  if (e.length > 254 || !_emailShape.hasMatch(e)) {
    throw const ApiException(400, 'invalid_email', 'Enter a valid email address');
  }
  return e;
}

String cleanDisplayName(String raw) {
  final String clean = raw
      .replaceAll(RegExp(r'[\u0000-\u001F\u007F\u202A-\u202E\u2066-\u2069\u200E\u200F]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (clean.isEmpty) {
    throw const ApiException(400, 'invalid_name', 'Enter your name');
  }
  if (clean.length > ProtocolLimits.maxDisplayName) {
    throw const ApiException(
      400,
      'invalid_name',
      'Names can be at most ${ProtocolLimits.maxDisplayName} characters',
    );
  }
  return clean;
}
