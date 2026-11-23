import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/print_route.dart';
import '../services/local_file_reader.dart';
import '../services/pdf_splitter_service.dart';
import '../services/print_api_service.dart';
import '../widgets/flip_guide_3d_sheet.dart';
import '../widgets/pdf_preview_sheet.dart';

enum _StatusTone { neutral, loading, success, error }

class HomeScreen extends StatefulWidget {
  final Future<void> Function(bool currentIsDark)? onToggleTheme;

  const HomeScreen({super.key, this.onToggleTheme});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const _prefUrl = 'server_url';
  static const _prefApiKey = 'api_key';
  static const _prefRoute = 'selected_route';

  static const _defaultApiUrl = String.fromEnvironment('PRINT_API_URL');
  static const _defaultApiKey = String.fromEnvironment('PRINT_API_KEY');
  static const _shareChannel = MethodChannel('com.example.print_app/share');

  final _urlController = TextEditingController(text: _defaultApiUrl);
  final _apiKeyController = TextEditingController(text: _defaultApiKey);
  final _scrollController = ScrollController();

  List<PrintRoute> _routes = [];
  String? _selectedRouteId;
  bool _loadingRoutes = false;
  bool _sending = false;
  bool _processingPdf = false;
  bool _connected = false;

  String _statusMessage = 'Chọn hoặc chia sẻ PDF, Word, Excel, Ảnh để bắt đầu.';
  _StatusTone _statusTone = _StatusTone.neutral;

  String? _currentFileName;
  int? _currentFileBytes;
  SplitPdfResult? _splitResult;
  bool _duplexModeSelected = false;
  int _wizardStep = 1; // 1 -> 2 -> (3 nếu lẻ) -> 4 (hoàn tất)
  final Map<int, String> _stepStates = {}; // 'sent' | 'skipped'

  @override
  void initState() {
    super.initState();
    _initApp();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _urlController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  Future<void> _initApp() async {
    final prefs = await SharedPreferences.getInstance();
    final savedUrl = prefs.getString(_prefUrl);
    final savedKey = prefs.getString(_prefApiKey);
    final savedRoute = prefs.getString(_prefRoute);

    if (savedUrl != null && savedUrl.isNotEmpty) {
      _urlController.text = savedUrl;
    }
    if (savedKey != null && savedKey.isNotEmpty) {
      _apiKeyController.text = savedKey;
    }
    _selectedRouteId = savedRoute;

    _listenIncomingShare();
    if (_urlController.text.trim().isNotEmpty) {
      await _loadRoutes();
    } else {
      _setStatus(
        'Chưa có Server URL. Bấm vào nút Kết nối ở góc trên để nhập.',
        _StatusTone.error,
      );
    }
  }

  void _listenIncomingShare() {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;

    _shareChannel.setMethodCallHandler((call) async {
      if (call.method == 'onSharedFile' && call.arguments is String) {
        await _handleSharedFile(call.arguments as String);
      }
    });

    _shareChannel.invokeMethod<String>('getInitialSharedFile').then((path) {
      if (path != null && path.isNotEmpty) {
        _handleSharedFile(path);
      }
    });
  }

  Future<void> _handleSharedFile(String path) async {
    try {
      final bytes = await readLocalFileBytes(path);
      if (bytes == null) {
        _setStatus('Không tìm thấy file được chia sẻ.', _StatusTone.error);
        return;
      }
      final name = path.split(RegExp(r'[/\\]')).last;
      await _handleIncomingBytes(bytes, name);
    } catch (e) {
      _setStatus('Lỗi đọc file chia sẻ: $e', _StatusTone.error);
    }
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefUrl, _urlController.text.trim());
    await prefs.setString(_prefApiKey, _apiKeyController.text.trim());
  }

  Future<void> _saveSelectedRoute(String routeId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefRoute, routeId);
  }

  Future<void> _loadRoutes() async {
    if (_urlController.text.trim().isEmpty) {
      _setStatus('Vui lòng nhập Server URL trước khi kết nối.', _StatusTone.error);
      return;
    }

    setState(() {
      _loadingRoutes = true;
    });
    await _saveSettings();

    try {
      final routes = await PrintApiService.fetchRoutes(
        baseUrl: _urlController.text,
        apiKey: _apiKeyController.text,
      );
      if (!mounted) return;
      setState(() {
        _routes = routes;
        _connected = true;
        if (routes.isNotEmpty) {
          final stillExists = routes.any((r) => r.id == _selectedRouteId);
          if (!stillExists) {
            _selectedRouteId = routes.first.id;
          }
        } else {
          _selectedRouteId = null;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _connected = false;
      });
      _setStatus(
        'Không kết nối được API (${_urlController.text}): $e',
        _StatusTone.error,
      );
    } finally {
      if (mounted) {
        setState(() {
          _loadingRoutes = false;
        });
      }
    }
  }

  Future<void> _pickPdfFile() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: [
        'pdf',
        'doc',
        'docx',
        'xls',
        'xlsx',
        'jpg',
        'jpeg',
        'png',
        'webp',
        'heic',
        'bmp',
      ],
    );
    if (files.isEmpty) return;

    final picked = files.first;
    final bytes = await picked.readAsBytes();
    await _handleIncomingBytes(bytes, picked.name);
  }

  static bool _isOfficeFile(String fileName) {
    final lower = fileName.toLowerCase();
    return lower.endsWith('.doc') ||
        lower.endsWith('.docx') ||
        lower.endsWith('.xls') ||
        lower.endsWith('.xlsx');
  }

  static bool _isImageFile(String fileName) {
    final lower = fileName.toLowerCase();
    return lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.heic') ||
        lower.endsWith('.heif') ||
        lower.endsWith('.bmp') ||
        lower.endsWith('.gif');
  }

  Future<void> _handleIncomingBytes(Uint8List bytes, String fileName) async {
    if (_isImageFile(fileName)) {
      setState(() {
        _processingPdf = true;
        _currentFileName = fileName;
        _currentFileBytes = bytes.length;
        _splitResult = null;
        _duplexModeSelected = false;
        _wizardStep = 1;
        _stepStates.clear();
        _statusMessage = 'Đang chuyển ảnh "$fileName" sang PDF...';
        _statusTone = _StatusTone.loading;
      });
      try {
        final pdfBytes = await PdfSplitterService.imageToPdf(bytes);
        final pdfName = '${PdfSplitterService.sanitizeBaseName(fileName)}.pdf';
        await _processPdfBytes(pdfBytes, pdfName);
      } catch (e) {
        if (!mounted) return;
        _setStatus('Chuyển ảnh "$fileName" sang PDF thất bại: $e', _StatusTone.error);
        setState(() {
          _processingPdf = false;
        });
      }
      return;
    }

    if (!_isOfficeFile(fileName)) {
      await _processPdfBytes(bytes, fileName);
      return;
    }

    if (_urlController.text.trim().isEmpty) {
      _setStatus(
        'Cần kết nối Print API để chuyển "$fileName" sang PDF.',
        _StatusTone.error,
      );
      return;
    }

    setState(() {
      _processingPdf = true;
      _currentFileName = fileName;
      _currentFileBytes = bytes.length;
      _splitResult = null;
      _duplexModeSelected = false;
      _wizardStep = 1;
      _stepStates.clear();
      _statusMessage = 'Đang chuyển "$fileName" sang PDF trên server...';
      _statusTone = _StatusTone.loading;
    });

    try {
      final pdfBytes = await PrintApiService.convertToPdf(
        baseUrl: _urlController.text,
        fileBytes: bytes,
        fileName: fileName,
        apiKey: _apiKeyController.text,
      );
      final pdfName = '${PdfSplitterService.sanitizeBaseName(fileName)}.pdf';
      await _processPdfBytes(pdfBytes, pdfName);
    } catch (e) {
      if (!mounted) return;
      _setStatus('Chuyển "$fileName" sang PDF thất bại: $e', _StatusTone.error);
      setState(() {
        _processingPdf = false;
      });
    }
  }

  Future<void> _processPdfBytes(Uint8List bytes, String fileName) async {
    setState(() {
      _processingPdf = true;
      _currentFileName = fileName;
      _currentFileBytes = bytes.length;
      _splitResult = null;
      _duplexModeSelected = false;
      _wizardStep = 1;
      _stepStates.clear();
      _statusMessage = 'Đang phân tích và tách trang "$fileName"...';
      _statusTone = _StatusTone.loading;
    });

    try {
      final split = await compute(_splitInIsolate, _SplitInput(bytes, fileName));
      if (!mounted) return;
      setState(() {
        _splitResult = split;
        _statusTone = _StatusTone.success;
        if (split.pageCount <= 1) {
          _statusMessage = 'File có ${split.pageCount} trang. Sẵn sàng gửi in trực tiếp.';
        } else {
          final parity = split.isOddPageCount ? 'lẻ' : 'chẵn';
          _statusMessage =
              'Đã tách xong ${split.pageCount} trang (số trang $parity). Bấm từng bước bên dưới để in.';
        }
      });
    } catch (e) {
      if (!mounted) return;
      _setStatus('Lỗi xử lý PDF "$fileName": $e', _StatusTone.error);
    } finally {
      if (mounted) {
        setState(() {
          _processingPdf = false;
        });
      }
    }
  }

  Future<void> _sendBytes(
    int? wizardStep,
    Uint8List bytes,
    String fileName,
    String label,
  ) async {
    final routeId = _selectedRouteId;
    if (routeId == null || routeId.isEmpty) {
      _setStatus('Vui lòng kết nối API và chọn máy in trước khi gửi.', _StatusTone.error);
      return;
    }

    setState(() {
      _sending = true;
      _statusMessage = 'Đang gửi [$label] lên hàng đợi in...';
      _statusTone = _StatusTone.loading;
    });

    try {
      final jobFile = await PrintApiService.uploadPdf(
        baseUrl: _urlController.text,
        routeId: routeId,
        pdfBytes: bytes,
        fileName: fileName,
        apiKey: _apiKeyController.text,
      );
      if (!mounted) return;
      if (wizardStep != null) {
        setState(() {
          _stepStates[wizardStep] = 'sent';
          _wizardStep = _nextWizardStep(wizardStep);
        });
        _scrollToBottom();
      }
      _setStatus('Đã gửi [$label] thành công!\nJob: $jobFile', _StatusTone.success);
      await _loadRoutes();
    } catch (e) {
      if (!mounted) return;
      _setStatus('Gửi [$label] thất bại: $e', _StatusTone.error);
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
        });
      }
    }
  }

  int _nextWizardStep(int current) {
    final hasBonus = _splitResult?.bonusLastOddBytes != null;
    if (current == 1) return 2;
    if (current == 2) return hasBonus ? 3 : 4;
    return 4;
  }

  void _skipWizardStep(int step, String label) {
    setState(() {
      _stepStates[step] = 'skipped';
      _wizardStep = _nextWizardStep(step);
    });
    _setStatus('Đã bỏ qua [$label]. Chuyển sang bước tiếp theo.', _StatusTone.neutral);
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _resetWizard() {
    setState(() {
      _wizardStep = 1;
      _stepStates.clear();
    });
    _setStatus('Đã đặt lại quy trình in từng bước.', _StatusTone.neutral);
  }

  void _setStatus(String msg, _StatusTone tone) {
    setState(() {
      _statusMessage = msg;
      _statusTone = tone;
    });
  }

  void _openFlipGuide3D(bool hasBonus) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => FlipGuide3DSheet(hasBonusOddLast: hasBonus),
    );
  }

  void _openPreview({
    required String title,
    required String subtitle,
    required Uint8List pdfBytes,
    VoidCallback? onSendPrint,
  }) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => PdfPreviewSheet(
        title: title,
        subtitle: subtitle,
        pdfBytes: pdfBytes,
        onSendPrint: onSendPrint,
      ),
    );
  }

  void _openServerSettingsSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            16,
            20,
            MediaQuery.of(ctx).viewInsets.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFFCBD5E1),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Cấu hình Print API',
                style: Theme.of(ctx).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 4),
              Text(
                'Nhập địa chỉ server đang chạy print_api',
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF64748B),
                    ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _urlController,
                decoration: const InputDecoration(
                  labelText: 'Server URL',
                  hintText: 'http://192.168.1.182:8080',
                  prefixIcon: Icon(Icons.dns_outlined),
                ),
                keyboardType: TextInputType.url,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _apiKeyController,
                decoration: const InputDecoration(
                  labelText: 'API Key (tùy chọn)',
                  prefixIcon: Icon(Icons.key_outlined),
                ),
                obscureText: true,
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: () {
                  Navigator.of(ctx).pop();
                  _loadRoutes();
                },
                icon: const Icon(Icons.check_circle_outline),
                label: const Text('Lưu & Kết nối lại'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  String _formatSize(int? bytes) {
    if (bytes == null) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final split = _splitResult;
    final busy = _sending || _processingPdf;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _buildTopHeader(),
            Expanded(
              child: ListView(
                controller: _scrollController,
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                children: [
                  _buildPrinterSection(),
                  const SizedBox(height: 14),
                  _buildFileSection(busy, split),
                  const SizedBox(height: 14),
                  _buildStatusBanner(),
                  if (split != null) ...[
                    const SizedBox(height: 18),
                    _buildPrintActions(split, busy),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopHeader() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.asset(
              'assets/logo.png',
              width: 44,
              height: 44,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'PrintBridge',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.3,
                      ),
                ),
                Text(
                  'In 2 mặt & điều phối máy in',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                      ),
                ),
              ],
            ),
          ),
          InkWell(
            onTap: _openServerSettingsSheet,
            borderRadius: BorderRadius.circular(20),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: _connected
                    ? (isDark ? const Color(0xFF064E3B) : const Color(0xFFECFDF5))
                    : (isDark ? const Color(0xFF7F1D1D) : const Color(0xFFFEF2F2)),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: _connected
                      ? (isDark ? const Color(0xFF059669) : const Color(0xFFA7F3D0))
                      : (isDark ? const Color(0xFFDC2626) : const Color(0xFFFECACA)),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: _connected
                          ? const Color(0xFF10B981)
                          : const Color(0xFFEF4444),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _connected ? '${_routes.length} máy' : 'Offline',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: _connected
                          ? (isDark ? const Color(0xFF6EE7B7) : const Color(0xFF047857))
                          : (isDark ? const Color(0xFFFCA5A5) : const Color(0xFFB91C1C)),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (widget.onToggleTheme != null) ...[
            const SizedBox(width: 6),
            IconButton.filledTonal(
              tooltip: isDark ? 'Chuyển sang giao diện sáng' : 'Chuyển sang Dark Mode',
              onPressed: () => widget.onToggleTheme!(isDark),
              icon: Icon(
                isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
                size: 20,
              ),
            ),
          ],
          const SizedBox(width: 6),
          IconButton.filledTonal(
            tooltip: 'Làm mới danh sách máy in',
            onPressed: _loadingRoutes ? null : _loadRoutes,
            icon: _loadingRoutes
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded, size: 20),
          ),
        ],
      ),
    );
  }

  Widget _buildPrinterSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            'MÁY IN ĐÍCH',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: const Color(0xFF64748B),
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
          ),
        ),
        if (_routes.isEmpty)
          Card(
            child: ListTile(
              leading: const Icon(Icons.cloud_off_rounded, color: Color(0xFFEF4444)),
              title: const Text('Chưa có danh sách máy in'),
              subtitle: const Text('Chạm để cấu hình Server URL'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: _openServerSettingsSheet,
            ),
          )
        else
          SizedBox(
            height: 84,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _routes.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (ctx, i) {
                final isDark = Theme.of(ctx).brightness == Brightness.dark;
                final route = _routes[i];
                final selected = route.id == _selectedRouteId;
                return GestureDetector(
                  onTap: () {
                    setState(() => _selectedRouteId = route.id);
                    _saveSelectedRoute(route.id);
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    width: 196,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: selected
                          ? (isDark ? const Color(0xFF312E81) : const Color(0xFFEEF2FF))
                          : (isDark ? const Color(0xFF1E293B) : Colors.white),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: selected
                            ? const Color(0xFF6366F1)
                            : (isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
                        width: selected ? 1.8 : 1,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.print_rounded,
                              size: 18,
                              color: selected
                                  ? (isDark ? const Color(0xFFA5B4FC) : const Color(0xFF4F46E5))
                                  : (isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)),
                            ),
                            const Spacer(),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: route.pendingCount > 0
                                    ? (isDark ? const Color(0xFF78350F) : const Color(0xFFFEF3C7))
                                    : (isDark ? const Color(0xFF334155) : const Color(0xFFF1F5F9)),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                '${route.pendingCount} chờ',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: route.pendingCount > 0
                                      ? (isDark ? const Color(0xFFFDE68A) : const Color(0xFFB45309))
                                      : (isDark ? const Color(0xFFCBD5E1) : const Color(0xFF64748B)),
                                ),
                              ),
                            ),
                          ],
                        ),
                        Text(
                          route.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                            color: selected
                                ? (isDark ? Colors.white : const Color(0xFF312E81))
                                : (isDark ? const Color(0xFFF1F5F9) : const Color(0xFF0F172A)),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _buildFileSection(bool busy, SplitPdfResult? split) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (_currentFileName == null) {
      return InkWell(
        onTap: busy ? null : _pickPdfFile,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E293B) : Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isDark ? const Color(0xFF4338CA) : const Color(0xFFC7D2FE),
              width: 1.5,
            ),
          ),
          child: Column(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF312E81) : const Color(0xFFEEF2FF),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  Icons.upload_file_rounded,
                  color: isDark ? const Color(0xFFA5B4FC) : const Color(0xFF4F46E5),
                  size: 30,
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: busy ? null : _pickPdfFile,
                icon: const Icon(Icons.picture_as_pdf_rounded),
                label: const Text('Chọn PDF / Word / Excel / Ảnh'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Hỗ trợ PDF, Word, Excel và Ảnh (JPG/PNG/WEBP) qua chọn file hoặc Share',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
              ),
            ],
          ),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: const Color(0xFFFEE2E2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.picture_as_pdf_rounded,
                color: Color(0xFFDC2626),
                size: 26,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _currentFileName!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    children: [
                      if (split != null)
                        _infoChip(
                          '${split.pageCount} trang',
                          const Color(0xFFEEF2FF),
                          const Color(0xFF4338CA),
                        ),
                      if (_currentFileBytes != null)
                        _infoChip(
                          _formatSize(_currentFileBytes),
                          const Color(0xFFF1F5F9),
                          const Color(0xFF475569),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            if (split != null)
              IconButton(
                tooltip: 'Xem tổng quát PDF',
                onPressed: busy
                    ? null
                    : () => _openPreview(
                          title: 'Xem tổng quát',
                          subtitle: '${split.pageCount} trang • ${_currentFileName ?? ""}',
                          pdfBytes: split.fullBytes,
                        ),
                icon: const Icon(Icons.visibility_rounded),
              ),
            IconButton(
              tooltip: 'Đổi file khác',
              onPressed: busy ? null : _pickPdfFile,
              icon: const Icon(Icons.swap_horiz_rounded),
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoChip(String text, Color bg, Color fg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg),
      ),
    );
  }

  Widget _buildStatusBanner() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final (Color bg, Color border, Color fg, IconData icon) = switch (_statusTone) {
      _StatusTone.loading => isDark
          ? (
              const Color(0xFF1E1B4B),
              const Color(0xFF4338CA),
              const Color(0xFFC7D2FE),
              Icons.sync_rounded,
            )
          : (
              const Color(0xFFEEF2FF),
              const Color(0xFFC7D2FE),
              const Color(0xFF3730A3),
              Icons.sync_rounded,
            ),
      _StatusTone.success => isDark
          ? (
              const Color(0xFF064E3B),
              const Color(0xFF059669),
              const Color(0xFFA7F3D0),
              Icons.check_circle_rounded,
            )
          : (
              const Color(0xFFECFDF5),
              const Color(0xFFA7F3D0),
              const Color(0xFF065F46),
              Icons.check_circle_rounded,
            ),
      _StatusTone.error => isDark
          ? (
              const Color(0xFF450A0A),
              const Color(0xFFDC2626),
              const Color(0xFFFECACA),
              Icons.error_rounded,
            )
          : (
              const Color(0xFFFEF2F2),
              const Color(0xFFFECACA),
              const Color(0xFF991B1B),
              Icons.error_rounded,
            ),
      _StatusTone.neutral => isDark
          ? (
              const Color(0xFF1E293B),
              const Color(0xFF334155),
              const Color(0xFFCBD5E1),
              Icons.info_outline_rounded,
            )
          : (
              const Color(0xFFF8FAFC),
              const Color(0xFFE2E8F0),
              const Color(0xFF334155),
              Icons.info_outline_rounded,
            ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_sending || _processingPdf)
            Padding(
              padding: const EdgeInsets.only(right: 10, top: 2),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: fg),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(right: 10, top: 1),
              child: Icon(icon, size: 18, color: fg),
            ),
          Expanded(
            child: Text(
              _statusMessage,
              style: TextStyle(fontSize: 13, color: fg, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPrintActions(SplitPdfResult split, bool busy) {
    if (split.pageCount <= 1) {
      return FilledButton.icon(
        onPressed: busy
            ? null
            : () => _sendBytes(
                  null,
                  split.fullBytes,
                  split.fullFileName,
                  'In trực tiếp',
                ),
        icon: const Icon(Icons.print_rounded),
        label: const Text('Gửi in ngay (1 trang)'),
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      );
    }

    final hasBonus = split.bonusLastOddBytes != null;

    if (!_duplexModeSelected) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              'CHỌN KIỂU IN',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: const Color(0xFF64748B),
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
            ),
          ),
          _modeChoiceCard(
            icon: Icons.description_outlined,
            accent: const Color(0xFF334155),
            title: 'In 1 mặt',
            subtitle: 'Gửi in toàn bộ ${split.pageCount} trang một lần',
            onTap: busy
                ? null
                : () => _sendBytes(
                      null,
                      split.fullBytes,
                      split.fullFileName,
                      'In 1 mặt',
                    ),
          ),
          const SizedBox(height: 10),
          _modeChoiceCard(
            icon: Icons.auto_awesome_motion_rounded,
            accent: const Color(0xFF4F46E5),
            title: 'In 2 mặt (từng bước)',
            subtitle: hasBonus
                ? 'Chia 3 bước: Mặt trước → Lật giấy & Mặt sau → Trang lẻ cuối'
                : 'Chia 2 bước: Mặt trước → Lật giấy & Mặt sau',
            onTap: busy
                ? null
                : () {
                    setState(() {
                      _duplexModeSelected = true;
                      _wizardStep = 1;
                      _stepStates.clear();
                    });
                    _scrollToBottom();
                  },
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Row(
            children: [
              Text(
                'IN 2 MẶT TỪNG BƯỚC',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: const Color(0xFF64748B),
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                    ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: busy
                    ? null
                    : () => setState(() => _duplexModeSelected = false),
                icon: const Icon(Icons.arrow_back_rounded, size: 16),
                label: const Text('Đổi kiểu in'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
              ),
              TextButton.icon(
                onPressed: () => _openFlipGuide3D(hasBonus),
                icon: const Icon(Icons.threed_rotation_rounded, size: 16),
                label: const Text('3D'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
        ),
        _wizardStepCard(
          step: 1,
          title: 'In mặt trước (trang lẻ)',
          instruction:
              'Nạp giấy trắng bình thường rồi bấm In. Đợi máy in xong hết hẳn rồi mới cầm xấp giấy lên.',
          accent: const Color(0xFF4F46E5),
          busy: busy,
          pdfBytes: split.oddBytes,
          fileName: split.oddFileName,
          printLabel: 'Mặt trước - Trang lẻ',
          buttonText: 'In Bước 1 (Mặt trước)',
          showInline3D: false,
        ),
        const SizedBox(height: 10),
        _wizardStepCard(
          step: 2,
          title: 'Đợi in xong & Lật giấy in mặt sau',
          instruction:
              '⚠️ Đợi máy in chạy xong hết hẳn các trang lẻ rồi mới cầm giấy lên!\nCầm đọc xuôi chữ → lật úp theo trục dài (giữ nguyên đầu giấy ở trên) → đặt vào khay và bấm In.',
          accent: const Color(0xFF0284C7),
          busy: busy,
          pdfBytes: split.evenBytes,
          fileName: split.evenFileName,
          printLabel: 'Mặt sau - Trang chẵn đảo',
          buttonText: 'In Bước 2 (Mặt sau)',
          showInline3D: true,
        ),
        if (hasBonus) ...[
          const SizedBox(height: 10),
          _wizardStepCard(
            step: 3,
            title: 'In trang lẻ cuối (Bonus)',
            instruction:
                'Tổng số trang lẻ: đợi bước 2 xong hẳn, nạp 1 tờ giấy trắng rồi bấm In nốt trang ${split.pageCount}.',
            accent: const Color(0xFFD97706),
            busy: busy,
            pdfBytes: split.bonusLastOddBytes,
            fileName: split.bonusFileName,
            printLabel: 'Bonus - Trang lẻ cuối',
            buttonText: 'In Bước 3 (Trang cuối)',
            showInline3D: false,
          ),
        ],
        if (_wizardStep >= 4) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFFECFDF5),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFA7F3D0)),
            ),
            child: Row(
              children: [
                const Icon(Icons.task_alt_rounded, color: Color(0xFF059669)),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Đã hoàn tất toàn bộ các bước in!',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF065F46),
                    ),
                  ),
                ),
                TextButton(
                  onPressed: busy ? null : _resetWizard,
                  child: const Text('In lại'),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _modeChoiceCard({
    required IconData icon,
    required Color accent,
    required String title,
    required String subtitle,
    required VoidCallback? onTap,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: isDark ? const Color(0xFF1E293B) : Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: accent, size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: Color(0xFF64748B),
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: accent),
            ],
          ),
        ),
      ),
    );
  }

  Widget _wizardStepCard({
    required int step,
    required String title,
    required String instruction,
    required Color accent,
    required bool busy,
    required Uint8List? pdfBytes,
    required String fileName,
    required String printLabel,
    required String buttonText,
    required bool showInline3D,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final outcome = _stepStates[step];
    final isCurrent = _wizardStep == step;
    final isLocked = step > _wizardStep;
    final isDone = outcome == 'sent';
    final isSkipped = outcome == 'skipped';

    final Color borderColor = isCurrent
        ? accent
        : isDone
            ? const Color(0xFF10B981)
            : (isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0));

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isLocked
            ? (isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC))
            : (isDark ? const Color(0xFF1E293B) : Colors.white),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: borderColor,
          width: isCurrent ? 1.8 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: isDone
                      ? const Color(0xFFECFDF5)
                      : isSkipped
                          ? const Color(0xFFF1F5F9)
                          : isLocked
                              ? const Color(0xFFE2E8F0)
                              : accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: isDone
                    ? const Icon(Icons.check_rounded, color: Color(0xFF10B981), size: 20)
                    : isSkipped
                        ? const Icon(Icons.skip_next_rounded, color: Color(0xFF64748B), size: 20)
                        : isLocked
                            ? const Icon(Icons.lock_outline_rounded, color: Color(0xFF64748B), size: 18)
                            : Text(
                                '$step',
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 15,
                                  color: accent,
                                ),
                              ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: isLocked
                            ? (isDark ? const Color(0xFF64748B) : const Color(0xFF64748B))
                            : (isDark ? const Color(0xFFF1F5F9) : const Color(0xFF0F172A)),
                      ),
                    ),
                    Text(
                      isDone
                          ? 'Đã gửi in xong'
                          : isSkipped
                              ? 'Đã bỏ qua'
                              : isLocked
                                  ? 'Chờ hoàn thành bước trước'
                                  : fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: isDone
                            ? const Color(0xFF059669)
                            : const Color(0xFF64748B),
                      ),
                    ),
                  ],
                ),
              ),
              if (pdfBytes != null && !isLocked)
                IconButton(
                  tooltip: 'Xem trước trang sẽ in',
                  onPressed: () => _openPreview(
                    title: 'Xem trước: $title',
                    subtitle: fileName,
                    pdfBytes: pdfBytes,
                    onSendPrint: (isCurrent && !busy)
                        ? () => _sendBytes(step, pdfBytes, fileName, printLabel)
                        : null,
                  ),
                  icon: const Icon(Icons.visibility_outlined, size: 20),
                ),
            ],
          ),
          if (isCurrent) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                instruction,
                style: TextStyle(
                  fontSize: 12.5,
                  color: accent.withValues(alpha: 0.95),
                  height: 1.35,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            if (showInline3D) ...[
              const SizedBox(height: 10),
              const FlipStep3DVisual(step: 2, height: 175),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: busy ? null : () => _skipWizardStep(step, printLabel),
                  icon: const Icon(Icons.skip_next_rounded, size: 18),
                  label: const Text('Skip'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: (busy || pdfBytes == null)
                        ? null
                        : () => _sendBytes(step, pdfBytes, fileName, printLabel),
                    icon: const Icon(Icons.print_rounded, size: 18),
                    label: Text(buttonText),
                    style: FilledButton.styleFrom(
                      backgroundColor: accent,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _SplitInput {
  final Uint8List bytes;
  final String fileName;
  const _SplitInput(this.bytes, this.fileName);
}

SplitPdfResult _splitInIsolate(_SplitInput input) {
  return PdfSplitterService.analyzeAndSplit(input.bytes, input.fileName);
}
