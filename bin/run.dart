import 'dart:convert';
import 'dart:io';

// ANSI escape codes for cursor control and text styling.
const String _ansiRed = '\u001b[31m';
const String _ansiGreen = '\u001b[32m';
const String _ansiYellow = '\u001b[33m';
const String _ansiBold = '\u001b[1m';
const String _ansiReset = '\u001b[0m';
const String _ansiHideCursor = '\u001b[?25l';
const String _ansiShowCursor = '\u001b[?25h';
const String _ansiClearLine = '\u001b[K';
const String _ansiCursorUp2 = '\u001b[2A';
const String _ansiCursorUp1 = '\u001b[1A';

// The name of the file used to cache run data.
const String _cacheFileName = '.test_laser.cache';

void main(List<String> args) async {
  // --- State Variables ---
  final passed = <String>[];
  final failed = <_Failure>[];
  final skipped = <String>[];
  final activeTests = <int, _TestInfo>{};
  final errorDetails = <int, String>{};
  final stackTraces = <int, String>{};
  final errorLog = <String>[]; // Buffer for stderr messages

  final cacheData = _readCacheData();
  int totalTests = cacheData.totalTests;
  final lastRunDuration = cacheData.lastDuration;

  int? exitCode;

  final isDebugMode = args.contains('--debug');
  final isRerunFailed = args.contains('--rerun-failed');
  var filteredArgs =
      args.where((arg) => arg != '--debug' && arg != '--rerun-failed').toList();

  // Start a stopwatch to time the current run.
  final stopwatch = Stopwatch()..start();

  // If --rerun-failed is used, construct a new set of arguments.
  if (isRerunFailed) {
    if (cacheData.failedTests.isEmpty) {
      print('$_ansiYellow'
          'No failed tests found in the last run. Nothing to rerun.'
          '$_ansiReset');
      exit(0);
    }

    // Group failed tests by file path to make the rerun much faster.
    final failedTestsByFile = <String, List<String>>{};
    for (final failure in cacheData.failedTests) {
      if (failure.info.url != null) {
        try {
          final filePath = Uri.parse(failure.info.url!).toFilePath();
          (failedTestsByFile[filePath] ??= []).add(failure.info.name);
        } catch (e) {
          // Ignore malformed URIs
        }
      }
    }

    if (failedTestsByFile.isEmpty) {
      print('$_ansiRed'
          'Could not find file paths for any failed tests. Cannot rerun.'
          '$_ansiReset');
      exit(1);
    }

    // Get the unique file paths to test.
    final filePathsToRun = failedTestsByFile.keys.toList();

    // Create a single regex to match all failed test names within those files.
    final allFailedNames =
        cacheData.failedTests.map((t) => RegExp.escape(t.info.name)).join('|');
    final regex = '^($allFailedNames)\$';

    // The arguments will be the file paths, followed by the --name flag.
    filteredArgs = [...filePathsToRun, '--name', regex];

    totalTests = cacheData.failedTests.length;
    print('$_ansiYellow'
        'Rerunning ${cacheData.failedTests.length} failed tests across ${filePathsToRun.length} files...'
        '$_ansiReset');
  }

  // In normal mode, hide the cursor and reserve space for the sticky footer.
  if (!isDebugMode) {
    stdout.write(_ansiHideCursor);
    stdout.write('\n\n');
  }

  try {
    // We now directly execute 'fvm flutter test' and rely on it to work.
    final process = await Process.start(
      'fvm',
      ['flutter', 'test', '--machine', ...filteredArgs],
      workingDirectory: Directory.current.path,
      runInShell: Platform.isWindows ? false : true,
    );

    final processExitCode = process.exitCode;

    // In normal mode, collect errors to print at the end. In debug, print immediately.
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
    // Decode the JSON output from the test process line by line.
    await for (final line in process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      try {
        final json = jsonDecode(line) as Map<String, dynamic>;

        if (isDebugMode) {
          const encoder = JsonEncoder.withIndent('  ');
          final formattedJson = encoder.convert(json);
          print('[DEBUG]\n$formattedJson');
        }

        final type = json['type'] as String?;

        if (type == 'group') {
          // Only count top-level groups to avoid double-counting.
          final group = json['group'] as Map<String, dynamic>;
          if (group['parentID'] == null) {
            newTotalTests += (group['testCount'] as int?) ?? 0;
          }
        } else if (type == 'testStart') {
          // When a test starts, save its info.
          final test = json['test'] as Map<String, dynamic>;
          final id = test['id'] as int;
          activeTests[id] = _TestInfo.fromJson(test);
        } else if (type == 'testDone') {
          final testID = json['testID'] as int;
          final result = json['result'] as String;
          final hidden = json['hidden'] as bool? ?? false;
          final isSkipped = json['skipped'] as bool? ?? false;

          final testInfo = activeTests[testID];
          if (testInfo == null) continue;

          // Ignore hidden setup/teardown tests for pass/fail counting.
          if (hidden) {
            activeTests.remove(testID);
            continue;
          }

          if (isSkipped) {
            skipped.add(testInfo.name);
          } else {
            switch (result) {
              case 'success':
                passed.add(testInfo.name);
                break;
              case 'failure':
              case 'error':
                // When a test fails, pull its stored error details.
                final error = errorDetails[testID] ?? 'Unknown error';
                final stackTrace =
                    stackTraces[testID] ?? 'No stack trace available';
                failed.add(_Failure(testInfo, error, stackTrace));
                break;
            }
          }
          // Clean up stored info for the completed test.
          activeTests.remove(testID);
          errorDetails.remove(testID);
          stackTraces.remove(testID);
        } else if (type == 'error') {
          final testID = json['testID'] as int;
          // Store error details when they arrive. They come before 'testDone'.
          errorDetails[testID] = json['error'] as String;
          stackTraces[testID] = json['stackTrace'] as String;
        }

        if (!isDebugMode) {
          _updateDisplay(passed.length, failed.length, skipped.length,
              totalTests, stopwatch.elapsed, lastRunDuration);
        }
      } catch (e) {
        // Ignore lines that aren't valid JSON.
      }
    }
    exitCode = await processExitCode;
    stopwatch.stop();

    // Only update the cache if this was a full run, not a rerun of failed tests.
    if (!isRerunFailed) {
      if (newTotalTests > 0) {
        totalTests = newTotalTests;
      }
      _writeCacheData(totalTests, stopwatch.elapsed, failed);
    }
  } finally {
    if (!isDebugMode) {
      // Clear the sticky lines before printing the final summary.
      stdout.write('$_ansiCursorUp2\r$_ansiClearLine\n\r$_ansiClearLine');
    }
    stdout.write(_ansiShowCursor);
  }

  // UPDATED: More specific error reporting.
  if (exitCode != 0 && passed.isEmpty && failed.isEmpty && skipped.isEmpty) {
    print('\n--------------------------------------------------');
    print(
        '$_ansiBold$_ansiRed Test runner failed to start or crashed. $_ansiReset');
    print('The command exited with code $exitCode before running any tests.');

    // If we captured specific errors, show them instead of a generic message.
    if (errorLog.isNotEmpty) {
      // CORRECTED: The typo `_ansiRedError` has been fixed.
      print('\n$_ansiBold$_ansiRed' 'Error Output:$_ansiReset');
      for (final error in errorLog) {
        print(error);
      }
    } else {
      print('\nPossible reasons:');
      print(' - A problem with the project\'s dependencies or test setup.');
      print(' - No "test" directory found in the current folder.');
    }
    print('--------------------------------------------------');
    exit(1);
  }

  print('\n--------------------------------------------------');
  print('$_ansiBold Test Run Summary $_ansiReset');
  print('--------------------------------------------------');

  if (failed.isNotEmpty) {
    print('\n$_ansiBold$_ansiRed FAILED TESTS: $_ansiReset\n');
    for (final failure in failed) {
      // Extract filename from URL for a cleaner header.
      final fileName = failure.info.url != null
          ? Uri.parse(failure.info.url!).pathSegments.last
          : 'Unknown File';

      // The test name from the runner might be "group, test name".
      // We take the last part for a cleaner name.
      final testName = failure.info.name.split(',').last.trim();

      print('$_ansiRed[${fileName}] ${testName}$_ansiReset');
      // Indent the error message for readability.
      print('  ${failure.error.replaceAll('\n', '\n  ')}');

      // Construct and print the rerun command if the test file path is available.
      if (failure.info.url != null) {
        try {
          final filePath = Uri.parse(failure.info.url!).toFilePath();
          // Use the full name from the runner for the --plain-name flag to be precise.
          final rerunCommand =
              "test_laser '$filePath' --plain-name '${failure.info.name}'";
          print('\n  To run this test again:');
          print('  $_ansiYellow$rerunCommand$_ansiReset');
        } catch (e) {
          // Ignore potential URI parsing errors
        }
      }
      print(''); // blank line for spacing
    }
  }

  final summary = '$_ansiGreen${passed.length} passed$_ansiReset, '
      '$_ansiRed${failed.length} failed$_ansiReset, '
      '$_ansiYellow${skipped.length} skipped$_ansiReset, '
      'Total: $totalTests, Duration: ${_formatDuration(stopwatch.elapsed)}';

  print(summary);
  print('--------------------------------------------------');

  if (failed.isNotEmpty) {
    print(
        'To rerun only the failed tests, use: $_ansiYellow`test_laser --rerun-failed`$_ansiReset');
    print('--------------------------------------------------');
  }

  exit(failed.isEmpty ? 0 : 1);
}

/// Redraws the sticky footer with the current test status and progress bar.
void _updateDisplay(int passed, int failed, int skipped, int total,
    Duration elapsed, Duration lastDuration) {
  final completed = passed + failed + skipped;
  final progress = total == 0 ? 0.0 : completed / total;

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

  // UPDATED: Move cursor up 2 lines, then write the status and progress bar
  // on separate lines.
  stdout.write(_ansiCursorUp1);
  stdout.writeln('\r$_ansiClearLine$statusText');
  stdout.write('\r$_ansiClearLine$progressBar');
}

/// A utility function that prints a message to the console, ensuring the line
/// is cleared first. Behaves like `print()` by adding a newline.
void _print(String message, {IOSink? to}) {
  final sink = to ?? stdout;
  // Move cursor up to clear the sticky lines, print the message, then redraw.
  stdout.write('$_ansiCursorUp2\r$_ansiClearLine\n\r$_ansiClearLine');
  sink.writeln(message);
}

/// A simple class to hold details of a running test.
class _TestInfo {
  final int id;
  final String name;
  final String? url;

  _TestInfo(this.id, this.name, this.url);

  factory _TestInfo.fromJson(Map<String, dynamic> json) {
    return _TestInfo(
      json['id'] as int,
      json['name'] as String,
      json['url'] as String?,
    );
  }
}

/// A simple class to hold the details of a failed test.
class _Failure {
  final _TestInfo info;
  String error;
  String stackTrace;

  _Failure(this.info, this.error, this.stackTrace);

  Map<String, dynamic> toJson() => {
        'name': info.name,
        'url': info.url,
      };
}

/// A class to hold the cached data.
class _CacheData {
  final int totalTests;
  final Duration lastDuration;
  final List<_Failure> failedTests;
  _CacheData(this.totalTests, this.lastDuration, this.failedTests);
}

/// Reads the cached data from a file in the current directory.
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
                  _TestInfo(-1, e['name'] as String, e['url'] as String?),
                  '',
                  ''))
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

/// Writes the total test count, duration, and failed tests to a cache file.
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
    // We can just ignore it and proceed.
  }
}

/// Formats a Duration into a MM:SS string.
String _formatDuration(Duration d) {
  final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}
