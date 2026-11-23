import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:syncfusion_flutter_pdf/pdf.dart';

class SplitPdfResult {
  final String baseName;
  final Uint8List fullBytes;
  final Uint8List? oddBytes;
  final Uint8List? evenBytes;
  final Uint8List? bonusLastOddBytes;
  final int pageCount;
  final bool isOddPageCount;

  const SplitPdfResult({
    required this.baseName,
    required this.fullBytes,
    required this.oddBytes,
    required this.evenBytes,
    required this.bonusLastOddBytes,
    required this.pageCount,
    required this.isOddPageCount,
  });

  String get fullFileName => '${baseName}_full.pdf';
  String get oddFileName => '${baseName}_odd.pdf';
  String get evenFileName => '${baseName}_even.pdf';
  String get bonusFileName => '${baseName}_odd_last.pdf';
}

class PdfSplitterService {
  static String sanitizeBaseName(String fileName) {
    final withoutExt = fileName.replaceAll(RegExp(r'\.[^.]+$'), '');
    final cleaned = withoutExt.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return cleaned.isEmpty ? 'document' : cleaned;
  }

  static Uint8List _buildPdfFromIndices(PdfDocument source, List<int> indices) {
    final outDoc = PdfDocument();
    for (final index in indices) {
      final srcPage = source.pages[index];
      final template = srcPage.createTemplate();

      final section = outDoc.sections!.add();
      section.pageSettings.margins.all = 0;
      section.pageSettings.size = ui.Size(template.size.width, template.size.height);

      final destPage = section.pages.add();
      destPage.graphics.drawPdfTemplate(template, ui.Offset.zero);
    }

    final bytes = Uint8List.fromList(outDoc.saveSync());
    outDoc.dispose();
    return bytes;
  }

  /// Chuyển ảnh (JPG/PNG/WEBP/HEIC...) thành 1 trang PDF khổ A4 vừa khung, tự xoay ngang nếu ảnh ngang.
  static Future<Uint8List> imageToPdf(Uint8List imageBytes) async {
    final codec = await ui.instantiateImageCodec(imageBytes);
    final frame = await codec.getNextFrame();
    final uiImage = frame.image;
    final pngData = await uiImage.toByteData(format: ui.ImageByteFormat.png);
    final imgW = uiImage.width.toDouble();
    final imgH = uiImage.height.toDouble();
    uiImage.dispose();
    codec.dispose();

    if (pngData == null) {
      throw Exception('Không giải mã được dữ liệu ảnh');
    }

    final doc = PdfDocument();
    doc.pageSettings.size = PdfPageSize.a4;
    doc.pageSettings.margins.all = 18;
    if (imgW > imgH) {
      doc.pageSettings.orientation = PdfPageOrientation.landscape;
    }

    final page = doc.pages.add();
    final clientSize = page.getClientSize();
    final scale = math.min(clientSize.width / imgW, clientSize.height / imgH);
    final drawW = imgW * scale;
    final drawH = imgH * scale;
    final dx = (clientSize.width - drawW) / 2;
    final dy = (clientSize.height - drawH) / 2;

    final bitmap = PdfBitmap(pngData.buffer.asUint8List());
    page.graphics.drawImage(bitmap, ui.Rect.fromLTWH(dx, dy, drawW, drawH));

    final pdfBytes = Uint8List.fromList(doc.saveSync());
    doc.dispose();
    return pdfBytes;
  }

  /// Tách PDF thành:
  /// - Mặt trước (trang lẻ: 1, 3, 5...; nếu tổng trang lẻ thì chừa trang cuối)
  /// - Mặt sau (trang chẵn đảo ngược: n, n-2, ... 2)
  /// - Bonus trang lẻ cuối (nếu tổng số trang là lẻ)
  static SplitPdfResult analyzeAndSplit(Uint8List inputBytes, String fileName) {
    final baseName = sanitizeBaseName(fileName);
    final inputDoc = PdfDocument(inputBytes: inputBytes);

    try {
      final totalPages = inputDoc.pages.count;
      if (totalPages <= 1) {
        return SplitPdfResult(
          baseName: baseName,
          fullBytes: inputBytes,
          oddBytes: null,
          evenBytes: null,
          bonusLastOddBytes: null,
          pageCount: totalPages,
          isOddPageCount: totalPages % 2 != 0,
        );
      }

      final isOddPageCount = totalPages % 2 != 0;

      final oddIndices = <int>[];
      for (int i = 0; i < totalPages; i += 2) {
        if (isOddPageCount && i == totalPages - 1) {
          continue;
        }
        oddIndices.add(i);
      }

      final evenIndices = <int>[];
      int evenIdx = totalPages.isEven ? totalPages - 1 : totalPages - 2;
      while (evenIdx >= 1) {
        evenIndices.add(evenIdx);
        evenIdx -= 2;
      }

      final oddBytes = _buildPdfFromIndices(inputDoc, oddIndices);
      final evenBytes = _buildPdfFromIndices(inputDoc, evenIndices);
      final bonusBytes = isOddPageCount
          ? _buildPdfFromIndices(inputDoc, [totalPages - 1])
          : null;

      return SplitPdfResult(
        baseName: baseName,
        fullBytes: inputBytes,
        oddBytes: oddBytes,
        evenBytes: evenBytes,
        bonusLastOddBytes: bonusBytes,
        pageCount: totalPages,
        isOddPageCount: isOddPageCount,
      );
    } finally {
      inputDoc.dispose();
    }
  }
}
