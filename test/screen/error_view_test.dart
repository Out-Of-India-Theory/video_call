import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oit_video_call/src/errors.dart';
import 'package:oit_video_call/src/screen/error_view.dart';

void main() {
  Widget host(Widget child) =>
      MaterialApp(home: Scaffold(body: child));

  testWidgets('renders message and Close button by default', (tester) async {
    await tester.pumpWidget(host(const ErrorView(
      code: OitVideoCallErrorCode.callNotFound,
      message: 'No such call',
    )));

    expect(find.text('No such call'), findsOneWidget);
    expect(find.text('Close'), findsOneWidget);
  });

  testWidgets('shows Retry action when provided', (tester) async {
    var retryCount = 0;
    await tester.pumpWidget(host(ErrorView(
      code: OitVideoCallErrorCode.permissionDenied,
      message: 'Mic + camera required',
      onRetry: () => retryCount++,
    )));

    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(retryCount, 1);
  });

  testWidgets('shows Open Settings action when provided', (tester) async {
    var settingsCount = 0;
    await tester.pumpWidget(host(ErrorView(
      code: OitVideoCallErrorCode.permissionDenied,
      message: 'Permission permanently denied',
      onOpenSettings: () => settingsCount++,
    )));

    expect(find.text('Open Settings'), findsOneWidget);
    await tester.tap(find.text('Open Settings'));
    await tester.pump();
    expect(settingsCount, 1);
  });
}
