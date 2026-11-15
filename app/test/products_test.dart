import 'package:flutter_test/flutter_test.dart';
import 'package:forromanager/ui/screens/products_screen.dart';

void main() {
  test('genera le varianti combinando taglie e colori', () {
    expect(combineVariants('S, M', 'nero, bianco'), [('S', 'nero'), ('S', 'bianco'), ('M', 'nero'), ('M', 'bianco')]);
    expect(combineVariants('S,M,M', ''), [('S', ''), ('M', '')]);
    expect(combineVariants('', ' oro '), [('', 'oro')]);
    expect(combineVariants('', ''), isEmpty);
  });
}
