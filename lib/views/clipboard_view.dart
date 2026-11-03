import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'package:type_the_clipboard/core/keyboard_navigable.dart';
import 'package:type_the_clipboard/input_simulator.dart';

enum _OutputAction {
  typeStandard,
  typeChat,
  instantPaste,
}

/// Restored core functionality: a live clipboard history list with one-click
/// (and keyboard) actions to type normally, type with Shift+Enter (chat), or
/// paste via Ctrl+V.
class ClipboardView extends StatefulWidget {
  final List<String> history;
  final VoidCallback onClear;
  final int? targetHwnd;

  const ClipboardView({
    super.key,
    required this.history,
    required this.onClear,
    this.targetHwnd,
  });

  @override
  State<ClipboardView> createState() => ClipboardViewState();
}

class ClipboardViewState extends State<ClipboardView>
    implements KeyboardNavigableView {
  final TextEditingController _searchController = TextEditingController();
  int _selectedIndex = -1;
  String _filter = '';

  List<String> get _filteredHistory {
    final query = _filter.toLowerCase();
    if (query.isEmpty) return widget.history;
    return widget.history
        .where((item) => item.toLowerCase().contains(query))
        .toList();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  void selectPrevious() {
    final items = _filteredHistory;
    if (items.isEmpty) return;
    setState(() {
      if (_selectedIndex < 0) {
        _selectedIndex = items.length - 1;
      } else {
        _selectedIndex = (_selectedIndex - 1).clamp(0, items.length - 1);
      }
    });
  }

  @override
  void selectNext() {
    final items = _filteredHistory;
    if (items.isEmpty) return;
    setState(() {
      if (_selectedIndex < 0) {
        _selectedIndex = 0;
      } else {
        _selectedIndex = (_selectedIndex + 1).clamp(0, items.length - 1);
      }
    });
  }

  @override
  Future<void> confirm() async {
    final items = _filteredHistory;
    if (_selectedIndex < 0 || _selectedIndex >= items.length) {
      if (items.isNotEmpty) _selectedIndex = 0;
    }
    if (_selectedIndex >= 0 && _selectedIndex < items.length) {
      await _activate(_selectedIndex, _OutputAction.instantPaste);
    }
  }

  Future<void> _activate(int index, _OutputAction action) async {
    final items = _filteredHistory;
    if (index < 0 || index >= items.length) return;
    final text = items[index];
    final hwnd = widget.targetHwnd ?? InputSimulator.getActiveWindow();

    await windowManager.hide();
    if (hwnd != 0) {
      InputSimulator.focusWindow(hwnd);
      await Future.delayed(const Duration(milliseconds: 250));
    }

    if (action == _OutputAction.instantPaste) {
      await Clipboard.setData(ClipboardData(text: text));
      await InputSimulator.pasteViaShortcut();
    } else {
      await InputSimulator.typeText(
        text,
        delayMs: 10,
        chatMode: action == _OutputAction.typeChat,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.history.isEmpty) {
      return const Center(
        child: Text(
          'Clipboard history is empty',
          style: TextStyle(
            color: Color(0xFFA6ADC8),
            fontSize: 11,
          ),
        ),
      );
    }

    final items = _filteredHistory;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${items.length}/${widget.history.length} item${widget.history.length == 1 ? '' : 's'}',
                style: const TextStyle(
                  color: Color(0xFFA6ADC8),
                  fontSize: 10,
                ),
              ),
              InkWell(
                onTap: widget.onClear,
                child: const Text(
                  'Clear',
                  style: TextStyle(
                    color: Color(0xFFE78284),
                    fontSize: 10,
                  ),
                ),
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
            style: const TextStyle(
              color: Color(0xFFCDD6F4),
              fontSize: 12,
            ),
            decoration: InputDecoration(
              hintText: 'Search clipboard history',
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
        Expanded(
          child: ListView.builder(
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              final preview =
                  item.replaceAll('\r', '').replaceAll('\n', ' ↵ ');
              final isSelected = index == _selectedIndex;

              return InkWell(
                onTap: () => setState(() => _selectedIndex = index),
                onDoubleTap: () => _activate(index, _OutputAction.instantPaste),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: isSelected ? const Color(0xFF313244) : null,
                    border: Border(
                      bottom: BorderSide(
                        color: const Color(0xFF313244),
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      Text(
                        '[${index + 1}] ',
                        style: const TextStyle(
                          fontFamily: 'Consolas',
                          color: Color(0xFF89B4FA),
                          fontSize: 11,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          preview,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'Consolas',
                            color: Color(0xFFCDD6F4),
                            fontSize: 11,
                          ),
                        ),
                      ),
                      _ActionIcon(
                        tooltip: 'Paste (Ctrl+V)',
                        icon: Icons.content_paste,
                        onPressed: () => _activate(
                          index,
                          _OutputAction.instantPaste,
                        ),
                      ),
                      _ActionIcon(
                        tooltip: 'Type',
                        icon: Icons.keyboard,
                        onPressed: () => _activate(
                          index,
                          _OutputAction.typeStandard,
                        ),
                      ),
                      _ActionIcon(
                        tooltip: 'Type as chat',
                        icon: Icons.chat_bubble_outline,
                        onPressed: () => _activate(
                          index,
                          _OutputAction.typeChat,
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

class _ActionIcon extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  const _ActionIcon({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      icon: Icon(icon, size: 14, color: const Color(0xFFA6ADC8)),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      onPressed: onPressed,
    );
  }
}
