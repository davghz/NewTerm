# Physical terminal QA

This fixture measures the installed terminal through its own interactive shell. The signed XCTest runner accepts the isolated bundle identifiers `com.davghz.t3rm.baseline` and `com.davghz.t3rm.review`. Each run opens a fresh instance of the selected test app, enters the Python command through its keyboard input, and waits for the fixture to signal completion. Test screenshots and the XCTest log are stored in the result bundle.

The fixture runs on a paired device with a shell, Python 3 and the two isolated QA packages installed. The host uses Xcode, XcodeGen, Apple development signing and a working SSH connection as the shell user. Build the test runner in a temporary copy of this directory.

```sh
xcodegen generate
xcodebuild -project TerminalDeviceQA.xcodeproj -scheme TerminalDeviceQA \
  -destination "id=$QA_DEVICE" -derivedDataPath "$QA_BUILD" \
  DEVELOPMENT_TEAM="$QA_TEAM" -parallel-testing-enabled NO build-for-testing
```

Install `replay.py` into the QA user's scratch directory through the existing connection.

```sh
ssh -S "$QA_SOCKET" "$QA_SSH_HOST" \
  'umask 077; mkdir -p /var/mobile/Library/Caches/t3rm-rewrite-qa && cd /var/mobile/Library/Caches/t3rm-rewrite-qa && cat > replay.tmp && mv replay.tmp replay.py' < replay.py
```

Set `QA_TESTRUN` to the generated `.xctestrun` file under `$QA_BUILD/Build/Products`. Use a fresh tag for every recording. A single-case run accepts `--case history_styled`, for example.

```sh
python3 profile_suite.py "$QA_TESTRUN" "$QA_DEVICE" baseline baseline01 "$QA_EVIDENCE" \
  --ssh-socket "$QA_SOCKET" --ssh-host "$QA_SSH_HOST"
python3 profile_suite.py "$QA_TESTRUN" "$QA_DEVICE" review review01 "$QA_EVIDENCE" \
  --ssh-socket "$QA_SOCKET" --ssh-host "$QA_SSH_HOST"
```

## Measurements

Each suite processes 41 deterministic frames for each of six combinations of sparse updates, styled rows and dense bursts, with zero or 10,000 rows of primary-screen prefill. A frame ends with an ANSI cursor-position query. The fixture records the time from the first PTY write through reception of the expected cursor row and column. It sets a minimum 60 ms period between frame starts. The JSON includes every sample, the median, nearest-rank p95, prefill time and the actual PTY dimensions. Workloads use up to 46 columns and 24 rows. Physical display presentation time is outside this measurement.

The host starts one Instruments Time Profiler recording per case. The fixture waits for the host to release the workload and records the originating terminal app's CPU time, resident memory, physical footprint and system thermal state throughout its measured frames. CPU percentage uses one fully occupied core as 100%. Trace startup and history prefill are outside the reported frame samples. The Time Profiler log records device-discovery failures; a successful trace can be inspected with `xcrun xctrace export --input … --toc`.

For a real-device editing check, copy `cli_probe.py` beside `replay.py` and run the signed test in `editing` mode against the review app. It creates a fresh working directory and home for the CLI, types into the device's vi, saves the file, and opens OpenCode through the ordinary interactive shell. The test types and erases an unsent draft, opens the model picker with the local /models command, dismisses it, and captures terminal transcripts and screenshots.

```sh
python3 run_ui.py "$QA_TESTRUN" "$QA_DEVICE" review editing edit01 "$QA_EVIDENCE"
python3 compare.py "$QA_EVIDENCE" baseline01 review01 > "$QA_EVIDENCE/comparison.csv"
```
