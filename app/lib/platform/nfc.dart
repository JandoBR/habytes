import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nfc_manager/ndef_record.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'package:nfc_manager/nfc_manager_android.dart';

import '../api/models.dart';
import 'native.dart';

/// The Android application ID, for the tag's Android Application Record.
const _package = 'uk.pixxula.habytes';

/// What a habit's tag holds: its URI, and a record that makes Android hand
/// the tag to this app. No secret, so a copied tag is of no use to anyone else.
NdefMessage habitTagMessage(String habitId) => NdefMessage(
  records: [
    NdefRecord(
      typeNameFormat: TypeNameFormat.wellKnown,
      type: Uint8List.fromList(ascii.encode('U')),
      identifier: Uint8List(0),
      // 0x00: the URI is written out in full, with no abbreviated prefix.
      payload: Uint8List.fromList([0, ...utf8.encode('habitd://habit/$habitId')]),
    ),
    NdefRecord(
      typeNameFormat: TypeNameFormat.external,
      type: Uint8List.fromList(ascii.encode('android.com:pkg')),
      identifier: Uint8List(0),
      payload: Uint8List.fromList(ascii.encode(_package)),
    ),
  ],
);

Future<void> _write(NfcTag tag, NdefMessage message) async {
  final ndef = NdefAndroid.from(tag);
  if (ndef == null) {
    final blank = NdefFormatableAndroid.from(tag);
    if (blank == null) throw Exception('This tag cannot hold NDEF data.');
    await blank.format(message);
    return;
  }
  if (!ndef.isWritable) throw Exception('This tag is read-only.');
  if (ndef.maxSize < message.byteLength) {
    throw Exception('This tag is too small (${ndef.maxSize} bytes, ${message.byteLength} needed).');
  }
  await ndef.writeNdefMessage(message);
}

/// Asks for a tag and writes [habit] to it. Returns whether a tag was written.
Future<bool> writeHabitTag(BuildContext context, Habit habit) async {
  final availability = await NfcManager.instance.checkAvailability();
  if (!context.mounted) return false;
  if (availability != NfcAvailability.enabled) {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('NFC is not available'),
        content: Text(
          availability == NfcAvailability.disabled
              ? 'Turn on NFC in the system settings and try again.'
              : 'This device has no NFC.',
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
      ),
    );
    return false;
  }
  final written = await showDialog<bool>(
    context: context,
    builder: (context) => _WriteDialog(habit: habit),
  );
  return written ?? false;
}

class _WriteDialog extends StatefulWidget {
  const _WriteDialog({required this.habit});

  final Habit habit;

  @override
  State<_WriteDialog> createState() => _WriteDialogState();
}

class _WriteDialogState extends State<_WriteDialog> {
  String? _error;
  bool _writing = false;

  @override
  void initState() {
    super.initState();
    // While the session runs the tag comes here instead of being logged as a scan.
    NfcManager.instance.startSession(
      pollingOptions: {NfcPollingOption.iso14443, NfcPollingOption.iso15693},
      onDiscovered: _onTag,
    );
  }

  @override
  void dispose() {
    unawaited(NfcManager.instance.stopSession());
    super.dispose();
  }

  Future<void> _onTag(NfcTag tag) async {
    if (_writing) return;
    setState(() {
      _writing = true;
      _error = null;
    });
    try {
      // The tag is still against the phone when the session ends, and Android
      // would read it straight back and log the habit.
      await Native.muteScans(widget.habit.id);
      await _write(tag, habitTagMessage(widget.habit.id));
      await Native.muteScans(widget.habit.id);
      if (mounted) Navigator.pop(context, true);
    } on Exception catch (error) {
      if (mounted) {
        setState(() {
          _writing = false;
          // The plugin's own errors are not written for people.
          _error = error is PlatformException
              ? 'Could not write the tag. Hold it still and try again.'
              : '$error'.replaceFirst('Exception: ', '');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Write NFC tag'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.nfc, size: 48),
        const SizedBox(height: 16),
        Text(
          _writing
              ? 'Writing…'
              : 'Hold a tag against the back of the phone. Scanning it afterwards '
                    'logs "${widget.habit.name}".',
          textAlign: TextAlign.center,
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
      ],
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
    ],
  );
}
