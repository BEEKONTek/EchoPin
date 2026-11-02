import 'package:echo_pin/providers/alert_provider.dart';
import 'package:echo_pin/providers/alert_scope.dart';
import 'package:echo_pin/providers/session_provider.dart';
import 'package:echo_pin/providers/session_scope.dart';
import 'package:echo_pin/screens/home_screen.dart';
import 'package:echo_pin/services/haptic_service.dart';
import 'package:echo_pin/services/noop_notification_backend.dart';
import 'package:echo_pin/services/notification_service.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(const EchoPinApp());
}

class EchoPinApp extends StatefulWidget {
  const EchoPinApp({super.key});

  @override
  State<EchoPinApp> createState() => _EchoPinAppState();
}

class _EchoPinAppState extends State<EchoPinApp> {
  late final AlertProvider _alertProvider;
  late final SessionProvider _sessionProvider;

  @override
  void initState() {
    super.initState();
    final NotificationService notifications = NotificationService(
      alertsEnabled: () => true,
      backend: const NoopNotificationBackend(),
    );
    final HapticService haptics = HapticService(isEnabled: () => true);
    _alertProvider = AlertProvider(
      notifications: notifications,
      haptics: haptics,
    );
    _sessionProvider = SessionProvider(alertProvider: _alertProvider);
  }

  @override
  void dispose() {
    _sessionProvider.dispose();
    _alertProvider.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertScope(
      notifier: _alertProvider,
      child: SessionScope(
        notifier: _sessionProvider,
        child: MaterialApp(
          title: 'EchoPin',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF2563EB),
            ),
            useMaterial3: true,
          ),
          home: const HomeScreen(),
        ),
      ),
    );
  }
}
