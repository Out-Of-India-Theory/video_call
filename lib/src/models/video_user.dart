/// Identifies the signed-in user for video calls.
///
/// Pass this to [OitVideoCall.init] so call participants can be rendered
/// with their name and avatar.
class VideoUser {
  const VideoUser({required this.id, required this.name, this.image});

  /// Stable per-user identifier; must match the Stream user id used by
  /// the backend when minting tokens.
  final String id;

  /// Display name shown to other participants.
  final String name;

  /// Optional avatar URL shown when the camera is off (audio-only mode
  /// or video disabled). Should be a CDN URL reachable by the call peer.
  final String? image;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VideoUser &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          name == other.name &&
          image == other.image;

  @override
  int get hashCode => Object.hash(id, name, image);
}
