#!/usr/bin/env python3
"""Build and run every XCTest, retaining kernel caches within bounded worker processes."""

import argparse
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
import json
import fcntl
import math
import signal
import threading
import os
from pathlib import Path
import re
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parents[1]
# This pipeline already runs alone in CI because concurrent Metal compilation can exhaust
# a hosted runner. It remains a required test and is included in the coverage audit below.
EXCLUSIVE = {
    "FotufilmCoreTests.PipelineStageMetalTests/"
    "testResolvedSilverDiscsMatchCPUAndChangeWithTheSeed",
}
IDENTIFIER = re.compile(r"[\w.]+/\w+\Z")
MAC_RESULT = re.compile(
    r"Test Case '-\[([\w.]+) (\w+)\]' (passed|failed|skipped) \(([\d.]+) seconds\)\.")
LINUX_RESULT = re.compile(
    r"Test Case '([\w.]+)\.(\w+)' (passed|failed|skipped) \(([\d.]+) seconds\)\.")


def discover(output):
    tests = [line.strip() for line in output.splitlines() if line.strip()]
    if not tests or any(not IDENTIFIER.fullmatch(test) for test in tests):
        raise ValueError("Expected a nonempty XCTest method list; unsupported discovery output")
    if len(set(tests)) != len(tests):
        raise ValueError("Test discovery returned duplicate methods")
    return sorted(tests)


def partition(tests, workers, durations):
    """Share ordinary fixtures, but spread long, self-contained frame benchmarks."""
    classes = defaultdict(list)
    for test in tests:
        name = test.split("/", 1)[0]
        classes[test if "PerformanceTests" in name else name].append(test)
    weights = {name: sum(durations.get(test, 1.0) for test in methods)
               for name, methods in classes.items()}
    groups = [[] for _ in range(min(workers, len(classes)))]
    loads = [0.0] * len(groups)
    for name in sorted(classes, key=lambda name: (-weights[name], name)):
        index = min(range(len(groups)), key=lambda i: (loads[i], i))
        groups[index].extend(classes[name])
        loads[index] += weights[name]
    return [sorted(group) for group in groups]


def results_from_log(output, tests):
    results = []
    for match in (MAC_RESULT if sys.platform == "darwin" else LINUX_RESULT).finditer(output):
        name, method, status, seconds = match.groups()
        identifier = name + "/" + method
        # swift-corelibs-xctest may omit the module from its textual case names.
        if identifier not in tests and sys.platform != "darwin":
            candidates = [test for test in tests if test.endswith("." + identifier)]
            if len(candidates) == 1:
                identifier = candidates[0]
        results.append({"test": identifier, "status": status, "seconds": float(seconds)})
    return results


def audit(tests, results):
    expected = Counter(tests)
    actual = Counter(result["test"] for result in results)
    problems = []
    if expected != actual:
        missing = list((expected - actual).elements())
        unexpected = list((actual - expected).elements())
        problems.append(f"Incomplete test execution: missing={missing}, unexpected={unexpected}")
    failed = [result["test"] for result in results if result["status"] == "failed"]
    if failed:
        problems.append(f"Failed tests: {failed}")
    return problems


RUNNING = set()
RUNNING_LOCK = threading.Lock()
STOPPING = threading.Event()


def stop_process(process):
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
    except ProcessLookupError:
        pass


def interrupt(signum, _frame):
    STOPPING.set()
    with RUNNING_LOCK:
        active = list(RUNNING)
    for process in active:
        stop_process(process)
    raise SystemExit(128 + signum)


def timing_history(path):
    if not path.exists():
        return {}
    try:
        previous = json.loads(path.read_text())
        durations = {}
        for worker in previous['workers']:
            for result in worker['results']:
                seconds = float(result['seconds'])
                if math.isfinite(seconds) and seconds >= 0:
                    durations[result['test']] = seconds
        return durations
    except (ValueError, KeyError, TypeError, OSError):
        print('Ignoring unreadable timing history; all tests will still run.', flush=True)
        return {}


def run_group(index, tests, runner, bundle, directory, timeout):
    command = ([runner, "-XCTest", ",".join(tests), str(bundle)]
               if sys.platform == "darwin" else [str(bundle), ",".join(tests)])
    log = directory / f"worker-{index}.log"
    start = time.monotonic()
    with log.open("w") as output:
        process = None
        try:
            if STOPPING.is_set():
                raise OSError('Test run was interrupted')
            process = subprocess.Popen(command, cwd=ROOT, stdout=output,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            with RUNNING_LOCK:
                RUNNING.add(process)
            if STOPPING.is_set():
                stop_process(process)
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            stop_process(process)
            code = 124
            output.write(f"\nWorker exceeded {timeout} seconds.\n")
        except OSError as error:
            code = 127
            output.write(f"\nCould not run worker: {error}\n")
        finally:
            if process is not None:
                with RUNNING_LOCK:
                    RUNNING.discard(process)
    seconds = time.monotonic() - start
    results = results_from_log(log.read_text(errors="replace"), tests)
    problems = audit(tests, results)
    if code:
        problems.append(f"Worker {index} exited {code}; see {log}")
    print(f"Worker {index}: {len(results)}/{len(tests)} tests, {seconds:.2f}s, "
          f"{'FAIL' if problems else 'OK'}", flush=True)
    return {"worker": index, "seconds": seconds, "exit_code": code,
            "results": results, "problems": problems}


def positive_int(value):
    number = int(value)
    if number <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return number


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workers", type=positive_int, default=min(8, os.cpu_count() or 1))
    parser.add_argument("--scratch-path", type=Path)
    parser.add_argument("--output", type=Path, default=ROOT / "build/engine-tests")
    parser.add_argument("--timings", type=Path,
                        help="Previous report to balance workers (default: last report in --output)")
    parser.add_argument("--timeout", type=positive_int, default=3600,
                        help="Maximum seconds per worker (default: 3600)")
    args = parser.parse_args()
    start = time.monotonic()
    if sys.platform == "darwin":
        # Apple's /usr/bin/python3 can inject the Command Line Tools SDK into its children.
        # Tests are host executables: use the SDK from the selected Xcode for SwiftPM too.
        os.environ["SDKROOT"] = subprocess.check_output(
            ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    directory = args.output.resolve()
    directory.mkdir(parents=True, exist_ok=True)
    # One output directory owns one report and worker-log set. Concurrent invocations wait,
    # so a second test run cannot overwrite the evidence used by the first coverage audit.
    run_lock = (directory / '.runner.lock').open('a')
    try:
        fcntl.flock(run_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print('Another test run is using this output directory; waiting…', flush=True)
        fcntl.flock(run_lock, fcntl.LOCK_EX)
    scratch = args.scratch_path or ROOT / ".build"
    os.environ.setdefault('FOTUFILM_COMPILED_CACHE_DIRECTORY',
                          str(scratch.resolve() / 'compiled-kernels'))
    swift = ["swift", "--package-path", str(ROOT), "--scratch-path",
             str(scratch.resolve()), "-c", "release"]
    def swift_command(verb, *options, **kwargs):
        return subprocess.run([swift[0], verb, *swift[1:], *options],
                              cwd=ROOT, check=True, **kwargs)

    print("Building the complete release test bundle…", flush=True)
    # `swift test` enables testable imports in release dependencies; `swift build
    # --build-tests` alone does not. Listing builds the same bundle as the standard suite.
    listing = swift_command("test", "list", stdout=subprocess.PIPE, text=True).stdout
    build_seconds = time.monotonic() - start
    tests = discover(listing)
    bin_path = Path(swift_command("build", "--show-bin-path",
                                 capture_output=True, text=True).stdout.strip())
    bundle = bin_path / "FotufilmPackageTests.xctest"
    if not bundle.exists():
        raise ValueError(f"Missing built test bundle: {bundle}")
    runner = (subprocess.check_output(["xcrun", "--find", "xctest"], text=True).strip()
              if sys.platform == "darwin" else None)
    durations = timing_history(args.timings or directory / "report.json")
    exclusive = sorted(set(tests) & EXCLUSIVE)
    groups = partition([test for test in tests if test not in EXCLUSIVE], args.workers, durations)
    print(f"Discovered {len(tests)} tests: {len(exclusive)} exclusive, "
          f"{len(groups)} workers. Logs: {directory}", flush=True)
    workers = []
    if exclusive:
        workers.append(run_group(0, exclusive, runner, bundle, directory, args.timeout))
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        pending = [pool.submit(run_group, index, group, runner, bundle, directory, args.timeout)
                   for index, group in enumerate(groups, 1)]
        for future in as_completed(pending):
            workers.append(future.result())
    workers.sort(key=lambda worker: worker["worker"])
    results = [result for worker in workers for result in worker["results"]]
    problems = audit(tests, results) + [problem for worker in workers
                                      for problem in worker["problems"]]
    report = {"build_seconds": build_seconds, "total_seconds": time.monotonic() - start,
              "discovered": len(tests), "executed": len(results),
              "skipped": sum(result["status"] == "skipped" for result in results),
              "workers": workers, "problems": problems}
    staged_report = directory / "report.json.pending"
    staged_report.write_text(json.dumps(report, indent=2) + "\n")
    staged_report.replace(directory / "report.json")
    print(f"{len(results)}/{len(tests)} tests, {report['skipped']} skipped, "
          f"{build_seconds:.2f}s build, {report['total_seconds']:.2f}s total.")
    for problem in problems:
        print(problem, file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    signal.signal(signal.SIGINT, interrupt)
    signal.signal(signal.SIGTERM, interrupt)
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
