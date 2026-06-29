import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../data/datasources/local/database.dart' as db;
import 'provider_manager.dart';

/// Shows the Edit Provider dialog for an existing M3U provider.
/// Returns true when the provider was updated.
Future<bool?> showEditProviderDialog(BuildContext context, db.Provider provider) {
  return Navigator.of(context).push<bool>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _EditProviderPage(provider: provider),
    ),
  );
}

class _EditProviderPage extends ConsumerStatefulWidget {
  final db.Provider provider;
  const _EditProviderPage({required this.provider});

  @override
  ConsumerState<_EditProviderPage> createState() => _EditProviderPageState();
}

class _EditProviderPageState extends ConsumerState<_EditProviderPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _url;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.provider.name);
    _url = TextEditingController(text: widget.provider.url ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    super.dispose();
  }

  String? _validateRequired(String? value) {
    if (value == null || value.trim().isEmpty) return 'Required';
    return null;
  }

  String? _validateM3uSource(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Enter a URL or import a file';
    }
    return null;
  }

  Future<void> _pickM3uFile() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Import M3U File',
      type: FileType.custom,
      allowedExtensions: const ['m3u', 'm3u8', 'txt'],
    );
    final path = result?.files.single.path;
    if (path == null) return;
    setState(() {
      _url.text = path;
      if (_name.text.trim().isEmpty) {
        _name.text = p.basenameWithoutExtension(path);
      }
    });
  }

  Future<void> _pasteUrl() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) {
      _url.text = data!.text!;
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    try {
      final manager = ref.read(providerManagerProvider);
      await manager.updateM3uProvider(
        id: widget.provider.id,
        name: _name.text.trim(),
        url: _url.text.trim(),
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A2E),
          title: const Text('Error'),
          content: Text('Failed to update provider:\n$e'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          final pf = FocusManager.instance.primaryFocus;
          if (pf?.context?.findAncestorWidgetOfExactType<EditableText>() !=
              null) {
            pf!.unfocus();
            return;
          }
          Future.microtask(() {
            Navigator.of(context).pop();
          });
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: const Color(0xFF0A0A0F),
          appBar: AppBar(
            leading: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.of(context).pop(),
            ),
            title: const Text('Edit Provider'),
          ),
          body: Form(
            key: _formKey,
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                TextFormField(
                  controller: _name,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Provider Name',
                    hintText: 'e.g. My IPTV',
                  ),
                  validator: _validateRequired,
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _url,
                  decoration: const InputDecoration(
                    labelText: 'M3U URL or File',
                    hintText: 'http://…  or import a local file',
                  ),
                  validator: _validateM3uSource,
                  keyboardType: TextInputType.url,
                  maxLines: null,
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _save(),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton.icon(
                      onPressed: _pickM3uFile,
                      icon: const Icon(Icons.folder_open, size: 18),
                      label: const Text('Import File'),
                    ),
                    const SizedBox(width: 8),
                    TextButton.icon(
                      onPressed: _pasteUrl,
                      icon: const Icon(Icons.paste, size: 18),
                      label: const Text('Paste URL'),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                SizedBox(
                  height: 48,
                  child: FilledButton(
                    onPressed: _loading ? null : _save,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF6C5CE7),
                    ),
                    child: _loading
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text('Save', style: TextStyle(fontSize: 16)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
