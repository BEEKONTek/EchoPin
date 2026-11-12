// CUSTODIAN KEYS: an optional second seal on session records, whose
// private half never touches the server.
//
// Without it, the server's escrow key opens every record, so anyone who
// controls the server (or reads ECHOPIN_KEYS from the hosting dashboard)
// can read them, audit or not. With custodian keys configured, phones
// seal each record twice:
//
//   inner = seal(custodian public key, record)  ← only responders can open
//   outer = seal(escrow public key, inner)      ← only the server can open
//
// Opening a record then needs both halves: the server peels the outer
// layer during the audited break-glass request, and the responder's
// console peels the inner one with the custodian private key held on that
// device. A stolen database plus server keys yields nothing readable, and
// a responder's device alone can't fetch anything without going through
// the audited API.

import 'dart:convert';

import 'package:echopin_protocol/echopin_protocol.dart';

class CustodianKeys {
  CustodianKeys(List<String> base64Keys)
    : publicKeys = <String, List<int>>{
        for (final String k in base64Keys)
          SealedBox.keyIdFor(base64.decode(k)): base64.decode(k),
      },
      currentId = base64Keys.isEmpty
          ? null
          : SealedBox.keyIdFor(base64.decode(base64Keys.first));

  /// Accepted custodian keys by id (old ones stay so queued uploads work).
  final Map<String, List<int>> publicKeys;

  /// The key new records are sealed to, or null when not configured.
  final String? currentId;

  bool get configured => currentId != null;
}
