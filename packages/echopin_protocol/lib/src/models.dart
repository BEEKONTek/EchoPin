/// Enumerations whose wire values the app and the server must agree on.
library;

T? _fromWire<T extends Enum>(List<T> values, String Function(T) wire, Object? v) {
  for (final T e in values) {
    if (wire(e) == v) return e;
  }
  return null;
}

/// What an account may do. Ordered from least to most privileged.
enum AccountRole {
  /// Uses EchoPin; can file reports and see their own.
  member('member'),

  /// Emergency staff: sees the session index and reports, and can open a
  /// sealed session log by stating a reason (break-glass).
  responder('responder'),

  /// Everything a responder can do, plus accounts, diagnostics, audit and
  /// backups.
  admin('admin');

  const AccountRole(this.wire);
  final String wire;

  bool atLeast(AccountRole other) => index >= other.index;

  static AccountRole? fromWire(Object? v) =>
      _fromWire(values, (AccountRole e) => e.wire, v);
}

enum AccountStatus {
  /// Registered, email not yet verified. Cannot sign in.
  pending('pending'),
  active('active'),

  /// Switched off by an admin. All sign-ins and tokens are refused.
  disabled('disabled');

  const AccountStatus(this.wire);
  final String wire;

  static AccountStatus? fromWire(Object? v) =>
      _fromWire(values, (AccountStatus e) => e.wire, v);
}

enum ReportCategory {
  bug('bug', 'Something is broken'),
  safety('safety', 'Safety incident'),
  abuse('abuse', 'Someone is misusing EchoPin'),
  account('account', 'Account or sign-in'),
  other('other', 'Something else');

  const ReportCategory(this.wire, this.label);
  final String wire;
  final String label;

  static ReportCategory? fromWire(Object? v) =>
      _fromWire(values, (ReportCategory e) => e.wire, v);
}

enum ReportSeverity {
  low('low'),
  normal('normal'),
  high('high'),

  /// Someone may be in danger now. Sorted to the top of every admin list.
  critical('critical');

  const ReportSeverity(this.wire);
  final String wire;

  static ReportSeverity? fromWire(Object? v) =>
      _fromWire(values, (ReportSeverity e) => e.wire, v);
}

enum ReportStatus {
  open('open'),
  investigating('investigating'),
  resolved('resolved'),
  dismissed('dismissed');

  const ReportStatus(this.wire);
  final String wire;

  bool get isClosed => this == resolved || this == dismissed;

  static ReportStatus? fromWire(Object? v) =>
      _fromWire(values, (ReportStatus e) => e.wire, v);
}

enum DiagnosticLevel {
  info('info'),
  warning('warning'),
  error('error');

  const DiagnosticLevel(this.wire);
  final String wire;

  static DiagnosticLevel? fromWire(Object? v) =>
      _fromWire(values, (DiagnosticLevel e) => e.wire, v);
}

/// Event types inside a sealed session log. The log itself is opaque to
/// the server until opened; these names are what a responder reads.
abstract final class SessionLogEvent {
  static const String started = 'started';
  static const String memberJoined = 'member_joined';
  static const String memberLeft = 'member_left';
  static const String pingSent = 'ping_sent';
  static const String pingStatus = 'ping_status';
  static const String pingReceived = 'ping_received';
  static const String pingAnswered = 'ping_answered';
  static const String sosRaised = 'sos_raised';
  static const String sosResolved = 'sos_resolved';
  static const String leftBoundary = 'left_boundary';
  static const String returnedToBoundary = 'returned_to_boundary';
  static const String security = 'security';
  static const String ended = 'ended';
}

/// Limits both sides enforce.
abstract final class ProtocolLimits {
  static const int maxReportSubject = 120;
  static const int maxReportBody = 4000;
  static const int maxSealedLogBytes = 512 * 1024;
  static const int maxDiagnosticsBytes = 32 * 1024;
  static const int maxLogEvents = 2000;
  static const int minPasswordLength = 10;
  static const int maxPasswordLength = 256;
  static const int maxDisplayName = 40;
}
