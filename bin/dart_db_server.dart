import 'package:dart_db_server/dart_db_server.dart';

Future<void> main(List<String> arguments) async {
  final db = await DatabaseServer.initialize();
}
