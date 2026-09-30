import 'package:flutter_test/flutter_test.dart';
import 'package:adagio/main.dart';

void main() {
  testWidgets('Carga inicial de AdagioApp', (WidgetTester tester) async {
    // Construye la aplicación Adagio y renderiza el primer frame.
    await tester.pumpWidget(const AdagioApp());

    // Verifica que el nombre de la app se muestre en pantalla.
    expect(find.text('Adagio'), findsWidgets);
  });
}
