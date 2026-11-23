import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'package:print_app/main.dart';
import 'package:print_app/services/pdf_splitter_service.dart';

void main() {
  testWidgets('PrintApp renders home screen', (WidgetTester tester) async {
    await tester.pumpWidget(const PrintApp());
    expect(find.text('PrintBridge'), findsOneWidget);
    expect(find.text('Chọn PDF / Word / Excel / Ảnh'), findsOneWidget);
  });

  test('PdfSplitterService splits 5-page PDF into odd, reversed even, and bonus', () {
    final doc = PdfDocument();
    for (int i = 0; i < 5; i++) {
      doc.pages.add();
    }
    final inputBytes = Uint8List.fromList(doc.saveSync());
    doc.dispose();

    final result = PdfSplitterService.analyzeAndSplit(inputBytes, 'test_invoice.pdf');
    expect(result.pageCount, 5);
    expect(result.isOddPageCount, true);
    expect(result.oddBytes, isNotNull);
    expect(result.evenBytes, isNotNull);
    expect(result.bonusLastOddBytes, isNotNull);

    final oddDoc = PdfDocument(inputBytes: result.oddBytes);
    final evenDoc = PdfDocument(inputBytes: result.evenBytes);
    final bonusDoc = PdfDocument(inputBytes: result.bonusLastOddBytes);
    expect(oddDoc.pages.count, 2); // pages 1, 3
    expect(evenDoc.pages.count, 2); // pages 4, 2
    expect(bonusDoc.pages.count, 1); // page 5
    oddDoc.dispose();
    evenDoc.dispose();
    bonusDoc.dispose();
  });
}
