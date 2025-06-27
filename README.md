# Test Laser ⚡️

A beautiful and informative command-line test runner for Flutter that makes your test output clean, readable, and actionable.

## What is Test Laser?

The default `flutter test` command is powerful, but its output can be hard to read, especially in large projects. When tests fail, you have to scroll through hundreds of lines to find the error details.

**Test Laser** wraps the standard test runner and transforms its output into a user-friendly experience with a live progress bar, detailed summaries, and actionable failure reports.

## Example

![Demo of Test Laser in action](https://raw.githubusercontent.com/bassiuz/test_laser/main/assets/example.gif)

## Features

* **Clean Sticky Footer**: A live-updating footer shows a progress bar, test counts, and elapsed time without spamming your console.

* **Detailed Failure Reports**: Failures are summarized at the end with the "Expected vs. Actual" output, making it easy to see what went wrong.

* **Rerun Individual Tests**: Each failed test summary includes a copy-pasteable command to rerun only that specific test.

* **Rerun All Failed Tests**: Use the `--rerun-failed` flag to instantly run all the tests that failed in the last session.

* **Time Tracking & Caching**: The runner caches the total number of tests and the duration of the last run, giving you an immediate and accurate progress estimate on subsequent runs.

* **FVM Aware**: Automatically uses the project-specific Flutter version managed by FVM.

## Demo Output

Here is what you can expect to see in your terminal.

#### While Running

A clean, two-line sticky footer keeps you updated without clutter.

```
Passed: 124, Failed: 0, Skipped: 2, Total: 215 | Time: 00:45 / 01:12
[██████████████████████████████████████████████████████████████▍          ] 58%
```

#### Final Summary with Failures

A clear, actionable report shows you exactly what to fix.

```
--------------------------------------------------
 Test Run Summary 
--------------------------------------------------

 FAILED TESTS: 

[test_service_test.dart] Always fails
  Expected: <false>
    Actual: <true>
  This test always fails
  

  To run this test again:
  test_laser '/xxx/test_service_test.dart' --plain-name 'Always fails'


44 passed, 1 failed, 2 skipped, Total: 47, Duration: 00:08
--------------------------------------------------
To rerun only the failed tests, use: `test_laser --rerun-failed`
--------------------------------------------------
```

## Installation

Activate `test_laser` globally from `pub.dev`.

```
dart pub global activate test_laser
```

Make sure that your system's PATH includes the pub cache bin directory.

* On macOS/Linux: `export PATH="$PATH":"$HOME/.pub-cache/bin"`

* If you use FVM: `export PATH="$PATH":"$HOME/fvm/default/bin"`

Add the appropriate line to your `~/.zshrc`, `~/.bashrc`, or other shell configuration file.

## Usage

Navigate to any Flutter project directory and run the command:

```
test_laser
```

### Rerun Only Failed Tests

To save time, you can instantly rerun only the tests that failed in the last session.

```
test_laser --rerun-failed
```

### Run a Specific File or Test

You can pass arguments just like you would to `flutter test`.

```
# Run all tests in a specific file
test_laser test/my_feature/my_feature_test.dart

# Run a single test by its name
test_laser --plain-name 'MyWidget should display an error'
```

### Debug Mode

To see the raw JSON output from the test runner for debugging purposes, use the `--debug` flag.

```
test_laser --debug
```

## Contributing

Contributions are welcome! If you find a bug or have a feature request, please open an issue on the GitHub repository.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.