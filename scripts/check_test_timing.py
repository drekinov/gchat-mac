#!/usr/bin/env python3
"""Keeps real time and stray tasks out of the tests.

  check_test_timing.py                 check the tree, honouring scripts/timing-allowlist.txt
  check_test_timing.py --strict FILE…  check these files with no allowlist
  check_test_timing.py --self-test     prove each rule catches what it should

Rules
  real-time    Tests may not sleep, poll a wall clock or schedule a timer. Only the helper files named in the
               allowlist may.
  session-task Sources/ChatSync creates unstructured tasks only where the allowlist says, so session work can be
               given an executor.
  sim-rig      A test file that uses SimWorld creates tasks only through the world and uses none of the helpers that
               wait in real time.

The task rules match `Task {`, `Task(`, `Task<…> {`, `Task<…>(`, `Task.detached`, `Task.init` and `Task.immediate`.
They can't see a task made through a type alias or a contextual `.init { … }`.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
ALLOWLIST = ROOT / "scripts" / "timing-allowlist.txt"

REAL_TIME = re.compile(
    r"Task\.sleep\s*\(|Thread\.sleep\s*\(|\busleep\s*\(|\bsleep\s*\(\s*\d|asyncAfter\s*\(|ContinuousClock|SuspendingClock"
    r"|DispatchSourceTimer|Timer\.scheduledTimer|\.wait\s*\(\s*(timeout|until)\s*:"
)
TASK = re.compile(r"(?<![\w.])Task\s*(<[^{}()\n]*>)?\s*(\{|\(|\.detached\b|\.init\b|\.immediate\b)")
SIM_BANNED = re.compile(
    r"\bpoll\s*[({]|\bpollAsync\b|\bwaitForArrival\b|\bwaitForFinish\b|\bmakeTransport\s*\(\)|\bBarrier\s*\(\)"
    r"|\bUncancellableWait\b|\bRealSleepClock\b|\bSteppingClock\b|\bServerTimeClock\b|\bServerClock\s*\("
)
SIM_KERNEL = {"Tests/ChatSyncTests/SimWorld.swift", "Tests/ChatSyncTests/SimWorldTests.swift"}


def strip_comment(line):
    index = line.find("//")
    return line if index < 0 else line[:index]


def task_sites(text):
    for number, raw in enumerate(text.splitlines(), 1):
        line = strip_comment(raw)
        for match in TASK.finditer(line):
            # `-> Task<Value, Never> {` is a return type followed by a body, not a task.
            if match.group(1) and "->" in line[: match.start()]:
                continue
            yield number, raw.strip()


def real_time_sites(text):
    for number, raw in enumerate(text.splitlines(), 1):
        if REAL_TIME.search(strip_comment(raw)):
            yield number, raw.strip()


def sim_banned_sites(text):
    for number, raw in enumerate(text.splitlines(), 1):
        if SIM_BANNED.search(strip_comment(raw)):
            yield number, raw.strip()


def load_allowlist():
    allowed = {"real-time": set(), "session-task": set()}
    section = None
    for raw in ALLOWLIST.read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
            continue
        allowed[section].add(line)
    return allowed


def check(paths, allowed):
    problems = []
    for path in paths:
        relative = path.relative_to(ROOT).as_posix()
        text = path.read_text()
        if relative.startswith("Tests/"):
            if relative not in allowed["real-time"]:
                problems += [(relative, n, "real-time", line) for n, line in real_time_sites(text)]
            if "SimWorld" in text and relative.startswith("Tests/ChatSyncTests/") and relative not in SIM_KERNEL:
                problems += [(relative, n, "sim-rig: task outside the world", line) for n, line in task_sites(text)]
                problems += [(relative, n, "sim-rig: real-time helper", line) for n, line in sim_banned_sites(text)]
        elif relative.startswith("Sources/ChatSync/") and relative not in allowed["session-task"]:
            problems += [(relative, n, "session-task", line) for n, line in task_sites(text)]
    return problems


def self_test():
    caught = [
        "Task { await run() }", "let t = Task(priority: .high) { }", "Task.detached { }", "Task.init { }",
        "Task.immediate { }", "let t = Task<Void, Never> { }", "return Task<Int, Never>(priority: nil) { 1 }",
        "x = Task(executorPreference: e) { }",
    ]
    ignored = [
        "var sleepTask: Task<Void, Never>?", "func unowned() -> Task<Success, Never> {", "if Task.isCancelled { }",
        "try Task.checkCancellation()", "await Task.yield()", "let tasks: [Task<Void, Never>] = []",
        "work.task { }", "// Task { }", "struct MyTask { }",
    ]
    real = [
        "try await Task.sleep(for: .seconds(1))", "Thread.sleep(forTimeInterval: 1)", "usleep(10_000)",
        "DispatchQueue.global().asyncAfter(deadline: .now() + 1) { }", "let end = ContinuousClock.now",
        "semaphore.wait(timeout: .now() + 1)", "condition.wait(until: deadline)",
    ]
    not_real = ["try await clock.sleep(for: .seconds(1))", "await world.settle()", "semaphore.wait()"]
    banned = [
        "await poll { done }", "await poll(timeout: .seconds(1)) { done }", "await pollAsync { true }",
        "barrier.waitForArrival()", "server.makeTransport()", "let b = Barrier()", "RealSleepClock(server: s)",
    ]
    failures = []
    failures += [f"task not caught: {s}" for s in caught if not list(task_sites(s))]
    failures += [f"task wrongly caught: {s}" for s in ignored if list(task_sites(s))]
    failures += [f"real time not caught: {s}" for s in real if not list(real_time_sites(s))]
    failures += [f"real time wrongly caught: {s}" for s in not_real if list(real_time_sites(s))]
    failures += [f"helper not caught: {s}" for s in banned if not list(sim_banned_sites(s))]
    for failure in failures:
        print(failure)
    return 1 if failures else 0


def main(argv):
    if argv == ["--self-test"]:
        return self_test()
    if argv and argv[0] == "--strict":
        paths = [pathlib.Path(p).resolve() for p in argv[1:]]
        allowed = {"real-time": set(), "session-task": load_allowlist()["session-task"]}
    else:
        paths = sorted(ROOT.glob("Tests/**/*.swift")) + sorted(ROOT.glob("Sources/ChatSync/*.swift"))
        allowed = load_allowlist()
    problems = check(paths, allowed)
    for relative, number, rule, line in problems:
        print(f"{relative}:{number}: {rule}: {line}")
    if problems:
        print(f"{len(problems)} timing problem(s). See scripts/check_test_timing.py for the rules.")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
