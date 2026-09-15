import 'context.dart';
import 'result.dart';

abstract class Interpreter {
  String get name;
  Future<InterpretResult> interpret(String text, InterpretContext ctx);
}
