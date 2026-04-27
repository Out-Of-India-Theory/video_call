import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:oit_video_call/oit_video_call.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load();
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});
  @override
  Widget build(BuildContext context) =>
      MaterialApp(home: const HomePage());
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _userIdCtrl = TextEditingController(text: 'demo-user');
  final _userNameCtrl = TextEditingController(text: 'Demo User');
  final _callIdCtrl = TextEditingController();
  bool _audioOnly = false;
  bool _initialized = false;

  Future<void> _initAndJoin() async {
    final apiKey = dotenv.env['STREAM_API_KEY'];
    final demoToken = dotenv.env['STREAM_DEMO_TOKEN'];
    if (apiKey == null || demoToken == null) {
      _toast('Set STREAM_API_KEY and STREAM_DEMO_TOKEN in .env');
      return;
    }

    if (!_initialized) {
      await OitVideoCall.init(
        apiKey: apiKey,
        user: VideoUser(id: _userIdCtrl.text, name: _userNameCtrl.text),
        tokenProvider: () async => demoToken,
      );
      _initialized = true;
    }

    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => OitVideoCall.callScreen(
          callId: _callIdCtrl.text,
          audioOnly: _audioOnly,
        ),
      ),
    );
  }

  void _toast(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('oit_video_call demo')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(controller: _userIdCtrl, decoration: const InputDecoration(labelText: 'User ID')),
            TextField(controller: _userNameCtrl, decoration: const InputDecoration(labelText: 'User Name')),
            TextField(controller: _callIdCtrl, decoration: const InputDecoration(labelText: 'Call ID')),
            CheckboxListTile(
              title: const Text('Audio only'),
              value: _audioOnly,
              onChanged: (v) => setState(() => _audioOnly = v ?? false),
            ),
            const SizedBox(height: 24),
            FilledButton(onPressed: _initAndJoin, child: const Text('Join call')),
          ],
        ),
      ),
    );
  }
}
