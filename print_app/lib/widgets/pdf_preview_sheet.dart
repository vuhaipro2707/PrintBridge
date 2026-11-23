import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class PdfPreviewSheet extends StatefulWidget {
  final String title;
  final String subtitle;
  final Uint8List pdfBytes;
  final VoidCallback? onSendPrint;

  const PdfPreviewSheet({
    super.key,
    required this.title,
    required this.subtitle,
    required this.pdfBytes,
    this.onSendPrint,
  });

  @override
  State<PdfPreviewSheet> createState() => _PdfPreviewSheetState();
}

class _PdfPreviewSheetState extends State<PdfPreviewSheet> {
  static const _previewChannel = MethodChannel('com.example.print_app/pdf_preview');

  late Future<List<Uint8List>> _pagesFuture;

  @override
  void initState() {
    super.initState();
    _pagesFuture = _renderPages();
  }

  Future<List<Uint8List>> _renderPages() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      throw UnsupportedError('Xem trước trang PDF hiện chỉ hỗ trợ trên Android.');
    }
    final result = await _previewChannel.invokeMethod<List<dynamic>>(
      'renderPdfPages',
      <String, dynamic>{
        'bytes': widget.pdfBytes,
        'maxWidth': 1000,
      },
    );
    if (result == null) return [];
    return result.whereType<Uint8List>().toList();
  }

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      heightFactor: 0.9,
      child: Column(
        children: [
          const SizedBox(height: 10),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: const Color(0xFFCBD5E1),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      Text(
                        widget.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF64748B),
                        ),
                      ),
                    ],
                  ),
                ),
                if (widget.onSendPrint != null)
                  FilledButton.icon(
                    onPressed: () {
                      Navigator.of(context).pop();
                      widget.onSendPrint!();
                    },
                    icon: const Icon(Icons.send_rounded, size: 16),
                    label: const Text('Gửi in'),
                  ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: Container(
              color: Theme.of(context).brightness == Brightness.dark
                  ? const Color(0xFF0B1120)
                  : const Color(0xFFF1F5F9),
              child: FutureBuilder<List<Uint8List>>(
                future: _pagesFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 12),
                          Text('Đang dựng trang xem trước...'),
                        ],
                      ),
                    );
                  }
                  if (snapshot.hasError) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'Không thể hiển thị xem trước: ${snapshot.error}',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    );
                  }
                  final pages = snapshot.data ?? [];
                  if (pages.isEmpty) {
                    return const Center(child: Text('PDF không có trang nào.'));
                  }

                  return ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: pages.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 16),
                    itemBuilder: (ctx, i) {
                      return Column(
                        children: [
                          Container(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: const Color(0xFFCBD5E1)),
                              boxShadow: const [
                                BoxShadow(
                                  color: Color(0x14000000),
                                  blurRadius: 10,
                                  offset: Offset(0, 3),
                                ),
                              ],
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: InteractiveViewer(
                              minScale: 1.0,
                              maxScale: 3.5,
                              child: Image.memory(
                                pages[i],
                                fit: BoxFit.contain,
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Trang ${i + 1} / ${pages.length}',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF64748B),
                            ),
                          ),
                        ],
                      );
                    },
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
