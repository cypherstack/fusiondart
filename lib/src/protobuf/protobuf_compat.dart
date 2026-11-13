import 'package:protobuf/protobuf.dart';

/// Creates the `PbList` returned by legacy generated `createRepeated` APIs.
///
/// Protobuf 6 made the `PbList` constructor private, while protobuf 4 does not
/// expose the replacement factory. A repeated-field default is the public
/// operation common to both runtime generations.
PbList<T> newRepeated<T extends GeneratedMessage>(T Function() create) {
  final info = BuilderInfo('_RepeatedCompat')
    ..pc<T>(1, 'items', PbFieldType.PM, subBuilder: create);
  return info.makeDefault(1)!() as PbList<T>;
}
