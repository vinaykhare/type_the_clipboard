import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'package:type_the_clipboard/core/keyboard_navigable.dart';
import 'package:type_the_clipboard/input_simulator.dart';
import 'package:type_the_clipboard/services/auto_type_executor.dart';
import 'package:type_the_clipboard/services/keepass_service.dart';
import 'package:type_the_clipboard/services/settings_service.dart';
import 'package:type_the_clipboard/views/entry_form_dialog.dart';

/// Shows KeePass entries that match the active window title and lets the user
/// fill credentials. Also acts as a lightweight KeePass manager: search,
/// create, edit and delete entries.
class CredentialsView extends StatefulWidget {
  final SettingsService settings;
  final String? targetTitle;
  final int? targetHwnd;

  const CredentialsView({
    super.key,
    required this.settings,
    this.targetTitle,
    this.targetHwnd,
  });

  @override
  State<CredentialsView> createState() => CredentialsViewState();
}

class CredentialsViewState extends State<CredentialsView>
    implements KeyboardNavigableView {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();

  // Kept open for the lifetime of the view so entries can be edited and
  // saved back; the database handle must outlive every `Entry` object.
  KeePassService? _service;

  List<KeePassEntryRef> _entries = [];
  List<KeePassEntryRef> _allEntries = [];
  int _selectedIndex = -1;
  bool _loading = false;
  String? _error;
  String _filter = '';

  /// When true the list ignores the window match and covers the whole database.
  bool _searchAll = false;

  @override
  void initState() {
    super.initState();
    _service = KeePassService(widget.settings);
    _loadEntries();
  }

  @override
  void didUpdateWidget(CredentialsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.targetTitle != oldWidget.targetTitle) {
      _searchController.clear();
      _filter = '';
      _loadEntries();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    _service?.close();
    super.dispose();
  }

  /// Called by the parent when the Credentials tab becomes visible, so the
  /// list reflects changes made elsewhere.
  Future<void> reload() => _loadEntries();

  List<KeePassEntryRef> get _visibleEntries {
    // "Search all" ignores the window match, so entries can be found and
    // edited even when the window title no longer matches anything.
    final base = _searchAll ? _allEntries : _entries;
    final query = _filter.trim().toLowerCase();
    if (query.isEmpty) return base;
    return base.where((e) {
      return e.title.toLowerCase().contains(query) ||
          e.username.toLowerCase().contains(query) ||
          e.url.toLowerCase().contains(query) ||
          e.groupName.toLowerCase().contains(query) ||
          e.notes.toLowerCase().contains(query);
    }).toList();
  }

  Future<void> _loadEntries() async {
    if (!widget.settings.hasKeepassConfig) {
      setState(() {
        _entries = [];
        _allEntries = [];
        _selectedIndex = -1;
        _loading = false;
        _error = 'KeePass not configured. Add details in Settings.';
      });
      return;
    }

    final hint = widget.targetTitle?.trim() ?? '';
    setState(() => _loading = true);

    final service = _service ??= KeePassService(widget.settings);
    try {
      final all = await service.allEntries();
      final matched = hint.isEmpty
          ? all
          : await service.findEntries(hint);
      if (!mounted) return;
      if (all.isEmpty && service.lastError != null) {
        setState(() {
          _allEntries = [];
          _entries = [];
          _selectedIndex = -1;
          _loading = false;
          _error = 'KeePass: ${service.lastError}';
        });
        return;
      }
      setState(() {
        _allEntries = all;
        _entries = matched;
        _selectedIndex = matched.isNotEmpty ? 0 : -1;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      debugPrint('[Credentials] load failed: $e');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'KeePass error: $e';
      });
    }
  }

  void _scrollToSelected() {
    if (_selectedIndex < 0 || !_scrollController.hasClients) return;
    const itemHeight = 84.0;
    final offset = _selectedIndex * itemHeight;
    _scrollController.animateTo(
      offset.clamp(0.0, _scrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
    );
  }

  @override
  void selectPrevious() {
    final visible = _visibleEntries;
    if (visible.isEmpty) return;
    setState(() {
      _selectedIndex = _selectedIndex < 0
          ? visible.length - 1
          : (_selectedIndex - 1).clamp(0, visible.length - 1);
    });
    _scrollToSelected();
  }

  @override
  void selectNext() {
    final visible = _visibleEntries;
    if (visible.isEmpty) return;
    setState(() {
      _selectedIndex = _selectedIndex < 0
          ? 0
          : (_selectedIndex + 1).clamp(0, visible.length - 1);
    });
    _scrollToSelected();
  }

  @override
  Future<void> confirm() async {
    final visible = _visibleEntries;
    if (_selectedIndex < 0 || _selectedIndex >= visible.length) return;
    await _fillEntry(visible[_selectedIndex]);
  }

  /// Returns the window the credentials should be typed into, or 0 when
  /// there is no usable target.
  int _resolveTarget() {
    final hwnd = widget.targetHwnd ?? InputSimulator.getActiveWindow();
    if (hwnd == 0) return 0;
    // A stale/dead handle or the shell desktop can never take focus, so
    // typing would silently do nothing.
    return InputSimulator.isUsableTarget(hwnd) ? hwnd : 0;
  }

  /// Copies [value] and explains that there was no window to type into.
  Future<void> _copyWithNotice(String? value, String what) async {
    if (value == null || value.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    _showMessage(
      'No target window to type into, so the $what was copied instead.',
    );
  }

  Future<void> _fillEntry(KeePassEntryRef ref) async {
    final hwnd = _resolveTarget();
    if (hwnd == 0) {
      // Nothing to type into (no window captured, desktop focused, or the
      // window was closed). Copy the password so the click still helps.
      await _copyWithNotice(ref.password, 'password');
      return;
    }

    final service = _service ??= KeePassService(widget.settings);
    try {
      final sequence = await service.autoTypeSequenceFor(ref);
      if (sequence.isEmpty) {
        if (mounted) _showMessage('This entry has no username or password.');
        return;
      }

      await windowManager.hide();
      final ok = await AutoTypeExecutor.execute(
        sequence,
        username: ref.username,
        password: ref.password,
        targetHwnd: hwnd,
      );
      if (!ok && mounted) {
        await Clipboard.setData(ClipboardData(text: ref.password));
        await windowManager.show();
        if (mounted) {
          _showMessage(
            'The target window would not accept input, so the password was '
            'copied to the clipboard instead.',
          );
        }
      }
    } catch (e) {
      debugPrint('[Credentials] fill failed: $e');
      if (mounted) _showMessage('Auto-Type failed: $e');
    }
  }

  /// Typed when the user presses "u" on the Credentials tab: the username of
  /// the highlighted entry only.
  @override
  Future<bool> typeUsername() async {
    final visible = _visibleEntries;
    if (_selectedIndex < 0 || _selectedIndex >= visible.length) return false;
    await _typeField(visible[_selectedIndex], '{USERNAME}');
    return true;
  }

  /// Typed when the user presses "p" on the Credentials tab: the password of
  /// the highlighted entry only.
  @override
  Future<bool> typePassword() async {
    final visible = _visibleEntries;
    if (_selectedIndex < 0 || _selectedIndex >= visible.length) return false;
    await _typeField(visible[_selectedIndex], '{PASSWORD}');
    return true;
  }

  Future<void> _typeField(KeePassEntryRef ref, String token) async {
    final value = token.contains('PASSWORD') ? ref.password : ref.username;
    final label = token.contains('PASSWORD') ? 'password' : 'username';

    final hwnd = _resolveTarget();
    if (hwnd == 0) {
      await _copyWithNotice(value, label);
      return;
    }

    try {
      await windowManager.hide();
      final ok = await AutoTypeExecutor.execute(
        token,
        username: ref.username,
        password: ref.password,
        targetHwnd: hwnd,
      );
      if (!ok && mounted) {
        await Clipboard.setData(ClipboardData(text: value));
        await windowManager.show();
        if (mounted) {
          _showMessage(
            'The target window would not accept input, so the $label was '
            'copied to the clipboard instead.',
          );
        }
      }
    } catch (e) {
      debugPrint('[Credentials] type field failed: $e');
      if (mounted) _showMessage('Typing failed: $e');
    }
  }

  Future<void> _copyValue(String? value) async {
    if (value == null || value.isEmpty) return;
    try {
      await Clipboard.setData(ClipboardData(text: value));
      await windowManager.hide();
    } catch (e) {
      debugPrint('[Credentials] copy failed: $e');
      if (mounted) _showMessage('Copy failed: $e');
    }
  }

  Future<void> _addEntry() async {
    final service = _service ??= KeePassService(widget.settings);
    try {
      final groups = await service.groups();
      if (!mounted) return;
      final result = await showEntryFormDialog(
        context,
        groups: groups,
        initialGroupUuid: groups.isNotEmpty ? groups.last.uuid : null,
      );
      if (result == null) return;
      await service.createEntry(result.groupUuid, result.toFields());
      await service.save();
      await _loadEntries();
      if (mounted) _showMessage('Entry created.');
    } catch (e) {
      if (mounted) await showKeepassError(context, e);
    }
  }

  Future<void> _editEntry(KeePassEntryRef ref) async {
    final service = _service ??= KeePassService(widget.settings);
    try {
      final groups = await service.groups();
      if (!mounted) return;
      final result = await showEntryFormDialog(
        context,
        groups: groups,
        entry: ref,
      );
      if (result == null) return;
      await service.updateEntry(ref.uuid, result.toFields());
      await service.save();
      await _loadEntries();
      if (mounted) _showMessage('Entry updated.');
    } catch (e) {
      if (mounted) await showKeepassError(context, e);
    }
  }

  Future<void> _deleteEntry(KeePassEntryRef ref) async {
    final confirmed = await showDeleteEntryDialog(
      context,
      ref.title.isEmpty ? '(no title)' : ref.title,
    );
    if (!confirmed) return;
    final service = _service ??= KeePassService(widget.settings);
    try {
      await service.deleteEntry(ref.uuid);
      await service.save();
      await _loadEntries();
      if (mounted) _showMessage('Entry deleted.');
    } catch (e) {
      if (mounted) await showKeepassError(context, e);
    }
  }

  void _showMessage(String message) {
    debugPrint('[Credentials] $message');
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 4),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }

    final visible = _visibleEntries;
    final title = widget.targetTitle?.trim() ?? '';
    final hasTarget = _resolveTarget() != 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!hasTarget)
          Container(
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF313244),
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Text(
              'No target window. Open this tab from the app you want to fill '
              '(Ctrl+Alt+K) — until then the buttons copy to the clipboard.',
              style: TextStyle(color: Color(0xFFF9E2AF), fontSize: 9),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title.isNotEmpty
                      ? 'Matches for "$title"'
                      : 'All KeePass entries',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFFCDD6F4),
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Reload',
                icon: const Icon(
                  Icons.refresh,
                  size: 16,
                  color: Color(0xFFA6ADC8),
                ),
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                padding: EdgeInsets.zero,
                onPressed: _loadEntries,
              ),
              IconButton(
                tooltip: 'New entry',
                icon: const Icon(
                  Icons.add_circle_outline,
                  size: 16,
                  color: Color(0xFFA6E3A1),
                ),
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                padding: EdgeInsets.zero,
                onPressed: _addEntry,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
          child: TextField(
            controller: _searchController,
            onChanged: (value) => setState(() {
              _filter = value;
              _selectedIndex = -1;
            }),
            style: const TextStyle(color: Color(0xFFCDD6F4), fontSize: 12),
            decoration: InputDecoration(
              hintText: title.isEmpty
                  ? 'Search all entries'
                  : 'Filter matches / search all entries',
              hintStyle: const TextStyle(
                color: Color(0xFF585B70),
                fontSize: 11,
              ),
              prefixIcon: const Icon(
                Icons.search,
                size: 14,
                color: Color(0xFFA6ADC8),
              ),
              filled: true,
              fillColor: const Color(0xFF181825),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 8,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFF45475A)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFF89B4FA)),
              ),
            ),
          ),
        ),
        if (title.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _searchAll
                        ? 'Searching all ${_allEntries.length} entries'
                        : 'Showing ${_entries.length} match'
                            '${_entries.length == 1 ? '' : 'es'} for this window',
                    style: const TextStyle(
                      color: Color(0xFF585B70),
                      fontSize: 9,
                    ),
                  ),
                ),
                InkWell(
                  onTap: () => setState(() {
                    _searchAll = !_searchAll;
                    _selectedIndex = _searchAll && _allEntries.isNotEmpty
                        ? 0
                        : (_entries.isNotEmpty ? 0 : -1);
                  }),
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Text(
                      _searchAll ? 'Show matches' : 'Search all',
                      style: const TextStyle(
                        color: Color(0xFF89B4FA),
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            child: Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFFA6ADC8), fontSize: 12),
            ),
          )
        else if (visible.isEmpty)
          Expanded(
            child: Center(
              child: Text(
                _entries.isEmpty
                    ? 'No matching KeePass entries.\nType in the search box to look through all ${_allEntries.length} entries.'
                    : 'No entries match the filter.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Color(0xFFA6ADC8),
                  fontSize: 11,
                ),
              ),
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              itemCount: visible.length,
              itemBuilder: (context, index) {
                final ref = visible[index];
                final isSelected = index == _selectedIndex;
                return InkWell(
                  onTap: () => setState(() => _selectedIndex = index),
                  onDoubleTap: () {
                    setState(() => _selectedIndex = index);
                    _fillEntry(ref);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: isSelected ? const Color(0xFF313244) : null,
                      border: const Border(
                        bottom: BorderSide(color: Color(0xFF313244)),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              isSelected
                                  ? Icons.radio_button_checked
                                  : Icons.radio_button_unchecked,
                              size: 14,
                              color: isSelected
                                  ? const Color(0xFF89B4FA)
                                  : const Color(0xFFA6ADC8),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    ref.title.isEmpty
                                        ? '(no title)'
                                        : ref.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Color(0xFFCDD6F4),
                                      fontSize: 12,
                                    ),
                                  ),
                                  if (ref.username.isNotEmpty)
                                    Text(
                                      ref.username,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Color(0xFFA6ADC8),
                                        fontSize: 10,
                                      ),
                                    ),
                                  if (ref.url.isNotEmpty)
                                    Text(
                                      ref.url,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Color(0xFF6C7086),
                                        fontSize: 10,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            _EntryActions(
                              onFill: () => _fillEntry(ref),
                              onTypeUsername: ref.username.isNotEmpty
                                  ? () => _typeField(ref, '{USERNAME}')
                                  : null,
                              onTypePassword: ref.password.isNotEmpty
                                  ? () => _typeField(ref, '{PASSWORD}')
                                  : null,
                              onCopyUsername: ref.username.isNotEmpty
                                  ? () => _copyValue(ref.username)
                                  : null,
                              onCopyPassword: ref.password.isNotEmpty
                                  ? () => _copyValue(ref.password)
                                  : null,
                              onEdit: () => _editEntry(ref),
                              onDelete: () => _deleteEntry(ref),
                            ),
                          ],
                        ),
                        // Secondary actions as always-visible buttons so
                        // typing just the username or the password is one
                        // click away.
                        if (ref.username.isNotEmpty || ref.password.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(left: 22, top: 4),
                            child: Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              children: [
                                if (ref.username.isNotEmpty)
                                  _MiniAction(
                                    icon: Icons.person_outline,
                                    label: 'Type user',
                                    onPressed: () =>
                                        _typeField(ref, '{USERNAME}'),
                                  ),
                                if (ref.password.isNotEmpty)
                                  _MiniAction(
                                    icon: Icons.key,
                                    label: 'Type password',
                                    onPressed: () =>
                                        _typeField(ref, '{PASSWORD}'),
                                  ),
                                if (ref.username.isNotEmpty)
                                  _MiniAction(
                                    icon: Icons.content_copy,
                                    label: 'Copy user',
                                    onPressed: () => _copyValue(ref.username),
                                  ),
                                if (ref.password.isNotEmpty)
                                  _MiniAction(
                                    icon: Icons.copy_all,
                                    label: 'Copy password',
                                    onPressed: () => _copyValue(ref.password),
                                  ),
                              ],
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
}

/// Compact secondary action shown under a credential row.
class _MiniAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  const _MiniAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        foregroundColor: const Color(0xFFCDD6F4),
        side: const BorderSide(color: Color(0xFF45475A)),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
      onPressed: onPressed,
      icon: Icon(icon, size: 12),
      label: Text(label, style: const TextStyle(fontSize: 9)),
    );
  }
}

class _EntryActions extends StatelessWidget {
  final VoidCallback onFill;
  final VoidCallback? onTypeUsername;
  final VoidCallback? onTypePassword;
  final VoidCallback? onCopyUsername;
  final VoidCallback? onCopyPassword;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _EntryActions({
    required this.onFill,
    required this.onTypeUsername,
    required this.onTypePassword,
    required this.onCopyUsername,
    required this.onCopyPassword,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    const itemStyle = TextStyle(color: Color(0xFFCDD6F4), fontSize: 12);
    return PopupMenuButton<String>(
      tooltip: 'Entry actions',
      color: const Color(0xFF181825),
      icon: const Icon(Icons.more_vert, size: 16, color: Color(0xFFA6ADC8)),
      onSelected: (value) {
        switch (value) {
          case 'fill':
            onFill();
          case 'user':
            onTypeUsername?.call();
          case 'pass':
            onTypePassword?.call();
          case 'copyUser':
            onCopyUsername?.call();
          case 'copyPass':
            onCopyPassword?.call();
          case 'edit':
            onEdit();
          case 'delete':
            onDelete();
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: 'fill',
          child: Text('Fill default', style: itemStyle),
        ),
        if (onTypeUsername != null)
          const PopupMenuItem(
            value: 'user',
            child: Text('Type username only', style: itemStyle),
          ),
        if (onTypePassword != null)
          const PopupMenuItem(
            value: 'pass',
            child: Text('Type password only', style: itemStyle),
          ),
        if (onCopyUsername != null)
          const PopupMenuItem(
            value: 'copyUser',
            child: Text('Copy username', style: itemStyle),
          ),
        if (onCopyPassword != null)
          const PopupMenuItem(
            value: 'copyPass',
            child: Text('Copy password', style: itemStyle),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'edit',
          child: Text('Edit entry...', style: itemStyle),
        ),
        const PopupMenuItem(
          value: 'delete',
          child: Text(
            'Delete entry...',
            style: TextStyle(color: Color(0xFFE78284), fontSize: 12),
          ),
        ),
      ],
    );
  }
}
