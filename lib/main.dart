import 'dart:io';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

void main() {
  runApp(const VVFApp());
}

// ═══════════════════════════════════════════════
// THEME COLORS — Orange, Gold, Red (VVF Theme)
// ═══════════════════════════════════════════════
const Color kOrange = Color(0xFFE65100);
const Color kGold = Color(0xFFFFB300);
const Color kRed = Color(0xFFB71C1C);
const Color kDarkBg = Color(0xFF121212);
const Color kCardBg = Color(0xFF1E1E1E);
const Color kSurface = Color(0xFF2A2A2A);
const Color kTextPrimary = Color(0xFFFFF8E1);
const Color kTextSecondary = Color(0xFFBCAAA4);

// ═══════════════════════════════════════════════
// FILE MODEL
// ═══════════════════════════════════════════════
class FileInfo {
  final String path;
  final String name;
  final String ext;
  final int size;
  final String hash;
  bool selected;

  FileInfo({
    required this.path,
    required this.name,
    required this.ext,
    required this.size,
    required this.hash,
    this.selected = false,
  });

  String get sizeFormatted {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class DuplicateGroup {
  final String hash;
  final List<FileInfo> files;
  DuplicateGroup({required this.hash, required this.files});
}

class NearDuplicatePair {
  final FileInfo file1;
  final FileInfo file2;
  final double similarity;
  NearDuplicatePair(
      {required this.file1, required this.file2, required this.similarity});
}

// ═══════════════════════════════════════════════
// SCANNER SERVICE
// ═══════════════════════════════════════════════
class ScannerService {
  static const supportedExtensions = {
    '.txt', '.md', '.pdf', '.docx', '.doc',
    '.mp3', '.mp4', '.jpg', '.jpeg', '.png',
    '.zip', '.rar', '.apk', '.xlsx', '.pptx',
  };

  static const textExtensions = {'.txt', '.md'};

  final Set<String> selectedExtensions;
  final double similarityThreshold;

  ScannerService({
    required this.selectedExtensions,
    required this.similarityThreshold,
  });

  Stream<String> scanDirectory(
    String dirPath, {
    required Function(List<DuplicateGroup>, List<NearDuplicatePair>) onDone,
    required Function(String) onProgress,
  }) async* {
    final dir = Directory(dirPath);
    if (!await dir.exists()) {
      yield 'फोल्डर नहीं मिला: $dirPath';
      onDone([], []);
      return;
    }

    final List<FileSystemEntity> entities = [];
    int skippedCount = 0;

    try {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          final ext = p.extension(entity.path).toLowerCase();
          if (selectedExtensions.contains(ext)) {
            entities.add(entity);
          }
        }
      }
    } catch (e) {
      skippedCount++;
    }

    // ── FIX: Show clear message if nothing found ──
    if (entities.isEmpty) {
      yield '⚠ कोई फाइल नहीं मिली — अनुमति जाँचें';
      onDone([], []);
      return;
    }

    yield 'मिली फाइलें: ${entities.length}';

    // === EXACT DUPLICATES via MD5 ===
    final Map<String, List<FileInfo>> hashGroups = {};
    int processed = 0;
    int readErrors = 0;

    for (final entity in entities) {
      try {
        final file = entity as File;
        final stat = await file.stat();
        final bytes = await file.readAsBytes();
        final hash = md5.convert(bytes).toString();
        final ext = p.extension(file.path).toLowerCase();

        final info = FileInfo(
          path: file.path,
          name: p.basename(file.path),
          ext: ext,
          size: stat.size,
          hash: hash,
        );

        hashGroups.putIfAbsent(hash, () => []).add(info);
        processed++;

        if (processed % 10 == 0) {
          onProgress('हैश कर रहे हैं: $processed/${entities.length}');
        }
      } catch (e) {
        readErrors++;
      }
    }

    // ── FIX: Report read errors ──
    if (readErrors > 0) {
      onProgress('$readErrors फाइलें पढ़ने में त्रुटि (अनुमति?)');
    }

    final exactDuplicates = hashGroups.entries
        .where((e) => e.value.length > 1)
        .map((e) => DuplicateGroup(hash: e.key, files: e.value))
        .toList();

    yield 'एग्जैक्ट डुप्लीकेट ग्रुप: ${exactDuplicates.length}';

    // === NEAR DUPLICATES via Jaccard Similarity (text files only) ===
    final List<NearDuplicatePair> nearDuplicates = [];

    final textFiles = hashGroups.values
        .expand((e) => e)
        .where((f) => textExtensions.contains(f.ext))
        .toList();

    final Set<String> seenHashes = {};
    final List<FileInfo> uniqueTextFiles = [];
    for (final f in textFiles) {
      if (!seenHashes.contains(f.hash)) {
        seenHashes.add(f.hash);
        uniqueTextFiles.add(f);
      }
    }

    onProgress('नियर-डुप्लीकेट ढूंढ रहे हैं...');

    for (int i = 0; i < uniqueTextFiles.length; i++) {
      for (int j = i + 1; j < uniqueTextFiles.length; j++) {
        try {
          final content1 = await File(uniqueTextFiles[i].path).readAsString();
          final content2 = await File(uniqueTextFiles[j].path).readAsString();

          final similarity = _jaccardSimilarity(content1, content2);
          if (similarity >= similarityThreshold) {
            nearDuplicates.add(NearDuplicatePair(
              file1: uniqueTextFiles[i],
              file2: uniqueTextFiles[j],
              similarity: similarity,
            ));
          }
        } catch (e) {
          // Skip unreadable text files
        }
      }
    }

    yield 'नियर-डुप्लीकेट जोड़े: ${nearDuplicates.length}';
    onDone(exactDuplicates, nearDuplicates);
  }

  static double _jaccardSimilarity(String text1, String text2) {
    final Set<String> words1 =
        text1.toLowerCase().split(RegExp(r'\s+')).toSet();
    final Set<String> words2 =
        text2.toLowerCase().split(RegExp(r'\s+')).toSet();

    if (words1.isEmpty && words2.isEmpty) return 1.0;
    if (words1.isEmpty || words2.isEmpty) return 0.0;

    final intersection = words1.intersection(words2).length;
    final union = words1.union(words2).length;
    return intersection / union;
  }

  static Future<void> moveToFolder(
      List<String> filePaths, String targetDir) async {
    final dir = Directory(targetDir);
    if (!await dir.exists()) await dir.create(recursive: true);

    for (final path in filePaths) {
      try {
        final file = File(path);
        final name = p.basename(path);
        await file.rename(p.join(targetDir, name));
      } catch (e) {
        try {
          final file = File(path);
          final name = p.basename(path);
          await file.copy(p.join(targetDir, name));
          await file.delete();
        } catch (_) {}
      }
    }
  }

  static Future<void> deleteFiles(List<String> filePaths) async {
    for (final path in filePaths) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
  }
}

// ═══════════════════════════════════════════════
// APP ROOT
// ═══════════════════════════════════════════════
class VVFApp extends StatelessWidget {
  const VVFApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VVF Duplicate Finder',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kDarkBg,
        colorScheme: ColorScheme.dark(
          primary: kOrange,
          secondary: kGold,
          error: kRed,
          surface: kCardBg,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: kDarkBg,
          foregroundColor: kGold,
          elevation: 0,
          titleTextStyle: TextStyle(
            color: kGold,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: kOrange,
            foregroundColor: Colors.white,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            padding:
                const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
          ),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

// ═══════════════════════════════════════════════
// HOME SCREEN
// ═══════════════════════════════════════════════
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  Set<String> selectedExtensions = {
    '.txt', '.md', '.pdf', '.docx', '.doc',
  };
  double threshold = 0.80;
  String scanPath = '/storage/emulated/0/';
  bool isSDCard = false;

  // ── FIX: Track permission status ──
  bool _permissionGranted = false;
  bool _waitingForSettings = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkPermission();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // ── FIX: Re-check permission when user returns from Settings ──
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _waitingForSettings) {
      _waitingForSettings = false;
      _checkPermission();
    }
  }

  Future<void> _checkPermission() async {
    final manageStatus = await Permission.manageExternalStorage.status;
    final storageStatus = await Permission.storage.status;
    if (mounted) {
      setState(() {
        _permissionGranted =
            manageStatus.isGranted || storageStatus.isGranted;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          // ── APP BAR ──
          SliverAppBar(
            expandedHeight: 200,
            pinned: true,
            backgroundColor: kDarkBg,
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xFF3E1A00), kDarkBg],
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(height: 40),
                    Container(
                      width: 90,
                      height: 90,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: kGold, width: 2.5),
                        boxShadow: [
                          BoxShadow(
                            color: kOrange.withOpacity(0.4),
                            blurRadius: 20,
                            spreadRadius: 2,
                          )
                        ],
                      ),
                      child: ClipOval(
                        child: Image.asset(
                          'assets/logo.jpg',
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(
                            color: kOrange,
                            child: const Icon(Icons.search,
                                color: Colors.white, size: 40),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'VVF Duplicate Finder',
                      style: TextStyle(
                        color: kGold,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const Text(
                      'Vishwa Vijayaa Foundation',
                      style: TextStyle(color: kTextSecondary, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ),

          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverList(
              delegate: SliverChildListDelegate([

                // ── FIX: Permission Status Banner ──
                if (!_permissionGranted) ...[
                  _PermissionBanner(
                    onGrantPress: _requestPermission,
                  ),
                  const SizedBox(height: 16),
                ],

                // ── SCAN LOCATION ──
                _SectionCard(
                  title: 'स्कैन कहाँ करें?',
                  icon: Icons.folder_outlined,
                  child: Column(
                    children: [
                      _ToggleRow(
                        label: 'फोन स्टोरेज',
                        subtitle: '/storage/emulated/0/',
                        value: !isSDCard,
                        onTap: () => setState(() {
                          isSDCard = false;
                          scanPath = '/storage/emulated/0/';
                        }),
                      ),
                      const Divider(color: kSurface),
                      _ToggleRow(
                        label: 'SD कार्ड',
                        subtitle: 'बाहरी स्टोरेज',
                        value: isSDCard,
                        onTap: () => setState(() {
                          isSDCard = true;
                          scanPath = '/storage/';
                        }),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 16),

                // ── FILE TYPES ──
                _SectionCard(
                  title: 'फाइल प्रकार चुनें',
                  icon: Icons.file_copy_outlined,
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: ScannerService.supportedExtensions.map((ext) {
                      final selected = selectedExtensions.contains(ext);
                      return GestureDetector(
                        onTap: () => setState(() {
                          if (selected) {
                            selectedExtensions.remove(ext);
                          } else {
                            selectedExtensions.add(ext);
                          }
                        }),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: selected
                                ? kOrange.withOpacity(0.25)
                                : kSurface,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: selected ? kOrange : Colors.transparent,
                              width: 1.5,
                            ),
                          ),
                          child: Text(
                            ext,
                            style: TextStyle(
                              color: selected ? kGold : kTextSecondary,
                              fontWeight: selected
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),

                const SizedBox(height: 16),

                // ── SIMILARITY THRESHOLD ──
                _SectionCard(
                  title: 'नियर-डुप्लीकेट संवेदनशीलता',
                  icon: Icons.tune,
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('कम (अधिक मिलेंगे)',
                              style: TextStyle(
                                  color: kTextSecondary, fontSize: 12)),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 4),
                            decoration: BoxDecoration(
                              color: kOrange,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              '${(threshold * 100).round()}%',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold),
                            ),
                          ),
                          const Text('अधिक (कम मिलेंगे)',
                              style: TextStyle(
                                  color: kTextSecondary, fontSize: 12)),
                        ],
                      ),
                      Slider(
                        value: threshold,
                        min: 0.5,
                        max: 0.99,
                        divisions: 49,
                        activeColor: kOrange,
                        inactiveColor: kSurface,
                        onChanged: (v) => setState(() => threshold = v),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 24),

                // ── SCAN BUTTON ──
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton.icon(
                    onPressed: selectedExtensions.isEmpty ? null : _startScan,
                    icon: const Icon(Icons.search, size: 24),
                    label: const Text(
                      'स्कैन शुरू करें',
                      style: TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: kOrange,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                    ),
                  ),
                ),

                const SizedBox(height: 16),

                // ── INFO ──
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: kRed.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: kRed.withOpacity(0.3)),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.info_outline, color: kGold, size: 18),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'पहले स्कैन करें, फिर परिणाम देखकर डिलीट या मूव करें।',
                          style:
                              TextStyle(color: kTextSecondary, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 30),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  // ── FIX: Step-by-step permission request ──
  Future<void> _requestPermission() async {
    // Step 1: Try MANAGE_EXTERNAL_STORAGE (Android 11+)
    final manageStatus = await Permission.manageExternalStorage.status;

    if (manageStatus.isGranted) {
      setState(() => _permissionGranted = true);
      return;
    }

    // Step 2: If denied but not permanently — request it
    if (!manageStatus.isPermanentlyDenied) {
      final result = await Permission.manageExternalStorage.request();
      if (result.isGranted) {
        setState(() => _permissionGranted = true);
        return;
      }
    }

    // Step 3: Need to open Settings (Android 11+ always needs this for MANAGE)
    if (mounted) {
      await showDialog(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: kCardBg,
          title: const Text('अनुमति आवश्यक है',
              style: TextStyle(color: kGold)),
          content: const Text(
            'फाइल स्कैन के लिए "All Files Access" अनुमति चाहिए।\n\n'
            'नीचे "Settings खोलें" दबाएं, फिर:\n'
            '• "All Files Access" या\n'
            '• "Files and Media" > "Allow All"\n\n'
            'Allow करने के बाद वापस आएं।',
            style: TextStyle(color: kTextSecondary, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('बाद में',
                  style: TextStyle(color: kTextSecondary)),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                _waitingForSettings = true;
                openAppSettings();
              },
              style:
                  ElevatedButton.styleFrom(backgroundColor: kOrange),
              child: const Text('Settings खोलें'),
            ),
          ],
        ),
      );
    }

    // Step 4: Fallback — try regular storage permission (Android 10 and below)
    final storageStatus = await Permission.storage.request();
    if (storageStatus.isGranted) {
      setState(() => _permissionGranted = true);
    }
  }

  // ── FIX: Scan only after confirming permission ──
  void _startScan() async {
    // Re-check permission fresh before scanning
    await _checkPermission();

    if (!_permissionGranted) {
      await _requestPermission();
      // Re-check after request attempt
      await _checkPermission();
      if (!_permissionGranted) return;
    }

    if (mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ScanScreen(
            scanPath: scanPath,
            selectedExtensions: selectedExtensions,
            threshold: threshold,
          ),
        ),
      );
    }
  }
}

// ═══════════════════════════════════════════════
// PERMISSION BANNER WIDGET
// ═══════════════════════════════════════════════
class _PermissionBanner extends StatelessWidget {
  final VoidCallback onGrantPress;
  const _PermissionBanner({required this.onGrantPress});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kRed.withOpacity(0.15),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kRed.withOpacity(0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.lock_outline, color: kRed, size: 18),
              SizedBox(width: 8),
              Text(
                'स्टोरेज अनुमति नहीं दी गई',
                style: TextStyle(
                    color: kRed,
                    fontWeight: FontWeight.bold,
                    fontSize: 14),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'बिना अनुमति के स्कैन काम नहीं करेगी। नीचे बटन दबाएं।',
            style: TextStyle(color: kTextSecondary, fontSize: 12),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: onGrantPress,
              icon: const Icon(Icons.security, size: 16),
              label: const Text('अनुमति दें'),
              style: ElevatedButton.styleFrom(
                backgroundColor: kRed,
                padding:
                    const EdgeInsets.symmetric(vertical: 10),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════
// SCAN SCREEN
// ═══════════════════════════════════════════════
class ScanScreen extends StatefulWidget {
  final String scanPath;
  final Set<String> selectedExtensions;
  final double threshold;

  const ScanScreen({
    super.key,
    required this.scanPath,
    required this.selectedExtensions,
    required this.threshold,
  });

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  List<DuplicateGroup> exactDuplicates = [];
  List<NearDuplicatePair> nearDuplicates = [];
  bool scanning = true;
  String progressMsg = 'स्कैन शुरू हो रहा है...';
  String activeTab = 'exact';

  // ── FIX: Track if scan found 0 files (permission issue) ──
  bool _zeroFilesFound = false;

  @override
  void initState() {
    super.initState();
    _runScan();
  }

  Future<void> _runScan() async {
    if (mounted) {
      setState(() {
        scanning = true;
        progressMsg = 'स्कैन शुरू हो रहा है...';
        exactDuplicates = [];
        nearDuplicates = [];
        _zeroFilesFound = false;
      });
    }

    final scanner = ScannerService(
      selectedExtensions: widget.selectedExtensions,
      similarityThreshold: widget.threshold,
    );

    await for (final msg in scanner.scanDirectory(
      widget.scanPath,
      onProgress: (msg) {
        if (mounted) setState(() => progressMsg = msg);
      },
      onDone: (exact, near) {
        if (mounted) {
          setState(() {
            exactDuplicates = exact;
            nearDuplicates = near;
            scanning = false;
            // ── FIX: Detect zero-file result ──
            _zeroFilesFound = exact.isEmpty && near.isEmpty;
          });
        }
      },
    )) {
      if (mounted) setState(() => progressMsg = msg);
    }
  }

  int get totalWastedSpace {
    int total = 0;
    for (final group in exactDuplicates) {
      for (int i = 1; i < group.files.length; i++) {
        total += group.files[i].size;
      }
    }
    return total;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('स्कैन परिणाम'),
        backgroundColor: kDarkBg,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: kGold),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: scanning ? _buildScanning() : _buildResults(),
      bottomNavigationBar: scanning ? null : _buildBottomBar(),
    );
  }

  Widget _buildScanning() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 60,
            height: 60,
            child: CircularProgressIndicator(
              color: kOrange,
              strokeWidth: 5,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            progressMsg,
            style: const TextStyle(color: kGold, fontSize: 16),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 10),
          const Text(
            'कृपया प्रतीक्षा करें...',
            style: TextStyle(color: kTextSecondary),
          ),
        ],
      ),
    );
  }

  Widget _buildResults() {
    return Column(
      children: [
        // ── FIX: Zero files warning ──
        if (_zeroFilesFound && exactDuplicates.isEmpty && nearDuplicates.isEmpty)
          _ZeroFilesWarning(
            scanPath: widget.scanPath,
            onOpenSettings: openAppSettings,
            onRescan: _runScan,
          ),

        if (!_zeroFilesFound) ...[
          // ── SUMMARY ──
          Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF3E1A00), kCardBg],
              ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: kOrange.withOpacity(0.4)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _StatBox(
                    label: 'डुप्लीकेट\nग्रुप',
                    value: '${exactDuplicates.length}'),
                Container(
                    width: 1, height: 40, color: kOrange.withOpacity(0.3)),
                _StatBox(
                    label: 'नियर-\nडुप्लीकेट',
                    value: '${nearDuplicates.length}'),
                Container(
                    width: 1, height: 40, color: kOrange.withOpacity(0.3)),
                _StatBox(
                    label: 'बर्बाद\nस्पेस',
                    value: _formatBytes(totalWastedSpace)),
              ],
            ),
          ),

          // ── TABS ──
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() => activeTab = 'exact'),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        color: activeTab == 'exact' ? kOrange : kSurface,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        'एग्जैक्ट (${exactDuplicates.length})',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: activeTab == 'exact'
                              ? Colors.white
                              : kTextSecondary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() => activeTab = 'near'),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        color: activeTab == 'near' ? kGold : kSurface,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        'नियर-डुप्लीकेट (${nearDuplicates.length})',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: activeTab == 'near'
                              ? Colors.black
                              : kTextSecondary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // ── LIST ──
          Expanded(
            child:
                activeTab == 'exact' ? _buildExactList() : _buildNearList(),
          ),
        ],

        if (_zeroFilesFound)
          const Expanded(child: SizedBox()),
      ],
    );
  }

  Widget _buildExactList() {
    if (exactDuplicates.isEmpty) {
      return const _EmptyState(
          icon: Icons.check_circle_outline,
          message: 'कोई एग्जैक्ट डुप्लीकेट नहीं मिली!');
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: exactDuplicates.length,
      itemBuilder: (context, index) {
        final group = exactDuplicates[index];
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: kCardBg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: kOrange.withOpacity(0.2)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: kRed.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        'ग्रुप ${index + 1}  •  ${group.files.length} फाइलें',
                        style: const TextStyle(color: kRed, fontSize: 12),
                      ),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () => _selectGroupDuplicates(group),
                      style: TextButton.styleFrom(
                          foregroundColor: kGold,
                          padding: EdgeInsets.zero),
                      child: const Text('सब चुनें',
                          style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              ),
              ...group.files.asMap().entries.map((entry) {
                final idx = entry.key;
                final file = entry.value;
                return Container(
                  color: idx == 0
                      ? kSurface.withOpacity(0.5)
                      : Colors.transparent,
                  child: ListTile(
                    leading: Icon(
                      _fileIcon(file.ext),
                      color: idx == 0 ? Colors.green.shade400 : kOrange,
                      size: 28,
                    ),
                    title: Text(
                      file.name,
                      style:
                          const TextStyle(color: kTextPrimary, fontSize: 13),
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${file.sizeFormatted}  •  ${_shortenPath(file.path)}',
                      style: const TextStyle(
                          color: kTextSecondary, fontSize: 11),
                    ),
                    trailing: idx == 0
                        ? const Tooltip(
                            message: 'यह रखें',
                            child: Icon(Icons.star, color: kGold, size: 18))
                        : Checkbox(
                            value: file.selected,
                            activeColor: kOrange,
                            onChanged: (v) =>
                                setState(() => file.selected = v ?? false),
                          ),
                  ),
                );
              }),
            ],
          ),
        );
      },
    );
  }

  Widget _buildNearList() {
    if (nearDuplicates.isEmpty) {
      return const _EmptyState(
          icon: Icons.library_books_outlined,
          message:
              'कोई नियर-डुप्लीकेट नहीं मिली। थ्रेसहोल्ड कम करके दोबारा स्कैन करें।');
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: nearDuplicates.length,
      itemBuilder: (context, index) {
        final pair = nearDuplicates[index];
        final pct = (pair.similarity * 100).round();
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: kCardBg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: kGold.withOpacity(0.2)),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: kGold.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '$pct% समानता',
                      style: const TextStyle(
                          color: kGold,
                          fontWeight: FontWeight.bold,
                          fontSize: 13),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _NearFileRow(file: pair.file1),
              const SizedBox(height: 4),
              const Icon(Icons.compare_arrows, color: kOrange, size: 20),
              const SizedBox(height: 4),
              _NearFileRow(file: pair.file2),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBottomBar() {
    if (_zeroFilesFound) return const SizedBox.shrink();

    final selectedFiles = exactDuplicates
        .expand((g) => g.files)
        .where((f) => f.selected)
        .map((f) => f.path)
        .toList();

    return Container(
      decoration: const BoxDecoration(
        color: kCardBg,
        border: Border(top: BorderSide(color: kSurface)),
      ),
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Expanded(
            child: ElevatedButton.icon(
              onPressed:
                  selectedFiles.isEmpty ? null : () => _moveFiles(selectedFiles),
              icon: const Icon(Icons.drive_file_move_outlined, size: 18),
              label: const Text('मूव करें'),
              style: ElevatedButton.styleFrom(
                backgroundColor: kGold,
                foregroundColor: Colors.black,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: ElevatedButton.icon(
              onPressed: selectedFiles.isEmpty
                  ? null
                  : () => _deleteFiles(selectedFiles),
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('डिलीट करें'),
              style: ElevatedButton.styleFrom(backgroundColor: kRed),
            ),
          ),
        ],
      ),
    );
  }

  void _selectGroupDuplicates(DuplicateGroup group) {
    setState(() {
      for (int i = 1; i < group.files.length; i++) {
        group.files[i].selected = true;
      }
    });
  }

  Future<void> _moveFiles(List<String> paths) async {
    final targetDir = '/storage/emulated/0/Duplicates_VVF';
    await ScannerService.moveToFolder(paths, targetDir);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${paths.length} फाइलें $targetDir में मूव की गईं'),
          backgroundColor: Colors.green.shade700,
        ),
      );
      _runScan();
    }
  }

  Future<void> _deleteFiles(List<String> paths) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: kCardBg,
        title: const Text('पक्का डिलीट करें?',
            style: TextStyle(color: kGold)),
        content: Text(
          '${paths.length} फाइलें स्थायी रूप से डिलीट होंगी। यह वापस नहीं आएंगी!',
          style: const TextStyle(color: kTextSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('नहीं', style: TextStyle(color: kGold)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: kRed),
            child: const Text('हाँ, डिलीट करें'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await ScannerService.deleteFiles(paths);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${paths.length} फाइलें डिलीट की गईं'),
            backgroundColor: kRed,
          ),
        );
        _runScan();
      }
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)}KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
  }

  String _shortenPath(String path) {
    final parts = path.split('/');
    if (parts.length <= 3) return path;
    return '.../${parts[parts.length - 2]}/${parts.last}';
  }

  IconData _fileIcon(String ext) {
    switch (ext) {
      case '.pdf':
        return Icons.picture_as_pdf;
      case '.docx':
      case '.doc':
        return Icons.description;
      case '.mp3':
      case '.mp4':
        return Icons.music_note;
      case '.jpg':
      case '.jpeg':
      case '.png':
        return Icons.image;
      case '.zip':
      case '.rar':
        return Icons.folder_zip;
      default:
        return Icons.insert_drive_file;
    }
  }
}

// ═══════════════════════════════════════════════
// ZERO FILES WARNING WIDGET
// ═══════════════════════════════════════════════
class _ZeroFilesWarning extends StatelessWidget {
  final String scanPath;
  final VoidCallback onOpenSettings;
  final VoidCallback onRescan;

  const _ZeroFilesWarning({
    required this.scanPath,
    required this.onOpenSettings,
    required this.onRescan,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(20),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: kRed.withOpacity(0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kRed.withOpacity(0.4)),
      ),
      child: Column(
        children: [
          Icon(Icons.warning_amber_rounded,
              color: kRed, size: 48),
          const SizedBox(height: 12),
          const Text(
            'कोई फाइल नहीं मिली',
            style: TextStyle(
                color: kGold, fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            'स्कैन पाथ: $scanPath\n\n'
            'संभावित कारण:\n'
            '• "All Files Access" अनुमति नहीं दी\n'
            '• Settings > Apps > VVF Duplicate Finder > Permissions > Files and Media > Allow All',
            style: const TextStyle(color: kTextSecondary, height: 1.6),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onOpenSettings,
                  icon: const Icon(Icons.settings, size: 16),
                  label: const Text('Settings खोलें'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: kGold,
                    side: const BorderSide(color: kGold),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: onRescan,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('फिर स्कैन करें'),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: kOrange),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════
// HELPER WIDGETS
// ═══════════════════════════════════════════════
class _SectionCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget child;

  const _SectionCard(
      {required this.title, required this.icon, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: kCardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kOrange.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(icon, color: kGold, size: 20),
                const SizedBox(width: 8),
                Text(title,
                    style: const TextStyle(
                        color: kGold,
                        fontWeight: FontWeight.bold,
                        fontSize: 14)),
              ],
            ),
          ),
          const Divider(color: kSurface, height: 1),
          Padding(padding: const EdgeInsets.all(16), child: child),
        ],
      ),
    );
  }
}

class _ToggleRow extends StatelessWidget {
  final String label;
  final String subtitle;
  final bool value;
  final VoidCallback onTap;

  const _ToggleRow(
      {required this.label,
      required this.subtitle,
      required this.value,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Icon(
              value
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              color: value ? kOrange : kTextSecondary,
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(
                        color: value ? kTextPrimary : kTextSecondary,
                        fontWeight:
                            value ? FontWeight.bold : FontWeight.normal)),
                Text(subtitle,
                    style: const TextStyle(
                        color: kTextSecondary, fontSize: 11)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatBox extends StatelessWidget {
  final String label;
  final String value;
  const _StatBox({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value,
            style: const TextStyle(
                color: kGold, fontSize: 22, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text(label,
            style: const TextStyle(color: kTextSecondary, fontSize: 11),
            textAlign: TextAlign.center),
      ],
    );
  }
}

class _NearFileRow extends StatelessWidget {
  final FileInfo file;
  const _NearFileRow({required this.file});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.insert_drive_file, color: kOrange, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(file.name,
                    style: const TextStyle(color: kTextPrimary, fontSize: 12),
                    overflow: TextOverflow.ellipsis),
                Text(file.sizeFormatted,
                    style: const TextStyle(
                        color: kTextSecondary, fontSize: 11)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String message;
  const _EmptyState({required this.icon, required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 72, color: kOrange.withOpacity(0.4)),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: kTextSecondary, fontSize: 15),
            ),
          ),
        ],
      ),
    );
  }
}
