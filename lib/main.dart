// APP ENTRY POINT and composition root.
//
// main() probes the platform (Bootstrap: secure storage, notifications,
// Bluetooth), loads settings, and starts the widget tree. EchoPinApp
// creates every long-lived object once (settings, alerts, sessions, admin,
// and, when a server URL is built in, accounts, the outbox and the session
// recorder) and hands them down the tree with *Scope widgets, so any screen
// can reach them without globals. Tests pass fakes through the same
// constructor parameters.

import 'dart:async';

import 'package:echo_pin/account/account_provider.dart';
import 'package:echo_pin/account/outbox.dart';
import 'package:echo_pin/account/session_recorder.dart';
import 'package:echo_pin/app_info.dart';
import 'package:echo_pin/providers/account_lock_provider.dart';
import 'package:echo_pin/providers/account_lock_scope.dart';
import 'package:echo_pin/providers/account_scope.dart';
import 'package:echo_pin/providers/admin_provider.dart';
import 'package:echo_pin/providers/admin_scope.dart';
import 'package:echo_pin/providers/alert_provider.dart';
import 'package:echo_pin/providers/alert_scope.dart';
import 'package:echo_pin/providers/outbox_scope.dart';
import 'package:echo_pin/providers/session_provider.dart';
import 'package:echo_pin/providers/session_scope.dart';
import 'package:echo_pin/providers/settings_provider.dart';
import 'package:echo_pin/providers/settings_scope.dart';
import 'package:echo_pin/screens/home_screen.dart';
import 'package:echo_pin/services/admin_auth_service.dart';
import 'package:echo_pin/services/ble_permission_service.dart';
import 'package:echo_pin/services/bootstrap.dart';
import 'package:echo_pin/services/connectivity_service.dart';
import 'package:echo_pin/services/haptic_service.dart';
import 'package:echo_pin/services/method_channel_ble_bridge.dart';
import 'package:echo_pin/services/notification_service.dart';
import 'package:echo_pin/services/platform_ble_bridge.dart';
import 'package:echo_pin/services/session_history_service.dart';
import 'package:echo_pin/transport/message_transport.dart';
import 'package:echo_pin/ui/theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final Bootstrap bootstrap = await Bootstrap.initialize();
  final SettingsProvider settings = SettingsProvider();
  await settings.load();
  runApp(EchoPinApp(bootstrap: bootstrap, settings: settings));
  // Any OS permission dialog appears over a running app, never a splash.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(bootstrap.notifications.requestPermissions());
  });
}

class EchoPinApp extends StatefulWidget {
  const EchoPinApp({
    super.key,
    required this.bootstrap,
    this.settings,
    this.bleBridge,
    this.permissionService,
    this.adminAuth,
    this.accountLockAuth,
    this.transportFactory,
    this.connectivity,
    this.account,
  });

  final Bootstrap bootstrap;

  /// Pre-loaded settings. A default, unloaded provider is used when null.
  final SettingsProvider? settings;

  /// Overrides the native bridge (tests). When null, the method-channel
  /// bridge is used if `Bootstrap` found one.
  final PlatformBleBridge? bleBridge;
  final BlePermissionService? permissionService;

  /// Overrides radios (tests); see [SessionProvider.transportFactory].
  final List<MessageTransport> Function()? transportFactory;

  /// Overrides network detection (tests).
  final ConnectivityService? connectivity;

  /// Overrides admin authentication (tests).
  final AdminAuthService? adminAuth;

  /// Overrides the account PIN service (tests).
  final AdminAuthService? accountLockAuth;

  /// Overrides the account provider (tests). By default accounts are on
  /// only when the build sets `ECHOPIN_SERVER_URL`.
  final AccountProvider? account;

  @override
  State<EchoPinApp> createState() => _EchoPinAppState();
}

class _EchoPinAppState extends State<EchoPinApp> {
  late final SettingsProvider _settings;
  late final AlertProvider _alertProvider;
  late final SessionProvider _sessionProvider;
  late final AdminProvider _adminProvider;
  late final ConnectivityService _connectivity;
  late final AccountProvider _account;
  late final AccountLockProvider _accountLock;
  late final AppLifecycleListener _lifecycle;
  late final Outbox _outbox;
  late final SessionRecorder _recorder;

  @override
  void initState() {
    super.initState();
    final Bootstrap bootstrap = widget.bootstrap;
    _settings = widget.settings ?? SettingsProvider();

    final NotificationService notifications = NotificationService(
      alertsEnabled: () => _settings.value.alertsEnabled,
      osNotificationsEnabled: () => _settings.value.osNotificationsEnabled,
      backend: bootstrap.notifications,
    );
    final HapticService haptics = HapticService(
      isEnabled: () => _settings.value.hapticsEnabled,
    );
    _alertProvider = AlertProvider(
      notifications: notifications,
      haptics: haptics,
    );
    // Network detection only matters for the Wi-Fi transport, which the
    // web does not have (and connectivity_plus has no web channel here).
    _connectivity =
        widget.connectivity ?? ConnectivityService(enabled: !kIsWeb);
    _sessionProvider = SessionProvider(
      alertProvider: _alertProvider,
      sessionCodec: bootstrap.codec,
      // The history holds invite codes (session secrets): keep it in the
      // store Bootstrap chose, i.e. the OS keystore where available.
      historyService: SessionHistoryService(kv: bootstrap.kv),
      bleBridge:
          widget.bleBridge ??
          (bootstrap.usingRealBle ? MethodChannelBleBridge() : null),
      permissionService: widget.permissionService,
      settings: () => _settings.value,
      connectivity: _connectivity,
      transportFactory: widget.transportFactory,
    );
    _adminProvider = AdminProvider(
      auth: widget.adminAuth ?? AdminAuthService(kv: bootstrap.kv),
      settings: _settings,
      sessions: _sessionProvider,
      platform: PlatformDiagnostics(
        platform: Bootstrap.platformLabel,
        usingSecureStorage: bootstrap.usingSecureStorage,
        usingRealBle: bootstrap.usingRealBle,
        notificationBackend: bootstrap.notifications.name,
      ),
    );
    unawaited(_adminProvider.refresh());

    // Accounts, the upload queue and the sealed session recorder all keep
    // their secrets in the store Bootstrap chose (the OS keystore where
    // available).
    _account =
        widget.account ??
        AccountProvider(
          kv: bootstrap.kv,
          platform: Bootstrap.platformLabel,
          appVersion: kAppVersion,
          secureKeyStorage: bootstrap.usingSecureStorage,
        );
    // A PIN in front of the signed-in account on this device, like the
    // admin panel's. Its hash sits in the same store as the admin PIN.
    _accountLock = AccountLockProvider(
      auth:
          widget.accountLockAuth ?? AdminAuthService.account(kv: bootstrap.kv),
      account: _account,
    );
    // Phones suspend timers in the background: re-check idle time on return.
    _lifecycle = AppLifecycleListener(onResume: _accountLock.checkIdle);
    _outbox = Outbox(kv: bootstrap.kv, account: _account);
    _recorder = SessionRecorder(
      sessions: _sessionProvider,
      account: _account,
      outbox: _outbox,
      kv: bootstrap.kv,
      platform: Bootstrap.platformLabel,
    );
    unawaited(_startAccounts());
  }

  Future<void> _startAccounts() async {
    await _account.load();
    if (!_account.enabled) return;
    await _outbox.load();
    _outbox.start();
    await _recorder.start();
    unawaited(_outbox.flush());
  }

  @override
  void dispose() {
    _recorder.dispose();
    _outbox.dispose();
    _lifecycle.dispose();
    _accountLock.dispose();
    if (widget.account == null) _account.dispose();
    _adminProvider.dispose();
    _sessionProvider.dispose();
    _alertProvider.dispose();
    if (widget.connectivity == null) _connectivity.dispose();
    if (widget.settings == null) _settings.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SettingsScope(
      notifier: _settings,
      child: AlertScope(
        notifier: _alertProvider,
        child: SessionScope(
          notifier: _sessionProvider,
          child: AdminScope(
            notifier: _adminProvider,
            child: AccountScope(
              notifier: _account,
              child: AccountLockScope(
                notifier: _accountLock,
                child: OutboxScope(
                  notifier: _outbox,
                  child: MaterialApp(
                    title: 'EchoPin',
                    debugShowCheckedModeBanner: false,
                    theme: EchoTheme.light(),
                    darkTheme: EchoTheme.dark(),
                    home: const HomeScreen(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
