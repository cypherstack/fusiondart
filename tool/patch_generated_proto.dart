import 'dart:io';

const _compatImport =
    "import 'package:fusiondart/src/protobuf/protobuf_compat.dart' as \$compat;";
const _protobufImport = "import 'package:protobuf/protobuf.dart' as \$pb;";

void main(List<String> arguments) {
  final path =
      arguments.isEmpty ? 'lib/src/protobuf/fusion.pb.dart' : arguments.single;
  final file = File(path);
  var source = file.readAsStringSync();

  if (!source.contains(_compatImport)) {
    if (!source.contains(_protobufImport)) {
      throw StateError('$path has no protobuf import');
    }
    source = source.replaceFirst(
      _protobufImport,
      '$_protobufImport\n\n$_compatImport',
    );
  }

  final constructor = RegExp(r'\$pb\.PbList<([A-Za-z0-9_]+)>\(\)');
  final replacements = constructor.allMatches(source).length;
  source = source.replaceAllMapped(constructor, (match) {
    final type = match.group(1)!;
    return '\$compat.newRepeated<$type>($type.create)';
  });

  if (replacements == 0 && !source.contains(r'$compat.newRepeated<')) {
    throw StateError('$path has no createRepeated implementation to patch');
  }

  file.writeAsStringSync(source);
  stdout.writeln('Patched $replacements createRepeated implementation(s).');
}
