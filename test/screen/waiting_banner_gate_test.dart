import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oit_video_call/src/screen/waiting_banner_gate.dart';
import 'package:stream_video_flutter/stream_video_flutter.dart';

import 'fake_call_session.dart' show fakeParticipant;

/// Minimal [Call] for gate tests: exposes a mutable [state] and nothing else.
/// Most members route through `noSuchMethod` (via [Mock]) so any inadvertent
/// SDK call surfaces loudly as a test failure.
class _BannerFakeCall extends Mock implements Call {
  _BannerFakeCall()
      : _emitter = _BannerStateEmitter<CallState>(
          CallState(
            currentUserId: 'me',
            callCid: StreamCallCid(cid: 'default:c1'),
            preferences: DefaultCallPreferences(),
          ),
        );

  final _BannerStateEmitter<CallState> _emitter;

  @override
  StateEmitter<CallState> get state => _emitter;

  void pushParticipants(List<CallParticipantState> participants) {
    _emitter.value =
        _emitter.value.copyWith(callParticipants: participants);
  }
}

/// Sync broadcast state emitter — same shape as the one in
/// `fake_call_session.dart`, scoped to this test file.
class _BannerStateEmitter<T> extends MutableStateEmitter<T> {
  _BannerStateEmitter(this._value);

  T _value;
  final StreamController<T> _ctrl = StreamController<T>.broadcast(sync: true);

  @override
  T get value => _value;

  @override
  set value(T newValue) {
    _value = newValue;
    _ctrl.add(newValue);
  }

  @override
  bool get hasValue => true;

  @override
  T? get valueOrNull => _value;

  @override
  Stream<T> get valueStream => _ctrl.stream;

  @override
  Sink<T> get valueSink => _ctrl.sink;

  @override
  Future<dynamic> close() => _ctrl.close();

  @override
  StreamSubscription<T> listen(
    void Function(T value)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      _ctrl.stream.listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );

  @override
  Stream<T> asStream() => _ctrl.stream;

  @override
  Future<E> waitFor<E extends T>({required Duration timeLimit}) =>
      firstWhere((it) => it is E, timeLimit: timeLimit).then((it) => it as E);

  @override
  Future<T> firstWhere(
    bool Function(T element) test, {
    T Function()? orElse,
    required Duration timeLimit,
  }) =>
      _ctrl.stream.firstWhere(test, orElse: orElse).timeout(timeLimit);
}

void main() {
  testWidgets('shows child when local is alone', (tester) async {
    final call = _BannerFakeCall();
    await tester.pumpWidget(MaterialApp(
      home: WaitingBannerGate(call: call, child: const Text('WAITING')),
    ));
    call.pushParticipants([fakeParticipant(isLocal: true, userId: 'me')]);
    await tester.pump();
    expect(find.text('WAITING'), findsOneWidget);
  });

  testWidgets('hides child when remote joins', (tester) async {
    final call = _BannerFakeCall();
    await tester.pumpWidget(MaterialApp(
      home: WaitingBannerGate(call: call, child: const Text('WAITING')),
    ));
    call.pushParticipants([fakeParticipant(isLocal: true, userId: 'me')]);
    await tester.pump();
    expect(find.text('WAITING'), findsOneWidget);

    call.pushParticipants([
      fakeParticipant(isLocal: true, userId: 'me'),
      fakeParticipant(isLocal: false, userId: 'them'),
    ]);
    await tester.pump();
    expect(find.text('WAITING'), findsNothing);
  });

  testWidgets('latch: stays hidden after remote drops', (tester) async {
    final call = _BannerFakeCall();
    await tester.pumpWidget(MaterialApp(
      home: WaitingBannerGate(call: call, child: const Text('WAITING')),
    ));
    call.pushParticipants([
      fakeParticipant(isLocal: true, userId: 'me'),
      fakeParticipant(isLocal: false, userId: 'them'),
    ]);
    await tester.pump();
    call.pushParticipants([fakeParticipant(isLocal: true, userId: 'me')]);
    await tester.pump();
    expect(find.text('WAITING'), findsNothing);
  });

  testWidgets('pre-latches if remote already present at mount',
      (tester) async {
    final call = _BannerFakeCall();
    // Push remote BEFORE the gate is mounted — simulates tap-to-expand from
    // mini overlay into an already-joined call.
    call.pushParticipants([
      fakeParticipant(isLocal: true, userId: 'me'),
      fakeParticipant(isLocal: false, userId: 'them'),
    ]);
    await tester.pumpWidget(MaterialApp(
      home: WaitingBannerGate(call: call, child: const Text('WAITING')),
    ));
    await tester.pump();
    expect(find.text('WAITING'), findsNothing);
  });
}
