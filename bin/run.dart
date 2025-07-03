import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

// ANSI escape codes for cursor control and text styling.
const String _ansiRed = '\u001b[31m';
const String _ansiGreen = '\u001b[32m';
const String _ansiYellow = '\u001b[33m';
const String _ansiBold = '\u001b[1m';
const String _ansiReset = '\u001b[0m';
const String _ansiHideCursor = '\u001b[?25l';
const String _ansiShowCursor = '\u001b[?25h';
const String _ansiClearScreen = '\u001b[2J\u001b[H';
const String _ansiClearLine = '\u001b[K';
const String _ansiCursorUp2 = '\u001b[2A';
const String _ansiCursorUp1 = '\u001b[1A';

// The name of the file used to cache run data.
const String _cacheFileName = '.test_laser.cache';

/// Represents the current strategy for the watch mode.
enum _WatchState {
  needsFullRun,
  needsFailedRun,
}

/// A simple debouncer using the built-in Timer.
class _Debouncer {
  final Duration delay;
  Timer? _timer;

  _Debouncer({required this.delay});

  void call(void Function() callback) {
    _timer?.cancel();
    _timer = Timer(delay, callback);
  }

  void cancel() {
    _timer?.cancel();
  }
}

/// Script entry point. Decides whether to run once or start watch mode.
void main(List<String> args) async {
  if (args.contains('--version')) {
    await _printFlutterVersion();
  }

  final isWatchMode = args.contains('--watch');

  final testRunnerArgs =
      args.where((arg) => arg != '--watch' && arg != '--version').toList();

  if (isWatchMode) {
    await _runWatchMode(testRunnerArgs);
  } else {
    final success = await _runSingleTest(testRunnerArgs);
    exit(success ? 0 : 1);
  }
}

/// A helper function to run `flutter --version` and print the output.
Future<void> _printFlutterVersion() async {
  print('$_ansiBold--- Flutter Version ---$_ansiReset');
  try {
    final result = await Process.run('flutter', ['--version']);
    if (result.exitCode == 0) {
      print(result.stdout.toString().trim());
    } else {
      // CORRECTED: Added space after the ANSI code.
      print(
          '$_ansiRed Could not determine Flutter version. Error:\n${result.stderr}$_ansiReset');
    }
  } catch (e) {
    // CORRECTED: Added space after the ANSI code.
    print('$_ansiRed Error running "flutter --version": $e$_ansiReset');
  }
  print('$_ansiBold-----------------------$_ansiReset\n');
}

/// Manages the file watcher and the test execution state machine.
Future<void> _runWatchMode(List<String> initialArgs) async {
  var state = _WatchState.needsFullRun;
  final debouncer = _Debouncer(delay: const Duration(milliseconds: 350));
  late StreamSubscription<FileSystemEvent> watcherSubscription;

  Future<void> triggerTestRun() async {
    watcherSubscription.pause();
    stdout.write(_ansiClearScreen);

    var shouldContinueImmediateLoop = true;
    while (shouldContinueImmediateLoop) {
      shouldContinueImmediateLoop = false;
      bool success;

      switch (state) {
        case _WatchState.needsFullRun:
          print('$_ansiBold Running all tests...$_ansiReset');
          success = await _runSingleTest(initialArgs);

          if (success) {
            print(
                '\n$_ansiGreen$_ansiBold All tests passed! Watch mode complete. $_ansiReset');
            await watcherSubscription.cancel();
            debouncer.cancel();
            exit(0);
          } else {
            state = _WatchState.needsFailedRun;
            print(
                '\n$_ansiYellow$_ansiBold Failures detected. Will re-run failed tests on next change. $_ansiReset');
          }
          break;

        case _WatchState.needsFailedRun:
          print('$_ansiBold Rerunning failed tests...$_ansiReset');
          success = await _runSingleTest([...initialArgs, '--rerun-failed']);

          if (success) {
            state = _WatchState.needsFullRun;
            print(
                '\n$_ansiGreen$_ansiBold Previously failed tests passed. Performing final verification run...$_ansiReset');
            sleep(const Duration(seconds: 1));
            shouldContinueImmediateLoop = true;
          } else {
            print(
                '\n$_ansiYellow$_ansiBold Tests still failing. Waiting for next change. $_ansiReset');
          }
          break;
      }
    }

    print('\nWatching for file changes...');
    if (watcherSubscription.isPaused) {
      watcherSubscription.resume();
    }
  }

  final watcher = Directory(Directory.current.path).watch(recursive: true);
  watcherSubscription = watcher.listen(
    (event) {
      final path = event.path;
      final separator = Platform.pathSeparator;

      final isCacheFile = path.endsWith(_cacheFileName);
      final isDartToolFile = path.contains('$separator.dart_tool$separator');
      final isBuildFile = path.contains('${separator}build$separator');

      if (isCacheFile || isDartToolFile || isBuildFile) {
        return;
      }

      debouncer.call(triggerTestRun);
    },
    onError: (error) => print('$_ansiRed Watcher error: $error $_ansiReset'),
  );

  print('$_ansiBold Starting watch mode...$_ansiReset');
  await triggerTestRun();
}

/// Runs a single test process and returns true on success.
Future<bool> _runSingleTest(List<String> args) async {
  final passed = <String>[];
  final failed = <_Failure>[];
  final skipped = <String>[];
  final activeTests = <int, _TestInfo>{};
  final activeErrorPrints = <int, String>{};
  final errorLog = <String>[];

  final cacheData = _readCacheData();
  int totalTests = cacheData.totalTests;
  final lastRunDuration = cacheData.lastDuration;
  int? exitCode;

  final isDebugMode = args.contains('--debug');
  final isRerunFailed = args.contains('--rerun-failed');
  var filteredArgs =
      args.where((arg) => arg != '--debug' && arg != '--rerun-failed').toList();

  final stopwatch = Stopwatch()..start();

  if (isRerunFailed) {
    if (cacheData.failedTests.isEmpty) {
      print(
          '$_ansiYellow No failed tests found in the last run. Nothing to rerun. $_ansiReset');
      return true;
    }

    final failedTestsByFile = <String, List<String>>{};
    for (final failure in cacheData.failedTests) {
      if (failure.info.url != null) {
        try {
          final filePath = Uri.parse(failure.info.url!).toFilePath();
          (failedTestsByFile[filePath] ??= []).add(failure.info.name);
        } catch (e) {/* Ignore */}
      }
    }

    if (failedTestsByFile.isEmpty) {
      print(
          '$_ansiRed Could not find file paths for any failed tests. Cannot rerun. $_ansiReset');
      return false;
    }

    final filePathsToRun = failedTestsByFile.keys.toList();
    final allFailedNames =
        cacheData.failedTests.map((t) => RegExp.escape(t.info.name)).join('|');
    final regex = '^($allFailedNames)\$';
    filteredArgs = [...filePathsToRun, '--name', regex];
    totalTests = cacheData.failedTests.length;
    print(
        '$_ansiYellow Rerunning ${cacheData.failedTests.length} failed tests across ${filePathsToRun.length} files...$_ansiReset');
  }

  if (!isDebugMode) {
    stdout.write(_ansiHideCursor);
    stdout.write('\n\n');
  }

  try {
    final process = await Process.start(
      'flutter',
      ['test', '--machine', ...filteredArgs],
      workingDirectory: Directory.current.path,
      runInShell: Platform.isWindows ? false : true,
    );

    final processExitCode = process.exitCode;

    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((errorLine) {
      if (isDebugMode) {
        print('$_ansiRed[FLUTTER TEST ERROR] $errorLine$_ansiReset');
      } else {
        errorLog.add(errorLine);
      }
    });

    int newTotalTests = 0;
    await for (final line in process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      try {
        final json = jsonDecode(line) as Map<String, dynamic>;
        if (isDebugMode) {
          print('[DEBUG]\n${JsonEncoder.withIndent('  ').convert(json)}');
        }

        final type = json['type'] as String?;

        if (type == 'group') {
          final group = json['group'] as Map<String, dynamic>;
          if (group['parentID'] == null) {
            newTotalTests += (group['testCount'] as int?) ?? 0;
          }
        } else if (type == 'testStart') {
          final test = json['test'] as Map<String, dynamic>;
          final id = test['id'] as int;
          activeTests[id] = _TestInfo.fromJson(test);
        } else if (type == 'testDone') {
          final testID = json['testID'] as int;
          final result = json['result'] as String;
          final hidden = json['hidden'] as bool? ?? false;
          final isSkipped = json['skipped'] as bool? ?? false;
          final testInfo = activeTests[testID];
          if (testInfo == null || hidden) continue;

          if (isSkipped) {
            skipped.add(testInfo.name);
          } else {
            switch (result) {
              case 'success':
                passed.add(testInfo.name);
                break;
              case 'failure':
              case 'error':
                final errorLog = activeErrorPrints[testID] ??
                    'Unknown error: No exception log was captured.';
                failed.add(_Failure(testInfo, errorLog));
                break;
            }
          }
          activeTests.remove(testID);
          activeErrorPrints.remove(testID);
        } else if (type == 'print') {
          final testID = json['testID'] as int;
          final message = json['message'] as String;

          if (message.startsWith('══╡ EXCEPTION CAUGHT') &&
              !activeErrorPrints.containsKey(testID)) {
            activeErrorPrints[testID] = message;
          }
        }

        if (!isDebugMode) {
          _updateDisplay(passed.length, failed.length, skipped.length,
              totalTests, stopwatch.elapsed, lastRunDuration);
        }
      } catch (e) {/* Ignore JSON parse errors */}
    }
    exitCode = await processExitCode;
    stopwatch.stop();

    if (!isRerunFailed) {
      if (newTotalTests > 0) totalTests = newTotalTests;
      _writeCacheData(totalTests, stopwatch.elapsed, failed);
    }
  } finally {
    if (!isDebugMode) {
      stdout.write('$_ansiCursorUp2\r$_ansiClearLine\n\r$_ansiClearLine');
    }
    stdout.write(_ansiShowCursor);
  }

  if (exitCode != 0 && passed.isEmpty && failed.isEmpty && skipped.isEmpty) {
    _writeScreenFullLine(addNewLine: true);
    print(
        '$_ansiBold$_ansiRed Test runner failed to start or crashed. $_ansiReset');
    print('The command exited with code $exitCode before running any tests.');
    if (errorLog.isNotEmpty) {
      print('\n$_ansiBold$_ansiRed Error Output:$_ansiReset');
      errorLog.forEach(print);
    } else {
      print('\nPossible reasons:');
      print(' - A problem with your project\'s dependencies or test setup.');
      print(' - No "test" directory found in the current folder.');
    }
    _writeScreenFullLine();
    return false;
  }

  _writeScreenFullLine(addNewLine: true);
  print('$_ansiBold Test Run Summary $_ansiReset');
  _writeScreenFullLine();

  if (failed.isNotEmpty) {
    print('\n$_ansiBold$_ansiRed FAILED TESTS: $_ansiReset\n');
    for (final failure in failed) {
      final fileName = failure.info.url != null
          ? Uri.parse(failure.info.url!).pathSegments.last
          : 'Unknown File';
      final testName = failure.info.name;

      print('$_ansiRed[FAIL] $fileName: $testName$_ansiReset');

      final primaryError = _extractPrimaryError(failure.fullErrorLog);

      print('\n══╡ EXCEPTION CAUGHT BY FLUTTER TEST FRAMEWORK ╞══════════');
      print('$_ansiBold$primaryError$_ansiReset');
      print('════════════════════════════════════════════════════════════');

      if (failure.info.url != null) {
        try {
          String filePath = Uri.parse(failure.info.url!).toFilePath();
          final currentPath = Directory.current.path;
          if (filePath.startsWith(currentPath)) {
            filePath = filePath.substring(currentPath.length + 1);
          }

          final rerunCommand =
              "test_laser '$filePath' --plain-name '${failure.info.name}'";
          print('\n  To run this test again:');
          print('  $_ansiYellow$rerunCommand$_ansiReset');
        } catch (e) {/* Ignore */}
      }
      print('');
    }
  }

  final summary = '$_ansiGreen${passed.length} passed$_ansiReset, '
      '$_ansiRed${failed.length} failed$_ansiReset, '
      '$_ansiYellow${skipped.length} skipped$_ansiReset, '
      'Total: $totalTests, Duration: ${_formatDuration(stopwatch.elapsed)}';
  print(summary);
  _writeScreenFullLine();

  if (failed.isNotEmpty) {
    print(
        'To rerun only the failed tests, use: $_ansiYellow`test_laser --rerun-failed`$_ansiReset');
    _writeScreenFullLine();
  }

  return failed.isEmpty;
}

String _extractPrimaryError(String log) {
  final lines = log.split('\n');

  var startIndex = lines.indexWhere((line) => line.contains('was thrown'));
  if (startIndex == -1) return log;

  startIndex++;

  var endIndex = lines.indexWhere(
      (line) =>
          line.isEmpty || line.startsWith('When the exception was thrown'),
      startIndex);
  if (endIndex == -1) endIndex = lines.length;

  return lines.sublist(startIndex, endIndex).join('\n').trim();
}

void _updateDisplay(int passed, int failed, int skipped, int total,
    Duration elapsed, Duration lastDuration) {
  final completed = passed + failed + skipped;
  final progress = min(1, total == 0 ? 0.0 : completed / total);
  final timeText =
      'Time: ${_formatDuration(elapsed)} / ${_formatDuration(lastDuration)}';
  final statusText = 'Passed: $_ansiGreen$passed$_ansiReset, '
      'Failed: $_ansiRed$failed$_ansiReset, '
      'Skipped: $_ansiYellow$skipped$_ansiReset, '
      'Total: $total | $timeText';
  final terminalWidth = stdout.hasTerminal ? stdout.terminalColumns : 80;
  final progressBarWidth = terminalWidth - 7;
  final filledWidth = (progressBarWidth * progress).round();
  final emptyWidth = progressBarWidth - filledWidth;
  final filledBar = '█' * filledWidth;
  final emptyBar = ' ' * emptyWidth;
  final percentage = (progress * 100).toStringAsFixed(0);
  final progressBar =
      '[$_ansiGreen$filledBar$_ansiReset$emptyBar] $percentage%';

  stdout.write(_ansiCursorUp1);
  stdout.writeln('\r$_ansiClearLine$statusText');
  stdout.write('\r$_ansiClearLine$progressBar');
}

void _writeScreenFullLine({bool addNewLine = false}) {
  final terminalWidth = stdout.hasTerminal ? stdout.terminalColumns : 80;
  String line = '─' * terminalWidth;
  if (addNewLine) line = '\n$line';
  print(line);
}

class _TestInfo {
  final int id;
  final String name;
  final String? url;
  _TestInfo(this.id, this.name, this.url);
  factory _TestInfo.fromJson(Map<String, dynamic> json) {
    final url = json['root_url'] as String? ?? json['url'] as String?;
    return _TestInfo(
      json['id'] as int,
      json['name'] as String,
      url,
    );
  }
}

class _Failure {
  final _TestInfo info;
  String fullErrorLog;
  _Failure(this.info, this.fullErrorLog);

  Map<String, dynamic> toJson() => {
        'name': info.name,
        'url': info.url,
      };
}

class _CacheData {
  final int totalTests;
  final Duration lastDuration;
  final List<_Failure> failedTests;
  _CacheData(this.totalTests, this.lastDuration, this.failedTests);
}

_CacheData _readCacheData() {
  try {
    final cacheFile = File('${Directory.current.path}/$_cacheFileName');
    if (cacheFile.existsSync()) {
      final json =
          jsonDecode(cacheFile.readAsStringSync()) as Map<String, dynamic>;
      final totalTests = json['totalTests'] as int? ?? 0;
      final lastSeconds = json['lastDurationInSeconds'] as int? ?? 0;
      final failedTests = (json['failedTests'] as List<dynamic>?)
              ?.map((e) => _Failure(
                  _TestInfo(-1, e['name'] as String, e['url'] as String?), ''))
              .toList() ??
          [];
      return _CacheData(
          totalTests, Duration(seconds: lastSeconds), failedTests);
    }
  } catch (e) {
    // Ignore errors and return default.
  }
  return _CacheData(0, Duration.zero, []);
}

void _writeCacheData(int total, Duration duration, List<_Failure> failures) {
  try {
    final cacheFile = File('${Directory.current.path}/$_cacheFileName');
    final data = {
      'totalTests': total,
      'lastDurationInSeconds': duration.inSeconds,
      'failedTests': failures.map((f) => f.toJson()).toList(),
    };
    cacheFile.writeAsStringSync(jsonEncode(data));
  } catch (e) {
    // If we can't write the cache file, it's not a critical error.
  }
}

String _formatDuration(Duration d) {
  final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}
