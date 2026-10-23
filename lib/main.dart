import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

void main() => runApp(const TradeCompanionApp());

class TradeCompanionApp extends StatelessWidget {
  const TradeCompanionApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'همراه معامله‌گر',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF176B5B)),
          scaffoldBackgroundColor: const Color(0xFFF5F7F8),
          cardTheme: const CardThemeData(color: Colors.white, elevation: 1),
        ),
        home: const Directionality(
          textDirection: TextDirection.rtl,
          child: TradingHomePage(),
        ),
      );
}

class BackendClient {
  BackendClient({required this.baseUrl, required this.sessionToken});

  final String baseUrl;
  final String sessionToken;

  Uri _uri(String path) {
    final base = Uri.tryParse(baseUrl.trim());
    if (base == null || base.scheme != 'https' || base.host.isEmpty) {
      throw const FormatException('نشانی سرویس باید HTTPS معتبر باشد.');
    }
    return base.resolve(path);
  }

  Future<dynamic> request(String method, String path, {Object? body}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
    try {
      final uri = _uri(path);
      final HttpClientRequest req = switch (method) {
        'POST' => await client.postUrl(uri),
        _ => await client.getUrl(uri),
      };
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      if (sessionToken.trim().isNotEmpty) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${sessionToken.trim()}');
      }
      if (body != null) req.write(jsonEncode(body));
      final response = await req.close().timeout(const Duration(seconds: 15));
      final text = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('خطای سرویس (${response.statusCode})${text.isEmpty ? '' : ': $text'}');
      }
      return text.isEmpty ? <String, dynamic>{} : jsonDecode(text);
    } finally {
      client.close(force: true);
    }
  }
}

class TradingHomePage extends StatefulWidget {
  const TradingHomePage({super.key});
  @override
  State<TradingHomePage> createState() => _TradingHomePageState();
}

class _TradingHomePageState extends State<TradingHomePage> {
  final _urlController = TextEditingController();
  final _tokenController = TextEditingController();
  bool _busy = false;
  bool _running = false;
  String? _message;
  String? _error;
  double? _equity;
  List<dynamic> _positions = const [];

  BackendClient get _api => BackendClient(
        baseUrl: _urlController.text,
        sessionToken: _tokenController.text,
      );

  @override
  void dispose() {
    _urlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _runAction(String label, Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      await action();
      if (mounted) setState(() => _message = label);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() async {
    await _runAction('وضعیت به‌روزرسانی شد', () async {
      final data = await _api.request('GET', '/v1/status') as Map<String, dynamic>;
      final items = data['openPositions'];
      setState(() {
        _running = data['botStatus'] == 'running';
        _equity = (data['accountEquity'] as num?)?.toDouble();
        _positions = items is List ? items : const [];
      });
    });
  }

  Future<void> _botAction(bool start) async {
    await _runAction(start ? 'درخواست شروع ارسال شد' : 'درخواست توقف ارسال شد', () async {
      await _api.request('POST', start ? '/v1/bot/start' : '/v1/bot/stop', body: const {});
      await _refreshQuietly();
    });
  }

  Future<void> _refreshQuietly() async {
    final data = await _api.request('GET', '/v1/status') as Map<String, dynamic>;
    final items = data['openPositions'];
    setState(() {
      _running = data['botStatus'] == 'running';
      _equity = (data['accountEquity'] as num?)?.toDouble();
      _positions = items is List ? items : const [];
    });
  }

  Future<void> _telegramTest() async {
    await _runAction('درخواست پیام آزمایشی به تلگرام ارسال شد', () async {
      await _api.request('POST', '/v1/telegram/test', body: const {});
    });
  }

  void _showSettings() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => Directionality(
        textDirection: TextDirection.rtl,
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.viewInsetsOf(context).bottom + 24),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('اتصال امن', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            const Text('نشانی HTTPS سرویس ابری را وارد کنید. توکن این نشست فقط در حافظه برنامه می‌ماند.'),
            const SizedBox(height: 12),
            TextField(controller: _urlController, keyboardType: TextInputType.url, decoration: const InputDecoration(labelText: 'نشانی API ابری (HTTPS)', hintText: 'https://api.example.com')),
            const SizedBox(height: 10),
            TextField(controller: _tokenController, obscureText: true, decoration: const InputDecoration(labelText: 'توکن نشست برنامه (اختیاری)')),
            const SizedBox(height: 12),
            const Text('کلید MetaApi و توکن Telegram باید فقط روی سرویس امن/Serverless نگه‌داری شوند، نه در APK.', style: TextStyle(color: Colors.deepOrange)),
            const SizedBox(height: 12),
            FilledButton(onPressed: () => Navigator.pop(context), child: const Text('ذخیره موقت')),
          ]),
        ),
      ),
    );
  }

  String _money(dynamic value) {
    final n = (value as num?)?.toDouble();
    if (n == null) return '—';
    return '${n < 0 ? '-' : ''}\$${n.abs().toStringAsFixed(2)}';
  }

  @override
  Widget build(BuildContext context) {
    final color = _running ? const Color(0xFF16845B) : Colors.blueGrey;
    return Scaffold(
      appBar: AppBar(
        title: const Text('همراه معامله‌گر'),
        actions: [IconButton(tooltip: 'تنظیم اتصال', onPressed: _showSettings, icon: const Icon(Icons.settings_outlined))],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Card(child: Padding(padding: const EdgeInsets.all(18), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [const Expanded(child: Text('وضعیت ربات', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))), Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), decoration: BoxDecoration(color: color.withValues(alpha: .12), borderRadius: BorderRadius.circular(20)), child: Text(_running ? 'فعال' : 'متوقف', style: TextStyle(color: color, fontWeight: FontWeight.w700))) ]),
            const SizedBox(height: 16),
            Text('ارزش حساب', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.black54)),
            const SizedBox(height: 4),
            Text(_equity == null ? '—' : _money(_equity), style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            Row(children: [Expanded(child: FilledButton.icon(onPressed: _busy ? null : () => _botAction(true), icon: const Icon(Icons.play_arrow), label: const Text('شروع'))), const SizedBox(width: 10), Expanded(child: OutlinedButton.icon(onPressed: _busy ? null : () => _botAction(false), icon: const Icon(Icons.stop), label: const Text('توقف')))]),
            const SizedBox(height: 8),
            OutlinedButton.icon(onPressed: _busy ? null : _refresh, icon: const Icon(Icons.sync), label: const Text('به‌روزرسانی وضعیت')),
          ]))),
          if (_message != null) _Notice(text: _message!, color: Colors.green),
          if (_error != null) _Notice(text: _error!, color: Colors.red),
          Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [const Expanded(child: Text('پوزیشن‌های باز', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))), Text('${_positions.length} مورد')]),
            const SizedBox(height: 8),
            if (_positions.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 14), child: Center(child: Text('داده‌ای از سرویس دریافت نشده است. اتصال API را تنظیم کنید.'))),
            ..._positions.map((p) {
              final item = p is Map<String, dynamic> ? p : <String, dynamic>{};
              return ListTile(contentPadding: EdgeInsets.zero, title: Text('${item['symbol'] ?? '—'}  ${item['side'] ?? ''}'), subtitle: Text('حجم: ${item['volume'] ?? '—'}  |  شناسه: ${item['id'] ?? '—'}'), trailing: Text(_money(item['pnl'])));
            }),
          ]))),
          Card(child: ListTile(leading: const Icon(Icons.send_outlined), title: const Text('اعلان تلگرام'), subtitle: const Text('ارسال پیام آزمایشی از مسیر امن سرویس'), trailing: IconButton(onPressed: _busy ? null : _telegramTest, icon: const Icon(Icons.arrow_forward))),),
          const Padding(padding: EdgeInsets.all(8), child: Text('این نسخه، پوسته کلاینت است. تا وقتی API امن MetaApi/Telegram راه‌اندازی و متصل نشده، معامله زنده یا پیام واقعی ارسال نمی‌شود.', textAlign: TextAlign.center, style: TextStyle(color: Colors.blueGrey))),
          if (_busy) const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator())),
        ]),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text, required this.color});
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Card(color: color.withValues(alpha: .08), child: Padding(padding: const EdgeInsets.all(12), child: Text(text, style: TextStyle(color: color))));
}
