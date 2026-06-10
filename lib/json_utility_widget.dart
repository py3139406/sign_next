import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class JsonUtilityWidget extends StatefulWidget {
  const JsonUtilityWidget({super.key});

  @override
  State<JsonUtilityWidget> createState() => _JsonUtilityWidgetState();
}

class _JsonUtilityWidgetState extends State<JsonUtilityWidget> {
  final _textController = SearchableTextEditingController();
  final _searchController = TextEditingController();
  final _leftSearchController = TextEditingController();
  
  final _editorScrollController = ScrollController();
  final _lineScrollController = ScrollController();
  final _editorFocusNode = FocusNode();
  
  double _splitRatio = 0.55;
  
  String _errorLog = '';
  int? _errorLine;
  int? _errorCol;
  
  bool _isValid = true;
  dynamic _parsedJson;
  bool _treeExpandedByDefault = true;
  int _tabSpaces = 2;

  @override
  void initState() {
    super.initState();
    _textController.addListener(_validateJson);
    _leftSearchController.addListener(() {
      _textController.searchQuery = _leftSearchController.text;
    });
    _editorScrollController.addListener(() {
      if (_lineScrollController.hasClients) {
        _lineScrollController.jumpTo(_editorScrollController.offset);
      }
    });
  }

  @override
  void dispose() {
    _textController.removeListener(_validateJson);
    _textController.dispose();
    _searchController.dispose();
    _leftSearchController.dispose();
    _editorScrollController.dispose();
    _lineScrollController.dispose();
    _editorFocusNode.dispose();
    super.dispose();
  }

  void _scrollToLine(int? lineNum) {
    if (lineNum == null || lineNum <= 0) return;
    
    final text = _textController.text;
    final lines = text.split('\n');
    if (lineNum > lines.length) return;

    int charIndex = 0;
    for (int i = 0; i < lineNum - 1; i++) {
      charIndex += lines[i].length + 1;
    }

    _textController.selection = TextSelection.collapsed(offset: charIndex);
    _editorFocusNode.requestFocus();

    final estimatedLineHeight = 16.8;
    final double targetOffset = (lineNum - 1) * estimatedLineHeight;
    
    if (_editorScrollController.hasClients) {
      final double scrollTarget = (targetOffset - 100.0).clamp(0.0, _editorScrollController.position.maxScrollExtent);
      _editorScrollController.animateTo(
        scrollTarget,
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeInOut,
      );
    }
  }

  void _validateJson() {
    final text = _textController.text.trim();
    if (text.isEmpty) {
      setState(() {
        _isValid = true;
        _parsedJson = null;
        _errorLog = '';
        _errorLine = null;
        _errorCol = null;
      });
      return;
    }

    try {
      final decoded = json.decode(text);
      setState(() {
        _isValid = true;
        _parsedJson = decoded;
        _errorLog = '';
        _errorLine = null;
        _errorCol = null;
      });
    } on FormatException catch (e) {
      // Extract line and column
      final offset = e.offset ?? 0;
      int line = 1;
      int col = 1;
      for (int i = 0; i < offset && i < text.length; i++) {
        if (text[i] == '\n') {
          line++;
          col = 1;
        } else {
          col++;
        }
      }

      setState(() {
        _isValid = false;
        _parsedJson = null;
        _errorLog = e.message;
        _errorLine = line;
        _errorCol = col;
      });
    } catch (e) {
      setState(() {
        _isValid = false;
        _parsedJson = null;
        _errorLog = e.toString();
        _errorLine = null;
        _errorCol = null;
      });
    }
  }

  void _autoFix() {
    String text = _textController.text;
    if (text.trim().isEmpty) return;

    // 1. Strip comments
    text = text.replaceAll(RegExp(r'\/\*[\s\S]*?\*\/'), '');
    text = text.split('\n').map((line) {
      int idx = line.indexOf('//');
      if (idx != -1) {
        if (idx > 0 && line[idx - 1] == ':') {
          return line;
        }
        return line.substring(0, idx);
      }
      return line;
    }).join('\n');

    // 1b. Fix unclosed strings and raw newlines inside strings (runs first to prevent quote-state corruption in subsequent steps)
    List<String> lines = text.split('\n');
    bool changed = true;
    while (changed) {
      changed = false;
      String? currentQuoteChar;
      for (int i = 0; i < lines.length; i++) {
        String line = lines[i];
        bool escaped = false;
        for (int j = 0; j < line.length; j++) {
          if (line[j] == '\\') {
            escaped = !escaped;
          } else if (line[j] == '"') {
            if (!escaped) {
              if (currentQuoteChar == null) {
                currentQuoteChar = '"';
              } else if (currentQuoteChar == '"') {
                currentQuoteChar = null;
              }
            }
            escaped = false;
          } else if (line[j] == '\'') {
            if (!escaped) {
              if (currentQuoteChar == null) {
                currentQuoteChar = '\'';
              } else if (currentQuoteChar == '\'') {
                currentQuoteChar = null;
              }
            }
            escaped = false;
          } else {
            escaped = false;
          }
        }

        if (currentQuoteChar != null) {
          bool isNextKeyValue = false;
          int nextNonEmptyIdx = -1;
          for (int k = i + 1; k < lines.length; k++) {
            String nextLine = lines[k].trim();
            if (nextLine.isNotEmpty) {
              nextNonEmptyIdx = k;
              if (RegExp(r'^((?:"|\x27)?[a-zA-Z0-9_-]+(?:"|\x27)?\s*:)').hasMatch(nextLine)) {
                isNextKeyValue = true;
              }
              break;
            }
          }

          if (isNextKeyValue || nextNonEmptyIdx == -1) {
            String trimmedLine = line.trimRight();
            if (trimmedLine.endsWith(',')) {
              trimmedLine = trimmedLine.substring(0, trimmedLine.length - 1).trimRight();
              lines[i] = trimmedLine + currentQuoteChar + ',';
            } else {
              lines[i] = trimmedLine + currentQuoteChar;
            }
            currentQuoteChar = null;
            changed = true;
            break;
          } else {
            if (i + 1 < lines.length) {
              lines[i] = line + '\\n' + lines[i + 1];
              lines.removeAt(i + 1);
              changed = true;
              break;
            }
          }
        }
      }
    }
    text = lines.join('\n');

    // 2. Replace single quotes with double quotes
    StringBuffer fixedQuotes = StringBuffer();
    bool inDoubleQuote = false;
    bool inSingleQuote = false;
    for (int i = 0; i < text.length; i++) {
      String c = text[i];
      if (c == '"' && !inSingleQuote) {
        if (i > 0 && text[i - 1] == '\\') {
          fixedQuotes.write(c);
        } else {
          inDoubleQuote = !inDoubleQuote;
          fixedQuotes.write(c);
        }
      } else if (c == '\'' && !inDoubleQuote) {
        if (i > 0 && text[i - 1] == '\\') {
          fixedQuotes.write(c);
        } else {
          inSingleQuote = !inSingleQuote;
          fixedQuotes.write('"');
        }
      } else {
        fixedQuotes.write(c);
      }
    }
    text = fixedQuotes.toString();

    // 3. Fix unquoted keys
    text = text.replaceAllMapped(
      RegExp(r'([{,]\s*)([a-zA-Z_][a-zA-Z0-9_-]*)\s*:'),
      (match) => '${match.group(1)}"${match.group(2)}":',
    );

    // 4. Remove trailing commas before closing braces/brackets
    text = text.replaceAllMapped(
      RegExp(r',\s*([\]}])'),
      (match) => match.group(1)!,
    );

    // 5. Add missing commas between key-value pairs or elements
    text = text.replaceAllMapped(
      RegExp(r'("|\d|true|false|null)\s+("([a-zA-Z0-9_-]+)"\s*:)'),
      (match) => '${match.group(1)}, ${match.group(2)}',
    );

    // 6. Balance brackets/braces
    int openBraces = 0;
    int closeBraces = 0;
    int openBrackets = 0;
    int closeBrackets = 0;
    bool inString = false;

    for (int i = 0; i < text.length; i++) {
      char c = text[i];
      if (c == '"' && (i == 0 || text[i - 1] != '\\')) {
        inString = !inString;
      }
      if (!inString) {
        if (c == '{') openBraces++;
        if (c == '}') closeBraces++;
        if (c == '[') openBrackets++;
        if (c == ']') closeBrackets++;
      }
    }

    if (openBrackets > closeBrackets) {
      text = text + (']' * (openBrackets - closeBrackets));
    }
    if (openBraces > closeBraces) {
      text = text + ('}' * (openBraces - closeBraces));
    }

    _textController.text = text;
    _validateJson();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_isValid ? 'Successfully Auto-Fixed JSON!' : 'Auto-fixed some parts, but errors remain.'),
        backgroundColor: _isValid ? const Color(0xFF10B981) : const Color(0xFFF59E0B),
      ),
    );
  }

  void _formatJson() {
    if (!_isValid || _parsedJson == null) return;
    final indent = ' ' * _tabSpaces;
    final encoder = JsonEncoder.withIndent(indent);
    _textController.text = encoder.convert(_parsedJson);
  }

  void _minifyJson() {
    if (!_isValid || _parsedJson == null) return;
    _textController.text = json.encode(_parsedJson);
  }

  void _copyToClipboard() {
    Clipboard.setData(ClipboardData(text: _textController.text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('JSON copied to clipboard!'),
        backgroundColor: Color(0xFF8B5CF6),
      ),
    );
  }

  Widget _buildEditorSearchField() {
    return Container(
      height: 32,
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E22),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF27272A)),
      ),
      child: TextField(
        controller: _leftSearchController,
        style: const TextStyle(fontFamily: 'Inter', fontSize: 11, color: Colors.white70),
        decoration: const InputDecoration(
          prefixIcon: Icon(Icons.search_rounded, size: 14, color: Color(0xFF71717A)),
          hintText: 'Search text in editor...',
          hintStyle: TextStyle(fontFamily: 'Inter', fontSize: 11, color: Color(0xFF52525B)),
          contentPadding: EdgeInsets.symmetric(vertical: 8),
          border: InputBorder.none,
          suffixIcon: Icon(Icons.palette_outlined, size: 12, color: Color(0xFF8B5CF6)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(4.0),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final totalWidth = constraints.maxWidth;
          const dividerWidth = 16.0;
          final availableWidth = totalWidth - dividerWidth;
          
          double leftWidth = (availableWidth * _splitRatio).clamp(200.0, availableWidth - 200.0);
          double rightWidth = availableWidth - leftWidth;

          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Left Side: Editor
              SizedBox(
                width: leftWidth,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildEditorHeader(),
                    const SizedBox(height: 8),
                    _buildEditorSearchField(),
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFF0F0F11),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: _isValid ? const Color(0xFF27272A) : const Color(0xFFEF4444).withOpacity(0.5),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Container(
                              width: 45,
                              padding: const EdgeInsets.only(top: 16, bottom: 16),
                              decoration: const BoxDecoration(
                                color: Color(0xFF09090B),
                                borderRadius: BorderRadius.only(
                                  topLeft: Radius.circular(12),
                                  bottomLeft: Radius.circular(12),
                                ),
                              ),
                              child: SingleChildScrollView(
                                controller: _lineScrollController,
                                physics: const NeverScrollableScrollPhysics(),
                                child: ValueListenableBuilder<TextEditingValue>(
                                  valueListenable: _textController,
                                  builder: (context, value, child) {
                                    final lineCount = '\n'.allMatches(value.text).length + 1;
                                    return Column(
                                      crossAxisAlignment: CrossAxisAlignment.end,
                                      children: List.generate(lineCount, (index) {
                                        final currentLine = index + 1;
                                        final isErrorLine = _errorLine == currentLine;
                                        return Container(
                                          height: 16.8,
                                          padding: const EdgeInsets.only(right: 8),
                                          alignment: Alignment.centerRight,
                                          child: Text(
                                            '$currentLine',
                                            style: TextStyle(
                                              fontFamily: 'Courier',
                                              fontSize: 12,
                                              height: 1.4,
                                              color: isErrorLine ? const Color(0xFFEF4444) : const Color(0xFF52525B),
                                              fontWeight: isErrorLine ? FontWeight.bold : FontWeight.normal,
                                            ),
                                          ),
                                        );
                                      }),
                                    );
                                  },
                                ),
                              ),
                            ),
                            Container(
                              width: 1,
                              color: const Color(0xFF27272A),
                            ),
                            Expanded(
                              child: TextField(
                                controller: _textController,
                                scrollController: _editorScrollController,
                                focusNode: _editorFocusNode,
                                maxLines: null,
                                keyboardType: TextInputType.multiline,
                                style: const TextStyle(
                                  fontFamily: 'Courier',
                                  fontSize: 12,
                                  color: Color(0xD8FFFFFF),
                                  height: 1.4,
                                ),
                                decoration: const InputDecoration(
                                  hintText: 'Paste raw JSON here to validate, auto-fix, and format...',
                                  hintStyle: TextStyle(fontFamily: 'Courier', fontSize: 12, color: Color(0xFF52525B)),
                                  contentPadding: EdgeInsets.all(16),
                                  border: InputBorder.none,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (!_isValid && _errorLog.isNotEmpty) _buildErrorBanner(),
                  ],
                ),
              ),
              
              // Draggable Divider
              GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragUpdate: (details) {
                  setState(() {
                    double newLeftWidth = leftWidth + details.delta.dx;
                    _splitRatio = (newLeftWidth / availableWidth).clamp(0.1, 0.9);
                  });
                },
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeLeftRight,
                  child: Container(
                    width: dividerWidth,
                    color: Colors.transparent,
                    child: Center(
                      child: Container(
                        width: 2,
                        height: 60,
                        decoration: BoxDecoration(
                          color: const Color(0xFF3F3F46),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              // Right Side: Viewer
              SizedBox(
                width: rightWidth,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildViewerHeader(),
                    const SizedBox(height: 8),
                    Expanded(
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0F0F11),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFF27272A)),
                        ),
                        child: _parsedJson == null
                            ? const Center(
                                child: Text(
                                  'Paste valid JSON to explore interactively',
                                  style: TextStyle(fontFamily: 'Inter', fontSize: 12, color: Color(0xFF52525B)),
                                ),
                              )
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _buildSearchField(),
                                  const SizedBox(height: 10),
                                  Expanded(
                                    child: SingleChildScrollView(
                                      child: ValueListenableBuilder<TextEditingValue>(
                                        valueListenable: _searchController,
                                        builder: (context, value, child) {
                                          return JsonNodeWidget(
                                            key: ValueKey('${_parsedJson.hashCode}_$_treeExpandedByDefault'),
                                            name: 'root',
                                            value: _parsedJson,
                                            isLast: true,
                                            searchQuery: value.text.toLowerCase(),
                                            expanded: _treeExpandedByDefault,
                                          );
                                        },
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildEditorHeader() {
    return Row(
      children: [
        const Icon(Icons.code_rounded, color: Color(0xFF8B5CF6), size: 18),
        const SizedBox(width: 8),
        const Text(
          'JSON Editor',
          style: TextStyle(fontFamily: 'Inter', fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white),
        ),
        const Spacer(),
        if (!_isValid)
          TextButton.icon(
            style: TextButton.styleFrom(
              backgroundColor: const Color(0x20EF4444),
              foregroundColor: const Color(0xFFFCA5A5),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            ),
            icon: const Icon(Icons.build_rounded, size: 13),
            label: const Text('Auto-Fix JSON', style: TextStyle(fontFamily: 'Inter', fontSize: 11, fontWeight: FontWeight.bold)),
            onPressed: _autoFix,
          ),
        if (_isValid && _parsedJson != null) ...[
          IconButton(
            icon: const Icon(Icons.format_align_left_rounded, size: 16, color: Color(0xFFA1A1AA)),
            tooltip: 'Format/Beautify JSON',
            onPressed: _formatJson,
          ),
          IconButton(
            icon: const Icon(Icons.compress_rounded, size: 16, color: Color(0xFFA1A1AA)),
            tooltip: 'Minify JSON',
            onPressed: _minifyJson,
          ),
          IconButton(
            icon: const Icon(Icons.copy_rounded, size: 15, color: Color(0xFFA1A1AA)),
            tooltip: 'Copy JSON',
            onPressed: _copyToClipboard,
          ),
        ],
        IconButton(
          icon: const Icon(Icons.clear_all_rounded, size: 18, color: Color(0xFFEF4444)),
          tooltip: 'Clear Editor',
          onPressed: () => _textController.clear(),
        ),
      ],
    );
  }

  Widget _buildViewerHeader() {
    return Row(
      children: [
        const Icon(Icons.reorder_rounded, color: Color(0xFF10B981), size: 18),
        const SizedBox(width: 8),
        const Text(
          'Interactive Tree Viewer',
          style: TextStyle(fontFamily: 'Inter', fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white),
        ),
        const Spacer(),
        if (_parsedJson != null) ...[
          TextButton(
            style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(60, 24)),
            child: Text(
              _treeExpandedByDefault ? 'Collapse All' : 'Expand All',
              style: const TextStyle(fontFamily: 'Inter', fontSize: 10, color: Color(0xFF8B5CF6)),
            ),
            onPressed: () {
              setState(() {
                _treeExpandedByDefault = !_treeExpandedByDefault;
              });
            },
          ),
        ],
      ],
    );
  }

  Widget _buildSearchField() {
    return Container(
      height: 32,
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E22),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF27272A)),
      ),
      child: TextField(
        controller: _searchController,
        style: const TextStyle(fontFamily: 'Inter', fontSize: 11, color: Colors.white70),
        decoration: const InputDecoration(
          prefixIcon: Icon(Icons.search_rounded, size: 14, color: Color(0xFF71717A)),
          hintText: 'Filter keys or values...',
          hintStyle: TextStyle(fontFamily: 'Inter', fontSize: 11, color: Color(0xFF52525B)),
          contentPadding: EdgeInsets.symmetric(vertical: 8),
          border: InputBorder.none,
        ),
      ),
    );
  }

  Widget _buildErrorBanner() {
    return InkWell(
      onTap: () => _scrollToLine(_errorLine),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF2A1515),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFEF4444)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.error_outline_rounded, color: Color(0xFFEF4444), size: 16),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Invalid JSON: $_errorLog',
                          style: const TextStyle(fontFamily: 'Inter', fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFFFCA5A5)),
                        ),
                      ),
                      const Icon(Icons.ads_click_rounded, size: 12, color: Color(0xFFF87171)),
                      const SizedBox(width: 4),
                      const Text(
                        'Click to go',
                        style: TextStyle(fontFamily: 'Inter', fontSize: 9, color: Color(0xFFF87171)),
                      ),
                    ],
                  ),
                  if (_errorLine != null && _errorCol != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Error located at Line $_errorLine, Column $_errorCol',
                      style: const TextStyle(fontFamily: 'Courier', fontSize: 11, color: Color(0xFFF87171)),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class JsonNodeWidget extends StatefulWidget {
  final String name;
  final dynamic value;
  final bool isLast;
  final String searchQuery;
  final bool expanded;

  const JsonNodeWidget({
    super.key,
    required this.name,
    required this.value,
    required this.isLast,
    required this.searchQuery,
    required this.expanded,
  });

  @override
  State<JsonNodeWidget> createState() => _JsonNodeWidgetState();
}

class _JsonNodeWidgetState extends State<JsonNodeWidget> {
  late bool _isCollapsed;

  @override
  void initState() {
    super.initState();
    _isCollapsed = !widget.expanded;
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.name;
    final val = widget.value;

    final nameMatches = widget.searchQuery.isNotEmpty && name.toLowerCase().contains(widget.searchQuery);

    if (val is Map) {
      final childrenKeys = val.keys.toList();
      final size = childrenKeys.length;
      
      // Filter logic
      bool matchesSearch = nameMatches;
      if (widget.searchQuery.isNotEmpty && !nameMatches) {
        matchesSearch = _anyChildMatches(val, widget.searchQuery);
      }

      if (widget.searchQuery.isNotEmpty && !matchesSearch) {
        return const SizedBox.shrink();
      }

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                icon: Icon(_isCollapsed ? Icons.chevron_right_rounded : Icons.keyboard_arrow_down_rounded, size: 16),
                color: const Color(0xFF71717A),
                constraints: const BoxConstraints(),
                padding: EdgeInsets.zero,
                onPressed: () => setState(() => _isCollapsed = !_isCollapsed),
              ),
              const SizedBox(width: 4),
              _buildKey(name, nameMatches),
              const Text(': ', style: TextStyle(fontFamily: 'Courier', fontSize: 12, color: Colors.white54)),
              Text(
                '{$size items}',
                style: const TextStyle(fontFamily: 'Inter', fontSize: 10, color: Color(0xFF71717A), fontStyle: FontStyle.italic),
              ),
            ],
          ),
          if (!_isCollapsed)
            Padding(
              padding: const EdgeInsets.only(left: 16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: List.generate(size, (idx) {
                  final k = childrenKeys[idx].toString();
                  return JsonNodeWidget(
                    name: k,
                    value: val[k],
                    isLast: idx == size - 1,
                    searchQuery: widget.searchQuery,
                    expanded: widget.expanded,
                  );
                }),
              ),
            ),
        ],
      );
    } else if (val is List) {
      final size = val.length;
      
      // Filter logic
      bool matchesSearch = nameMatches;
      if (widget.searchQuery.isNotEmpty && !nameMatches) {
        matchesSearch = _anyListChildMatches(val, widget.searchQuery);
      }

      if (widget.searchQuery.isNotEmpty && !matchesSearch) {
        return const SizedBox.shrink();
      }

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                icon: Icon(_isCollapsed ? Icons.chevron_right_rounded : Icons.keyboard_arrow_down_rounded, size: 16),
                color: const Color(0xFF71717A),
                constraints: const BoxConstraints(),
                padding: EdgeInsets.zero,
                onPressed: () => setState(() => _isCollapsed = !_isCollapsed),
              ),
              const SizedBox(width: 4),
              _buildKey(name, nameMatches),
              const Text(': ', style: TextStyle(fontFamily: 'Courier', fontSize: 12, color: Colors.white54)),
              Text(
                '[$size items]',
                style: const TextStyle(fontFamily: 'Inter', fontSize: 10, color: Color(0xFF71717A), fontStyle: FontStyle.italic),
              ),
            ],
          ),
          if (!_isCollapsed)
            Padding(
              padding: const EdgeInsets.only(left: 16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: List.generate(size, (idx) {
                  return JsonNodeWidget(
                    name: '[$idx]',
                    value: val[idx],
                    isLast: idx == size - 1,
                    searchQuery: widget.searchQuery,
                    expanded: widget.expanded,
                  );
                }),
              ),
            ),
        ],
      );
    } else {
      // Primitive
      final valStr = val?.toString() ?? 'null';
      final valMatches = widget.searchQuery.isNotEmpty && valStr.toLowerCase().contains(widget.searchQuery);

      if (widget.searchQuery.isNotEmpty && !nameMatches && !valMatches) {
        return const SizedBox.shrink();
      }

      return Padding(
        padding: const EdgeInsets.only(left: 20.0, top: 2, bottom: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildKey(name, nameMatches),
            const Text(': ', style: TextStyle(fontFamily: 'Courier', fontSize: 12, color: Colors.white54)),
            Expanded(
              child: _buildPrimitiveValue(val, valMatches),
            ),
          ],
        ),
      );
    }
  }

  Widget _buildKey(String key, bool isMatch) {
    return InkWell(
      onTap: () {
        Clipboard.setData(ClipboardData(text: key));
      },
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        color: isMatch ? const Color(0x35F59E0B) : Colors.transparent,
        child: Text(
          key,
          style: const TextStyle(
            fontFamily: 'Courier',
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: Color(0xFFA7F3D0),
          ),
        ),
      ),
    );
  }

  Widget _buildPrimitiveValue(dynamic value, bool isMatch) {
    Color valColor;
    String badge = '';
    
    if (value is String) {
      valColor = const Color(0xFFF59E0B);
      badge = 'str';
    } else if (value is num) {
      valColor = const Color(0xFF38BDF8);
      badge = 'num';
    } else if (value is bool) {
      valColor = const Color(0xFF10B981);
      badge = 'bool';
    } else {
      valColor = const Color(0xFF71717A);
      badge = 'null';
    }

    final displayVal = value is String ? '"$value"' : value.toString();

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Type Badge
        Container(
          margin: const EdgeInsets.only(right: 6, top: 3),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          decoration: BoxDecoration(
            color: valColor.withOpacity(0.12),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: valColor.withOpacity(0.3), width: 0.5),
          ),
          child: Text(
            badge,
            style: TextStyle(fontFamily: 'Inter', fontSize: 8, fontWeight: FontWeight.bold, color: valColor),
          ),
        ),
        Expanded(
          child: Container(
            color: isMatch ? const Color(0x35F59E0B) : Colors.transparent,
            child: SelectableText(
              displayVal,
              style: TextStyle(
                fontFamily: 'Courier',
                fontSize: 12,
                color: valColor,
              ),
            ),
          ),
        ),
      ],
    );
  }

  bool _anyChildMatches(Map map, String query) {
    for (final entry in map.entries) {
      if (entry.key.toString().toLowerCase().contains(query)) return true;
      final val = entry.value;
      if (val is Map && _anyChildMatches(val, query)) return true;
      if (val is List && _anyListChildMatches(val, query)) return true;
      if (val != null && val.toString().toLowerCase().contains(query)) return true;
    }
    return false;
  }

  bool _anyListChildMatches(List list, String query) {
    for (final val in list) {
      if (val is Map && _anyChildMatches(val, query)) return true;
      if (val is List && _anyListChildMatches(val, query)) return true;
      if (val != null && val.toString().toLowerCase().contains(query)) return true;
    }
    return false;
  }
}

typedef char = String;

class SearchableTextEditingController extends TextEditingController {
  String _searchQuery = '';

  String get searchQuery => _searchQuery;

  set searchQuery(String val) {
    if (_searchQuery != val) {
      _searchQuery = val;
      notifyListeners();
    }
  }

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    if (_searchQuery.isEmpty) {
      return super.buildTextSpan(context: context, style: style, withComposing: withComposing);
    }

    final String text = this.text;
    final List<InlineSpan> children = [];
    int start = 0;

    final RegExp regExp = RegExp(RegExp.escape(_searchQuery), caseSensitive: false);
    final Iterable<RegExpMatch> matches = regExp.allMatches(text);

    for (final RegExpMatch match in matches) {
      if (match.start > start) {
        children.add(TextSpan(text: text.substring(start, match.start)));
      }
      children.add(TextSpan(
        text: text.substring(match.start, match.end),
        style: const TextStyle(
          backgroundColor: Color(0x65F59E0B),
          color: Colors.white,
          fontWeight: FontWeight.bold,
        ),
      ));
      start = match.end;
    }

    if (start < text.length) {
      children.add(TextSpan(text: text.substring(start)));
    }

    return TextSpan(style: style, children: children);
  }
}
