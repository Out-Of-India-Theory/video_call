/// Names of the push providers configured in the Stream dashboard.
///
/// These MUST exactly match the provider names created in the Stream
/// dashboard (see Phase 0 plan TG9). The iOS provider is an APN provider in
/// VoIP mode (PushKit); the Android provider is a Firebase (FCM) provider.
class StreamRingProviderNames {
  const StreamRingProviderNames({
    required this.apnVoip,
    required this.firebase,
  });

  /// iOS VoIP (PushKit) provider name, e.g. `dharmayana-apn-voip`.
  final String apnVoip;

  /// Android FCM provider name, e.g. `dharmayana-firebase`.
  final String firebase;
}
