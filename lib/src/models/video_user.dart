class VideoUser {
  const VideoUser({required this.id, required this.name, this.image});

  final String id;
  final String name;
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
