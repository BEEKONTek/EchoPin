import 'package:flutter/material.dart';

class SessionProvider extends ChangeNotifier {
  SessionProvider();

  String _sessionName = 'New session';

  String get sessionName => _sessionName;

  void updateSessionName(String value) {
    _sessionName = value;
    notifyListeners();
  }
}
