import 'package:flutter/material.dart';
import 'package:stream_video_flutter/stream_video_flutter.dart';
import '../config.dart';
import '../errors.dart';
import 'call_session.dart';
import 'error_view.dart';
import 'permission_gate.dart';

@visibleForTesting
class CallScreenDeps {
  const CallScreenDeps({this.session, this.permissionGate, this.openSettings});

  final CallSession? session;
  final PermissionGate? permissionGate;
  final Future<bool> Function()? openSettings;
}

class CallScreen extends StatefulWidget {
  const CallScreen({
    super.key,
    required this.config,
    required this.callId,
    required this.callType,
    required this.audioOnly,
    this.onCallEnded,
    @visibleForTesting this.deps,
  });

  final OitVideoCallConfig config;
  final String callId;
  final String callType;
  final bool audioOnly;
  final VoidCallback? onCallEnded;

  @visibleForTesting
  final CallScreenDeps? deps;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

sealed class _Phase {}

class _Loading extends _Phase {}

class _Errored extends _Phase {
  _Errored(
    this.code,
    this.message, {
    // ignore: unused_element_parameter — used in Task 16's _start().
    this.canRetry = true,
    // ignore: unused_element_parameter — used in Task 16's _start().
    this.canOpenSettings = false,
  });

  final OitVideoCallErrorCode code;
  final String message;
  final bool canRetry;
  final bool canOpenSettings;
}

class _Ready extends _Phase {
  _Ready(this.call);

  final Call call;
}

class _CallScreenState extends State<CallScreen> {
  late final CallSession _session;
  // ignore: unused_field — read by Task 16's _start() lifecycle.
  late final PermissionGate _gate;
  late final Future<bool> Function() _openSettings;
  Call? _call;
  _Phase _phase = _Loading();

  @override
  void initState() {
    super.initState();
    _session = widget.deps?.session ?? StreamCallSession();
    _gate = widget.deps?.permissionGate ?? RealPermissionGate();
    _openSettings = widget.deps?.openSettings ?? () => Future.value(false);
    _start();
  }

  Future<void> _start() async {
    // Implemented in Task 16.
  }

  @override
  void dispose() {
    if (_call != null) {
      _session.leaveCall(_call!);
    }
    _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: switch (_phase) {
        _Loading() => const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 12),
              Text('Joining call…'),
            ],
          ),
        ),
        _Errored(
          code: final c,
          message: final m,
          canRetry: final r,
          canOpenSettings: final s,
        ) =>
          ErrorView(
            code: c,
            message: m,
            onRetry: r ? _retry : null,
            onOpenSettings: s ? () => _openSettings() : null,
          ),
        _Ready(call: final call) => StreamCallContainer(call: call),
      },
    );
  }

  void _retry() {
    setState(() => _phase = _Loading());
    _start();
  }
}
