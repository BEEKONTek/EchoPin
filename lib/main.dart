import 'dart:async';

import 'package:echo_pin/providers/admin_provider.dart';
import 'package:echo_pin/providers/admin_scope.dart';
import 'package:echo_pin/providers/alert_provider.dart';
import 'package:echo_pin/providers/alert_scope.dart';
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
    this.transportFactory,
    this.connectivity,
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

  @override
  State<EchoPinApp> createState() => _EchoPinAppState();
}

class _EchoPinAppState extends State<EchoPinApp> {
  late final SettingsProvider _settings;
  late final AlertProvider _alertProvider;
  late final SessionProvider _sessionProvider;
  late final AdminProvider _adminProvider;
  late final ConnectivityService _connectivity;

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
  }

  @override
  void dispose() {
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
    );
  }
}
