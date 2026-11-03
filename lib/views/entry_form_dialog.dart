import 'package:flutter/material.dart';
import 'package:keepass_flutter/keepass_flutter.dart';

import 'package:type_the_clipboard/services/keepass_service.dart';

/// Result of the add/edit entry form.
class EntryFormResult {
  final String title;
  final String username;
  final String password;
  final String url;
  final String notes;
  final String groupUuid;

  /// Custom Auto-Type sequence. Stored in the entry's custom data under
  /// [keepassAutoTypeKey]; left empty, the database default is used.
  final String autoType;
  final String? originalAutoType;

  const EntryFormResult({
    required this.title,
    required this.username,
    required this.password,
    required this.url,
    required this.notes,
    required this.groupUuid,
    this.autoType = '',
    this.originalAutoType,
  });

  Map<String, String> toFields() => {
        'Title': title,
        'UserName': username,
        'Password': password,
        'URL': url,
        'Notes': notes,
        // Custom data key, see KeePassService.autoTypeFor.
        keepassAutoTypeKey: autoType,
        // Signals _writeFields to drop the key when cleared.
        keepassAutoTypeClearKey: (autoType.isEmpty &&
                (originalAutoType ?? '').isNotEmpty)
            ? '1'
            : '',
      };
}

/// Custom-data key holding an entry's Auto-Type sequence.
const String keepassAutoTypeKey = 'AutoType';

/// Internal marker telling the service that the user cleared the custom
/// Auto-Type sequence, so the key must be removed from the entry.
const String keepassAutoTypeClearKey = '__autoTypeClear';

const Color _surface = Color(0xFF1E1E2E);
const Color _fieldFill = Color(0xFF181825);
const Color _border = Color(0xFF45475A);
const Color _accent = Color(0xFF89B4FA);
const Color _textColor = Color(0xFFCDD6F4);
const Color _muted = Color(0xFFA6ADC8);
const Color _danger = Color(0xFFE78284);

InputDecoration _decoration(String label, {String? hint, Widget? suffix}) {
  return InputDecoration(
    labelText: label,
    hintText: hint,
    labelStyle: const TextStyle(color: _muted, fontSize: 11),
    hintStyle: const TextStyle(color: Color(0xFF585B70), fontSize: 11),
    filled: true,
    fillColor: _fieldFill,
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
    suffixIcon: suffix,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: const BorderSide(color: _border),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: const BorderSide(color: _accent),
    ),
  );
}

const TextStyle _textStyle = TextStyle(color: _textColor, fontSize: 12);

/// Modal dialog to create or edit a KeePass entry.
///
/// Returns `null` when cancelled.
Future<EntryFormResult?> showEntryFormDialog(
  BuildContext context, {
  required List<KeePassGroupRef> groups,
  KeePassEntryRef? entry,
  String? initialGroupUuid,
}) {
  return showDialog<EntryFormResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _EntryFormDialog(
      groups: groups,
      entry: entry,
      initialGroupUuid: initialGroupUuid,
    ),
  );
}

class _EntryFormDialog extends StatefulWidget {
  final List<KeePassGroupRef> groups;
  final KeePassEntryRef? entry;
  final String? initialGroupUuid;

  const _EntryFormDialog({
    required this.groups,
    this.entry,
    this.initialGroupUuid,
  });

  @override
  State<_EntryFormDialog> createState() => _EntryFormDialogState();
}

class _EntryFormDialogState extends State<_EntryFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;
  late final TextEditingController _urlController;
  late final TextEditingController _notesController;
  late final TextEditingController _autoTypeController;
  late String _groupUuid;
  bool _obscurePassword = true;

  bool get _isEdit => widget.entry != null;

  @override
  void initState() {
    super.initState();
    final entry = widget.entry;
    _titleController = TextEditingController(text: entry?.title ?? '');
    _usernameController = TextEditingController(text: entry?.username ?? '');
    _passwordController = TextEditingController(text: entry?.password ?? '');
    _urlController = TextEditingController(text: entry?.url ?? '');
    _notesController = TextEditingController(text: entry?.notes ?? '');
    _autoTypeController = TextEditingController(
      text: entry?.entry.getField(keepassAutoTypeKey) ?? '',
    );
    _groupUuid = widget.initialGroupUuid ??
        entry?.groupUuid ??
        (widget.groups.isNotEmpty ? widget.groups.first.uuid : '');
  }

  @override
  void dispose() {
    _titleController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _urlController.dispose();
    _notesController.dispose();
    _autoTypeController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(
      EntryFormResult(
        title: _titleController.text.trim(),
        username: _usernameController.text.trim(),
        password: _passwordController.text,
        url: _urlController.text.trim(),
        notes: _notesController.text,
        groupUuid: _groupUuid,
        autoType: _autoTypeController.text.trim(),
        originalAutoType: widget.entry?.entry.getField(keepassAutoTypeKey),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: _surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 560),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                child: Text(
                  _isEdit ? 'Edit entry' : 'New entry',
                  style: const TextStyle(
                    color: _textColor,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextFormField(
                        controller: _titleController,
                        style: _textStyle,
                        decoration: _decoration('Title'),
                        validator: (value) =>
                            (value == null || value.trim().isEmpty)
                                ? 'Title is required'
                                : null,
                      ),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _usernameController,
                        style: _textStyle,
                        decoration: _decoration('Username'),
                      ),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _passwordController,
                        style: _textStyle,
                        obscureText: _obscurePassword,
                        decoration: _decoration(
                          'Password',
                          suffix: IconButton(
                            icon: Icon(
                              _obscurePassword
                                  ? Icons.visibility_off
                                  : Icons.visibility,
                              size: 14,
                              color: _muted,
                            ),
                            onPressed: () => setState(
                              () => _obscurePassword = !_obscurePassword,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _urlController,
                        style: _textStyle,
                        decoration: _decoration(
                          'URL',
                          hint: 'https://example.com',
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _notesController,
                        style: _textStyle,
                        maxLines: 3,
                        decoration: _decoration('Notes'),
                      ),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _autoTypeController,
                        style: _textStyle,
                        decoration: _decoration(
                          'Auto-Type sequence (optional)',
                          hint: r'{USERNAME}{TAB}{PASSWORD}{ENTER}',
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Leave empty to use the database / group default. '
                        'Placeholders: {USERNAME} {PASSWORD} {TOTP} {TAB} '
                        '{ENTER}.',
                        style: TextStyle(
                          color: _muted.withValues(alpha: 0.8),
                          fontSize: 9,
                        ),
                      ),
                      if (!_isEdit && widget.groups.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        DropdownButtonFormField<String>(
                          initialValue: _groupUuid,
                          dropdownColor: _fieldFill,
                          style: _textStyle,
                          decoration: _decoration('Group'),
                          isExpanded: true,
                          items: widget.groups
                              .map(
                                (g) => DropdownMenuItem(
                                  value: g.uuid,
                                  child: Text(
                                    g.path,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            if (value != null) {
                              setState(() => _groupUuid = value);
                            }
                          },
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 14),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text(
                        'Cancel',
                        style: TextStyle(color: _muted),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: _accent,
                        foregroundColor: _surface,
                      ),
                      onPressed: _submit,
                      child: Text(_isEdit ? 'Save' : 'Create'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Confirmation dialog for deleting an entry.
Future<bool> showDeleteEntryDialog(BuildContext context, String title) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      backgroundColor: _surface,
      title: const Text(
        'Delete entry?',
        style: TextStyle(color: _textColor, fontSize: 14),
      ),
      content: Text(
        '"$title" will be deleted from the database.',
        style: const TextStyle(color: _muted, fontSize: 12),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel', style: TextStyle(color: _muted)),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: _danger,
            foregroundColor: _surface,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// Shows an error message from a KeePass operation.
Future<void> showKeepassError(
  BuildContext context,
  Object error,
) async {
  final message = error is KeePassError ? error.message : error.toString();
  await showDialog<void>(
    context: context,
    builder: (_) => AlertDialog(
      backgroundColor: _surface,
      title: const Text(
        'KeePass error',
        style: TextStyle(color: _danger, fontSize: 14),
      ),
      content: Text(
        message,
        style: const TextStyle(color: _textColor, fontSize: 12),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('OK', style: TextStyle(color: _muted)),
        ),
      ],
    ),
  );
}
