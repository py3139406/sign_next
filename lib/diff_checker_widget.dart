import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum DiffType { equal, deletion, addition, modification }

class DiffRow {
  final String? leftText;
  final int? leftLineNum;
  final String? rightText;
  final int? rightLineNum;
  final DiffType type;

  DiffRow({
    this.leftText,
    this.leftLineNum,
    this.rightText,
    this.rightLineNum,
    required this.type,
  });
}

class DiffCheckerWidget extends StatefulWidget {
  const DiffCheckerWidget({super.key});

  @override
  State<DiffCheckerWidget> createState() => _DiffCheckerWidgetState();
}

class _DiffCheckerWidgetState extends State<DiffCheckerWidget> {
  final _leftController = TextEditingController();
  final _rightController = TextEditingController();
  
  final _leftScrollController = ScrollController();
  final _leftLineScrollController = ScrollController();
  final _rightScrollController = ScrollController();
  final _rightLineScrollController = ScrollController();
  final _resultsScrollController = ScrollController();
  
  bool _isSplitView = true;
  bool _hasCompared = false;
  bool _isComparing = false;
  bool _showChangesOnly = false;
  
  double _splitRatio = 0.5;

  List<DiffRow> _diffRows = [];
  List<int> _splitChangeBlockIndices = [];
  List<int> _unifiedChangeBlockIndices = [];
  int _currentChangeIndex = -1;

  List<int> get _currentChangeBlockIndices => _isSplitView ? _splitChangeBlockIndices : _unifiedChangeBlockIndices;
  
  int _addedCount = 0;
  int _deletedCount = 0;
  int _modifiedCount = 0;
  double _percentDiff = 0.0;

  @override
  void initState() {
    super.initState();
    _leftScrollController.addListener(() {
      if (_leftLineScrollController.hasClients) {
        _leftLineScrollController.jumpTo(_leftScrollController.offset);
      }
    });
    _rightScrollController.addListener(() {
      if (_rightLineScrollController.hasClients) {
        _rightLineScrollController.jumpTo(_rightScrollController.offset);
      }
    });
  }

  @override
  void dispose() {
    _leftController.dispose();
    _rightController.dispose();
    _leftScrollController.dispose();
    _leftLineScrollController.dispose();
    _rightScrollController.dispose();
    _rightLineScrollController.dispose();
    _resultsScrollController.dispose();
    super.dispose();
  }

  void _clearAll() {
    setState(() {
      _leftController.clear();
      _rightController.clear();
      _diffRows.clear();
      _splitChangeBlockIndices.clear();
      _unifiedChangeBlockIndices.clear();
      _currentChangeIndex = -1;
      _hasCompared = false;
      _isComparing = false;
      _showChangesOnly = false;
      _addedCount = 0;
      _deletedCount = 0;
      _modifiedCount = 0;
      _percentDiff = 0.0;
    });
  }

  Future<void> _compareCode() async {
    final originalText = _leftController.text;
    final modifiedText = _rightController.text;

    if (originalText.isEmpty && modifiedText.isEmpty) return;

    setState(() {
      _isComparing = true;
    });

    final result = await _computeDiffAsync(originalText, modifiedText);

    // Group split view change blocks
    List<int> splitBlocks = [];
    bool inSplitBlock = false;
    for (int idx = 0; idx < result.rows.length; idx++) {
      if (result.rows[idx].type != DiffType.equal) {
        if (!inSplitBlock) {
          splitBlocks.add(idx);
          inSplitBlock = true;
        }
      } else {
        inSplitBlock = false;
      }
    }

    // Group unified view change blocks
    List<int> unifiedBlocks = [];
    bool inUnifiedBlock = false;
    int unifiedRowIdx = 0;
    for (final r in result.rows) {
      if (r.type == DiffType.equal) {
        inUnifiedBlock = false;
        unifiedRowIdx++;
      } else if (r.type == DiffType.modification) {
        if (!inUnifiedBlock) {
          unifiedBlocks.add(unifiedRowIdx);
          inUnifiedBlock = true;
        }
        unifiedRowIdx += 2;
      } else {
        if (!inUnifiedBlock) {
          unifiedBlocks.add(unifiedRowIdx);
          inUnifiedBlock = true;
        }
        unifiedRowIdx++;
      }
    }

    setState(() {
      _diffRows = result.rows;
      _splitChangeBlockIndices = splitBlocks;
      _unifiedChangeBlockIndices = unifiedBlocks;
      _currentChangeIndex = splitBlocks.isNotEmpty ? 0 : -1;
      _addedCount = result.added;
      _deletedCount = result.deleted;
      _modifiedCount = result.modified;
      _percentDiff = result.percent;
      _hasCompared = true;
      _isComparing = false;
    });

    if (splitBlocks.isNotEmpty) {
      Future.delayed(const Duration(milliseconds: 150), () {
        _jumpToChange(0);
      });
    }
  }

  int _getFilteredRowIndex(int fullRowIndex) {
    if (!_showChangesOnly) return fullRowIndex;
    if (_isSplitView) {
      int count = 0;
      for (int idx = 0; idx < fullRowIndex; idx++) {
        if (_diffRows[idx].type != DiffType.equal) {
          count++;
        }
      }
      return count;
    } else {
      int count = 0;
      for (int idx = 0; idx < _diffRows.length; idx++) {
        final r = _diffRows[idx];
        if (idx == fullRowIndex) break;
        if (r.type == DiffType.equal) continue;
        if (r.type == DiffType.modification) {
          count += 2;
        } else {
          count++;
        }
      }
      return count;
    }
  }

  void _jumpToFirstChangeOfType(DiffType type) {
    int targetRawIdx = -1;
    for (int idx = 0; idx < _diffRows.length; idx++) {
      final r = _diffRows[idx];
      if (r.type == type || (r.type == DiffType.modification && (type == DiffType.addition || type == DiffType.deletion))) {
        targetRawIdx = idx;
        break;
      }
    }
    if (targetRawIdx == -1) return;

    final blocks = _currentChangeBlockIndices;
    if (blocks.isEmpty) return;

    int targetBlockIdx = 0;
    if (_isSplitView) {
      for (int i = 0; i < blocks.length; i++) {
        if (blocks[i] <= targetRawIdx) {
          targetBlockIdx = i;
        } else {
          break;
        }
      }
    } else {
      int unifiedIdx = 0;
      for (int idx = 0; idx < targetRawIdx; idx++) {
        final r = _diffRows[idx];
        if (r.type == DiffType.equal) {
          unifiedIdx++;
        } else if (r.type == DiffType.modification) {
          unifiedIdx += 2;
        } else {
          unifiedIdx++;
        }
      }
      for (int i = 0; i < blocks.length; i++) {
        if (blocks[i] <= unifiedIdx) {
          targetBlockIdx = i;
        } else {
          break;
        }
      }
    }
    _jumpToChange(targetBlockIdx);
  }

  void _jumpToChange(int changeBlockIndex) {
    final blocks = _currentChangeBlockIndices;
    if (changeBlockIndex < 0 || changeBlockIndex >= blocks.length) return;
    
    setState(() {
      _currentChangeIndex = changeBlockIndex;
    });

    final targetRowIndex = blocks[changeBlockIndex];
    final displayRowIndex = _getFilteredRowIndex(targetRowIndex);
    const double rowHeight = 22.0;
    final double targetOffset = displayRowIndex * rowHeight;

    if (_resultsScrollController.hasClients) {
      final double scrollTarget = (targetOffset - 120.0).clamp(0.0, _resultsScrollController.position.maxScrollExtent);
      _resultsScrollController.animateTo(
        scrollTarget,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
      );
    }
  }

  Future<_DiffResult> _computeDiffAsync(String original, String modified) async {
    // Standard Line Splitter
    final originalLines = original.split(RegExp(r'\r?\n'));
    final modifiedLines = modified.split(RegExp(r'\r?\n'));

    // Truncate/warning limit for safety
    final maxLines = 1500;
    final origTruncated = originalLines.length > maxLines ? originalLines.sublist(0, maxLines) : originalLines;
    final modTruncated = modifiedLines.length > maxLines ? modifiedLines.sublist(0, maxLines) : modifiedLines;

    int n = origTruncated.length;
    int m = modTruncated.length;

    // LCS Table (Using simple list of lists)
    List<List<int>> dp = List.generate(n + 1, (_) => List.filled(m + 1, 0));

    for (int i = 1; i <= n; i++) {
      for (int j = 1; j <= m; j++) {
        if (origTruncated[i - 1] == modTruncated[j - 1]) {
          dp[i][j] = dp[i - 1][j - 1] + 1;
        } else {
          dp[i][j] = dp[i - 1][j] > dp[i][j - 1] ? dp[i - 1][j] : dp[i][j - 1];
        }
      }
    }

    // Backtrack to build raw diff rows
    List<DiffRow> rawRows = [];
    int i = n;
    int j = m;

    while (i > 0 || j > 0) {
      if (i > 0 && j > 0 && origTruncated[i - 1] == modTruncated[j - 1]) {
        rawRows.add(DiffRow(
          leftText: origTruncated[i - 1],
          leftLineNum: i,
          rightText: modTruncated[j - 1],
          rightLineNum: j,
          type: DiffType.equal,
        ));
        i--;
        j--;
      } else if (j > 0 && (i == 0 || dp[i][j - 1] >= dp[i - 1][j])) {
        rawRows.add(DiffRow(
          leftText: null,
          leftLineNum: null,
          rightText: modTruncated[j - 1],
          rightLineNum: j,
          type: DiffType.addition,
        ));
        j--;
      } else {
        rawRows.add(DiffRow(
          leftText: origTruncated[i - 1],
          leftLineNum: i,
          rightText: null,
          rightLineNum: null,
          type: DiffType.deletion,
        ));
        i--;
      }
    }

    rawRows = rawRows.reversed.toList();

    // Post-process to group deletions and additions as modifications
    List<DiffRow> processedRows = [];
    List<DiffRow> pendingDeletions = [];
    List<DiffRow> pendingAdditions = [];

    void flushPending() {
      int delCount = pendingDeletions.length;
      int addCount = pendingAdditions.length;
      int minCount = delCount < addCount ? delCount : addCount;

      for (int k = 0; k < minCount; k++) {
        processedRows.add(DiffRow(
          leftText: pendingDeletions[k].leftText,
          leftLineNum: pendingDeletions[k].leftLineNum,
          rightText: pendingAdditions[k].rightText,
          rightLineNum: pendingAdditions[k].rightLineNum,
          type: DiffType.modification,
        ));
      }

      if (delCount > minCount) {
        for (int k = minCount; k < delCount; k++) {
          processedRows.add(pendingDeletions[k]);
        }
      }

      if (addCount > minCount) {
        for (int k = minCount; k < addCount; k++) {
          processedRows.add(pendingAdditions[k]);
        }
      }

      pendingDeletions.clear();
      pendingAdditions.clear();
    }

    for (final row in rawRows) {
      if (row.type == DiffType.equal) {
        flushPending();
        processedRows.add(row);
      } else if (row.type == DiffType.deletion) {
        pendingDeletions.add(row);
      } else if (row.type == DiffType.addition) {
        pendingAdditions.add(row);
      }
    }
    flushPending();

    // Calculate stats
    int addedLines = 0;
    int deletedLines = 0;
    int modifiedLinesCount = 0;

    for (final r in processedRows) {
      if (r.type == DiffType.addition) addedLines++;
      if (r.type == DiffType.deletion) deletedLines++;
      if (r.type == DiffType.modification) modifiedLinesCount++;
    }

    // Percentage of changes relative to original text line count
    double percent = 0.0;
    if (originalLines.isNotEmpty) {
      percent = ((addedLines + deletedLines + (modifiedLinesCount * 2)) / (originalLines.length + modifiedLines.length) * 100).clamp(0.0, 100.0);
    } else if (modifiedLines.isNotEmpty) {
      percent = 100.0;
    }

    return _DiffResult(
      rows: processedRows,
      added: addedLines,
      deleted: deletedLines,
      modified: modifiedLinesCount,
      percent: percent,
    );
  }

  void _copyResult(BuildContext context, String content, String label) {
    Clipboard.setData(ClipboardData(text: content));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied $label to clipboard!'),
        backgroundColor: const Color(0xFF8B5CF6),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E22),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF27272A)),
      ),
      child: Column(
        children: [
          // Header Controls
          _buildControlsHeader(),
          const Divider(height: 1, color: Color(0xFF27272A)),
          Expanded(
            child: _isComparing
                ? const Center(child: CircularProgressIndicator(color: Color(0xFF8B5CF6)))
                : _hasCompared
                    ? _buildDiffViewer()
                    : _buildInputsPanel(),
          ),
        ],
      ),
    );
  }

  Widget _buildControlsHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        children: [
          const Icon(Icons.compare_rounded, color: Color(0xFF8B5CF6), size: 20),
          const SizedBox(width: 10),
          const Text(
            'Diff Checker',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const Spacer(),
          if (_hasCompared) ...[
            // View Mode Toggle
            Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: const Color(0xFF0F0F11),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF27272A)),
              ),
              child: Row(
                children: [
                  _buildToggleBtn(
                    label: 'Split View',
                    active: _isSplitView,
                    onTap: () {
                      setState(() => _isSplitView = true);
                      if (_currentChangeIndex >= 0) {
                        Future.delayed(const Duration(milliseconds: 50), () {
                          _jumpToChange(_currentChangeIndex);
                        });
                      }
                    },
                  ),
                  _buildToggleBtn(
                    label: 'Unified View',
                    active: !_isSplitView,
                    onTap: () {
                      setState(() => _isSplitView = false);
                      if (_currentChangeIndex >= 0) {
                        Future.delayed(const Duration(milliseconds: 50), () {
                          _jumpToChange(_currentChangeIndex);
                        });
                      }
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            // Changes Filtering Toggle
            Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: const Color(0xFF0F0F11),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF27272A)),
              ),
              child: Row(
                children: [
                  _buildToggleBtn(
                    label: 'All Lines',
                    active: !_showChangesOnly,
                    onTap: () {
                      setState(() => _showChangesOnly = false);
                    },
                  ),
                  _buildToggleBtn(
                    label: 'Changes Only',
                    active: _showChangesOnly,
                    onTap: () {
                      setState(() => _showChangesOnly = true);
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            IconButton(
              icon: const Icon(Icons.copy_all_rounded, size: 18, color: Color(0xFFA1A1AA)),
              tooltip: 'Copy Diff Representation',
              onPressed: () {
                final buffer = StringBuffer();
                for (final r in _diffRows) {
                  if (r.type == DiffType.equal) {
                    buffer.writeln('  ${r.rightText}');
                  } else if (r.type == DiffType.deletion) {
                    buffer.writeln('- ${r.leftText}');
                  } else if (r.type == DiffType.addition) {
                    buffer.writeln('+ ${r.rightText}');
                  } else if (r.type == DiffType.modification) {
                    buffer.writeln('- ${r.leftText}');
                    buffer.writeln('+ ${r.rightText}');
                  }
                }
                _copyResult(context, buffer.toString(), 'Diff Output');
              },
            ),
            const SizedBox(width: 4),
          ],
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFEF4444),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            icon: const Icon(Icons.delete_outline_rounded, size: 16),
            label: const Text('Clear', style: TextStyle(fontFamily: 'Inter', fontSize: 12)),
            onPressed: _clearAll,
          ),
          if (_hasCompared) ...[
            const SizedBox(width: 10),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF27272A),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              icon: const Icon(Icons.edit_rounded, size: 16),
              label: const Text('Edit Input', style: TextStyle(fontFamily: 'Inter', fontSize: 12)),
              onPressed: () {
                setState(() {
                  _hasCompared = false;
                });
              },
            ),
          ],
          if (!_hasCompared) ...[
            const SizedBox(width: 10),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF8B5CF6),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              icon: const Icon(Icons.play_arrow_rounded, size: 16),
              label: const Text('Compare', style: TextStyle(fontFamily: 'Inter', fontSize: 12)),
              onPressed: _compareCode,
            ),
          ]
        ],
      ),
    );
  }

  Widget _buildToggleBtn({required String label, required bool active, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF27272A) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 11,
            fontWeight: active ? FontWeight.bold : FontWeight.normal,
            color: active ? Colors.white : const Color(0xFF71717A),
          ),
        ),
      ),
    );
  }

  Widget _buildInputsPanel() {
    return Padding(
      padding: const EdgeInsets.all(20.0),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final totalWidth = constraints.maxWidth;
          const dividerWidth = 16.0;
          final availableWidth = totalWidth - dividerWidth;
          
          double leftWidth = (availableWidth * _splitRatio).clamp(200.0, availableWidth - 200.0);
          double rightWidth = availableWidth - leftWidth;

          return Row(
            children: [
              // Original Code Input
              SizedBox(
                width: leftWidth,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.history_rounded, size: 14, color: Color(0xFFEF4444)),
                        SizedBox(width: 6),
                        Text(
                          'Original Text / Code',
                          style: TextStyle(fontFamily: 'Inter', fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFFEF4444)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFF0F0F11),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFF27272A)),
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
                                  topLeft: Radius.circular(8),
                                  bottomLeft: Radius.circular(8),
                                ),
                              ),
                              child: SingleChildScrollView(
                                controller: _leftLineScrollController,
                                physics: const NeverScrollableScrollPhysics(),
                                child: ValueListenableBuilder<TextEditingValue>(
                                  valueListenable: _leftController,
                                  builder: (context, value, child) {
                                    final lineCount = '\n'.allMatches(value.text).length + 1;
                                    return Column(
                                      crossAxisAlignment: CrossAxisAlignment.end,
                                      children: List.generate(lineCount, (index) {
                                        return Container(
                                          height: 16.8,
                                          padding: const EdgeInsets.only(right: 8),
                                          alignment: Alignment.centerRight,
                                          child: Text(
                                            '${index + 1}',
                                            style: const TextStyle(
                                              fontFamily: 'Courier',
                                              fontSize: 12,
                                              height: 1.4,
                                              color: Color(0xFF52525B),
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
                                controller: _leftController,
                                scrollController: _leftScrollController,
                                maxLines: null,
                                keyboardType: TextInputType.multiline,
                                style: const TextStyle(
                                  fontFamily: 'Courier',
                                  fontSize: 12,
                                  color: Color(0xD8FFFFFF),
                                  height: 1.4,
                                ),
                                decoration: const InputDecoration(
                                  hintText: 'Paste original content here...',
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

              // Modified Code Input
              SizedBox(
                width: rightWidth,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.edit_note_rounded, size: 14, color: Color(0xFF10B981)),
                        SizedBox(width: 6),
                        Text(
                          'Modified Text / Code',
                          style: TextStyle(fontFamily: 'Inter', fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF10B981)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFF0F0F11),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFF27272A)),
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
                                  topLeft: Radius.circular(8),
                                  bottomLeft: Radius.circular(8),
                                ),
                              ),
                              child: SingleChildScrollView(
                                controller: _rightLineScrollController,
                                physics: const NeverScrollableScrollPhysics(),
                                child: ValueListenableBuilder<TextEditingValue>(
                                  valueListenable: _rightController,
                                  builder: (context, value, child) {
                                    final lineCount = '\n'.allMatches(value.text).length + 1;
                                    return Column(
                                      crossAxisAlignment: CrossAxisAlignment.end,
                                      children: List.generate(lineCount, (index) {
                                        return Container(
                                          height: 16.8,
                                          padding: const EdgeInsets.only(right: 8),
                                          alignment: Alignment.centerRight,
                                          child: Text(
                                            '${index + 1}',
                                            style: const TextStyle(
                                              fontFamily: 'Courier',
                                              fontSize: 12,
                                              height: 1.4,
                                              color: Color(0xFF52525B),
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
                                controller: _rightController,
                                scrollController: _rightScrollController,
                                maxLines: null,
                                keyboardType: TextInputType.multiline,
                                style: const TextStyle(
                                  fontFamily: 'Courier',
                                  fontSize: 12,
                                  color: Color(0xD8FFFFFF),
                                  height: 1.4,
                                ),
                                decoration: const InputDecoration(
                                  hintText: 'Paste modified content here...',
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
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSplitHeader(double leftWidth, double rightWidth, double availableWidth) {
    return Container(
      color: const Color(0xFF1E1E22),
      height: 32,
      child: Row(
        children: [
          SizedBox(
            width: leftWidth,
            child: const Padding(
              padding: EdgeInsets.only(left: 12.0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Original (Deletions)',
                  style: TextStyle(fontFamily: 'Inter', fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFFEF4444)),
                ),
              ),
            ),
          ),
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
                width: 16,
                color: Colors.transparent,
                child: Center(
                  child: Container(width: 2, height: 18, color: const Color(0xFF52525B)),
                ),
              ),
            ),
          ),
          SizedBox(
            width: rightWidth,
            child: const Padding(
              padding: EdgeInsets.only(left: 12.0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Modified (Additions)',
                  style: TextStyle(fontFamily: 'Inter', fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF10B981)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDiffViewer() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final totalWidth = constraints.maxWidth;
        const dividerWidth = 16.0;
        final availableWidth = totalWidth - dividerWidth;
        
        double leftWidth = (availableWidth * _splitRatio).clamp(200.0, availableWidth - 200.0);
        double rightWidth = availableWidth - leftWidth;

        return Column(
          children: [
            _buildStatsBar(),
            const Divider(height: 1, color: Color(0xFF27272A)),
            if (_isSplitView) ...[
              _buildSplitHeader(leftWidth, rightWidth, availableWidth),
              const Divider(height: 1, color: Color(0xFF27272A)),
            ],
            Expanded(
              child: Container(
                color: const Color(0xFF0F0F11),
                child: _isSplitView 
                    ? _buildSplitDiffList(leftWidth, rightWidth) 
                    : _buildUnifiedDiffList(),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildStatsBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () => _jumpToFirstChangeOfType(DiffType.addition),
                  child: _buildStatChip('Lines Added', '+$_addedCount', const Color(0xFF10B981), const Color(0x1510B981)),
                ),
              ),
              const SizedBox(width: 12),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () => _jumpToFirstChangeOfType(DiffType.deletion),
                  child: _buildStatChip('Lines Removed', '-$_deletedCount', const Color(0xFFEF4444), const Color(0x15EF4444)),
                ),
              ),
              const SizedBox(width: 12),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () => _jumpToFirstChangeOfType(DiffType.modification),
                  child: _buildStatChip('Lines Modified', '$_modifiedCount', const Color(0xFFF59E0B), const Color(0x15F59E0B)),
                ),
              ),
            ],
          ),
          Row(
            children: [
              Text(
                'Difference: ${_percentDiff.toStringAsFixed(1)}%',
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: Colors.white70,
                ),
              ),
              if (_currentChangeBlockIndices.isNotEmpty) ...[
                const SizedBox(width: 16),
                Container(width: 1, height: 16, color: const Color(0xFF27272A)),
                const SizedBox(width: 16),
                Text(
                  'Change ${_currentChangeIndex + 1} of ${_currentChangeBlockIndices.length}',
                  style: const TextStyle(fontFamily: 'Inter', fontSize: 11, color: Color(0xFFA1A1AA)),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.keyboard_arrow_up_rounded, size: 16),
                  tooltip: 'Previous Change',
                  constraints: const BoxConstraints(),
                  padding: EdgeInsets.zero,
                  onPressed: _currentChangeIndex > 0 
                      ? () => _jumpToChange(_currentChangeIndex - 1) 
                      : null,
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 16),
                  tooltip: 'Next Change',
                  constraints: const BoxConstraints(),
                  padding: EdgeInsets.zero,
                  onPressed: _currentChangeIndex < _currentChangeBlockIndices.length - 1 
                      ? () => _jumpToChange(_currentChangeIndex + 1) 
                      : null,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatChip(String label, String value, Color color, Color bg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(fontFamily: 'Inter', fontSize: 10, color: Color(0xFFA1A1AA)),
          ),
          const SizedBox(width: 6),
          Text(
            value,
            style: TextStyle(fontFamily: 'Courier', fontSize: 11, fontWeight: FontWeight.bold, color: color),
          ),
        ],
      ),
    );
  }

  Widget _buildSplitDiffList(double leftWidth, double rightWidth) {
    final displayedRows = _showChangesOnly 
        ? _diffRows.where((r) => r.type != DiffType.equal).toList() 
        : _diffRows;

    return ListView.builder(
      controller: _resultsScrollController,
      itemCount: displayedRows.length,
      itemBuilder: (context, index) {
        final row = displayedRows[index];

        Color leftBg = Colors.transparent;
        Color rightBg = Colors.transparent;
        Color leftBorder = Colors.transparent;
        Color rightBorder = Colors.transparent;
        Color leftTextColor = Colors.white70;
        Color rightTextColor = Colors.white70;

        if (row.type == DiffType.deletion) {
          leftBg = const Color(0x18EF4444);
          leftBorder = const Color(0xFFEF4444);
          leftTextColor = const Color(0xFFFCA5A5);
        } else if (row.type == DiffType.addition) {
          rightBg = const Color(0x1810B981);
          rightBorder = const Color(0xFF10B981);
          rightTextColor = const Color(0xFFA7F3D0);
        } else if (row.type == DiffType.modification) {
          leftBg = const Color(0x18EF4444);
          leftBorder = const Color(0xFFEF4444);
          leftTextColor = const Color(0xFFFCA5A5);

          rightBg = const Color(0x1810B981);
          rightBorder = const Color(0xFF10B981);
          rightTextColor = const Color(0xFFA7F3D0);
        }

        return SizedBox(
          height: 22.0,
          child: Container(
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0xFF1E1E22), width: 0.5)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Left Column (Original)
                SizedBox(
                  width: leftWidth,
                  child: Container(
                    color: leftBg,
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Line Number
                        Container(
                          width: 45,
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 8),
                          child: Text(
                            row.leftLineNum?.toString() ?? '',
                            style: const TextStyle(fontFamily: 'Courier', fontSize: 11, color: Color(0xFF52525B)),
                          ),
                        ),
                        Container(width: 3, height: 18, color: leftBorder),
                        const SizedBox(width: 8),
                        // Text
                        Expanded(
                          child: Text(
                            row.leftText ?? '',
                            style: TextStyle(
                              fontFamily: 'Courier',
                              fontSize: 11,
                              color: leftTextColor,
                              overflow: TextOverflow.clip,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // Separator / drag line spacer
                Container(width: 16, height: 22, color: const Color(0xFF27272A), child: const VerticalDivider(width: 16, color: Color(0xFF3F3F46), thickness: 1)),
                // Right Column (Modified)
                SizedBox(
                  width: rightWidth,
                  child: Container(
                    color: rightBg,
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Line Number
                        Container(
                          width: 45,
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 8),
                          child: Text(
                            row.rightLineNum?.toString() ?? '',
                            style: const TextStyle(fontFamily: 'Courier', fontSize: 11, color: Color(0xFF52525B)),
                          ),
                        ),
                        Container(width: 3, height: 18, color: rightBorder),
                        const SizedBox(width: 8),
                        // Text
                        Expanded(
                          child: Text(
                            row.rightText ?? '',
                            style: TextStyle(
                              fontFamily: 'Courier',
                              fontSize: 11,
                              color: rightTextColor,
                              overflow: TextOverflow.clip,
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
        );
      },
    );
  }

  Widget _buildUnifiedDiffList() {
    // Generate unified list of displays:
    List<_UnifiedRow> unified = [];
    for (final r in _diffRows) {
      if (r.type == DiffType.equal) {
        if (!_showChangesOnly) {
          unified.add(_UnifiedRow(lineNumLeft: r.leftLineNum, lineNumRight: r.rightLineNum, text: r.rightText ?? '', type: DiffType.equal));
        }
      } else if (r.type == DiffType.deletion) {
        unified.add(_UnifiedRow(lineNumLeft: r.leftLineNum, lineNumRight: null, text: r.leftText ?? '', type: DiffType.deletion));
      } else if (r.type == DiffType.addition) {
        unified.add(_UnifiedRow(lineNumLeft: null, lineNumRight: r.rightLineNum, text: r.rightText ?? '', type: DiffType.addition));
      } else if (r.type == DiffType.modification) {
        unified.add(_UnifiedRow(lineNumLeft: r.leftLineNum, lineNumRight: null, text: r.leftText ?? '', type: DiffType.deletion));
        unified.add(_UnifiedRow(lineNumLeft: null, lineNumRight: r.rightLineNum, text: r.rightText ?? '', type: DiffType.addition));
      }
    }

    return ListView.builder(
      controller: _resultsScrollController,
      itemCount: unified.length,
      itemBuilder: (context, index) {
        final row = unified[index];
        Color bg = Colors.transparent;
        Color border = Colors.transparent;
        Color textColor = Colors.white70;
        String sign = ' ';

        if (row.type == DiffType.deletion) {
          bg = const Color(0x18EF4444);
          border = const Color(0xFFEF4444);
          textColor = const Color(0xFFFCA5A5);
          sign = '-';
        } else if (row.type == DiffType.addition) {
          bg = const Color(0x1810B981);
          border = const Color(0xFF10B981);
          textColor = const Color(0xFFA7F3D0);
          sign = '+';
        }

        return SizedBox(
          height: 22.0,
          child: Container(
            color: bg,
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Left line num
                Container(
                  width: 40,
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 6),
                  child: Text(
                    row.lineNumLeft?.toString() ?? '',
                    style: const TextStyle(fontFamily: 'Courier', fontSize: 11, color: Color(0xFF52525B)),
                  ),
                ),
                // Right line num
                Container(
                  width: 40,
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 6),
                  child: Text(
                    row.lineNumRight?.toString() ?? '',
                    style: const TextStyle(fontFamily: 'Courier', fontSize: 11, color: Color(0xFF52525B)),
                  ),
                ),
                Container(width: 3, height: 18, color: border),
                const SizedBox(width: 8),
                // Sign indicator
                Text(
                  sign,
                  style: TextStyle(fontFamily: 'Courier', fontSize: 11, fontWeight: FontWeight.bold, color: border == Colors.transparent ? const Color(0xFF52525B) : border),
                ),
                const SizedBox(width: 8),
                // Text
                Expanded(
                  child: Text(
                    row.text,
                    style: TextStyle(
                      fontFamily: 'Courier',
                      fontSize: 11,
                      color: textColor,
                      overflow: TextOverflow.clip,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _DiffResult {
  final List<DiffRow> rows;
  final int added;
  final int deleted;
  final int modified;
  final double percent;

  _DiffResult({
    required this.rows,
    required this.added,
    required this.deleted,
    required this.modified,
    required this.percent,
  });
}

class _UnifiedRow {
  final int? lineNumLeft;
  final int? lineNumRight;
  final String text;
  final DiffType type;

  _UnifiedRow({
    this.lineNumLeft,
    this.lineNumRight,
    required this.text,
    required this.type,
  });
}
