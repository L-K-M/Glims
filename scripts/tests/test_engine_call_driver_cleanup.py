"""Driver ownership checks using fake processes/signals; no child is launched."""
import argparse
from contextlib import ExitStack, redirect_stderr, redirect_stdout
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest
from unittest import mock


class SimulatedTermination(BaseException):
    """Model the previous SIGTERM disposition without signalling this process."""


class FakeSignals:
    def __init__(self):
        def previous_term(signum, frame):
            raise SimulatedTermination("SIGTERM reached the previous disposition")

        def previous_int(signum, frame):
            raise KeyboardInterrupt("SIGINT reached the previous disposition")

        self.previous = {signal.SIGTERM: previous_term, signal.SIGINT: previous_int}
        self.handlers = dict(self.previous)
        self.delivered = []

    def signal(self, signum, handler):
        previous = self.handlers[signum]
        self.handlers[signum] = handler
        return previous

    def fire(self, signum):
        self.delivered.append(signum)
        self.handlers[signum](signum, None)


class FakeClock:
    def __init__(self):
        self.now = 100.0

    def monotonic(self):
        self.now += 0.1
        return self.now

    def sleep(self, seconds):
        self.now += max(0, seconds)


class FakeProcess:
    """TERM leaves the child alive, so cleanup must escalate and reap it."""
    pid = 2147483000

    def __init__(self, signals, clock, signum, during_spawn):
        self.signals = signals
        self.clock = clock
        self.signum = signum
        self.during_spawn = during_spawn
        self.returncode = None
        self.reaped = False
        self.term_sent = False
        self.initial_signal_sent = during_spawn
        self.repeated_signals_sent = False
        self.waits = 0
        self.kills = []
        self.spawn_handlers = None

    def poll(self):
        if self.returncode is not None:
            self.reaped = True
        return self.returncode

    def wait(self, timeout=None):
        self.waits += 1
        if self.waits > 200:
            raise AssertionError("driver exceeded the deterministic fake wait budget")
        if self.returncode is not None:
            self.reaped = True
            return self.returncode
        if not self.initial_signal_sent:
            self.initial_signal_sent = True
            self.signals.fire(self.signum)
        elif self.term_sent and not self.repeated_signals_sent:
            self.repeated_signals_sent = True
            self.signals.fire(self.signum)
            self.signals.fire(self.signum)
        self.clock.sleep(timeout if timeout is not None else 0.1)
        raise subprocess.TimeoutExpired(["fake-owned-harness"], timeout)

    def killpg(self, process_group, signum):
        if process_group != self.pid:
            raise AssertionError("attempted to signal an unowned process group")
        self.kills.append(signum)
        if signum == signal.SIGTERM:
            self.term_sent = True
        elif signum == signal.SIGKILL:
            self.returncode = -signal.SIGKILL
        else:
            raise AssertionError("unexpected process-group signal")


class DriverCleanupCases:
    def setUp(self):
        script = Path(__file__).resolve().parents[1] / self.driver_name
        spec = importlib.util.spec_from_file_location(self.driver_name.replace("-", "_"), script)
        self.driver = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.driver)
        self.temporary = tempfile.TemporaryDirectory(prefix="glims-driver-cleanup-")
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name).resolve()
        producer = root / "producer"
        producer.mkdir()
        binary = root / "harness" / "fake-harness"
        binary.parent.mkdir()
        binary.write_bytes(b"This fixture file is never executed.\n")
        source = producer / "immutable-input"
        source.write_bytes(b"unchanged fixture input\n")
        checksum = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
        (binary.parent / "build.json").write_text(json.dumps({
            "ref": self.driver.PINNED_REF, "producer": str(producer),
            "binary_sha256": checksum(binary), "inputs_sha256": {str(source): checksum(source)},
        }))
        self.arguments = argparse.Namespace(binary=binary, work=root / "work",
                                            timeout=1, ref=self.driver.PINNED_REF)

    def exercise_interruption(self, signum, during_spawn):
        signals = FakeSignals()
        clock = FakeClock()
        process = FakeProcess(signals, clock, signum, during_spawn)
        launches = []

        def fake_popen(command, **kwargs):
            self.assertTrue(kwargs.get("start_new_session"), "fixture must model an owned detached group")
            launches.append(command)
            process.spawn_handlers = dict(signals.handlers)
            if during_spawn:
                signals.fire(signum)
            return process

        caught = None
        result = None
        with ExitStack() as patches:
            patches.enter_context(mock.patch.object(self.driver.subprocess, "Popen", side_effect=fake_popen))
            patches.enter_context(mock.patch.object(self.driver.subprocess, "run",
                side_effect=AssertionError("no compiler or real subprocess may run in this fixture")))
            patches.enter_context(mock.patch.object(self.driver.os, "killpg", side_effect=process.killpg))
            patches.enter_context(mock.patch.object(self.driver.signal, "signal", side_effect=signals.signal))
            patches.enter_context(mock.patch.object(self.driver.signal, "getsignal",
                                                   side_effect=lambda number: signals.handlers[number]))
            patches.enter_context(mock.patch.object(time, "monotonic", side_effect=clock.monotonic))
            patches.enter_context(mock.patch.object(time, "sleep", side_effect=clock.sleep))
            patches.enter_context(redirect_stdout(io.StringIO()))
            patches.enter_context(redirect_stderr(io.StringIO()))
            try:
                result = self.driver.run(self.arguments)
            except BaseException as error:
                # Capture simulated termination/KeyboardInterrupt as assertion
                # evidence; never let fake signals interrupt the test runner.
                caught = error

        self.assertIsNone(caught, f"interruption escaped driver cleanup: {caught!r}")
        self.assertEqual(result, 124, "interruption must report failure rather than a successful run")
        self.assertEqual(len(launches), 1)
        self.assertTrue(process.reaped, "the owned detached child was not reaped")
        self.assertEqual(process.kills, [signal.SIGTERM, signal.SIGKILL])
        self.assertIs(signals.handlers[signal.SIGTERM], signals.previous[signal.SIGTERM])
        self.assertIs(signals.handlers[signal.SIGINT], signals.previous[signal.SIGINT])
        if during_spawn:
            self.assertIsNot(process.spawn_handlers[signal.SIGTERM], signals.previous[signal.SIGTERM])
            self.assertIsNot(process.spawn_handlers[signal.SIGINT], signals.previous[signal.SIGINT])
        else:
            self.assertTrue(process.repeated_signals_sent)
            self.assertEqual(signals.delivered.count(signum), 3)

    def test_repeated_sigterm_during_cleanup_reaps_owned_child(self):
        self.exercise_interruption(signal.SIGTERM, during_spawn=False)

    def test_repeated_sigint_during_cleanup_reaps_owned_child(self):
        self.exercise_interruption(signal.SIGINT, during_spawn=False)

    def test_sigterm_during_spawn_is_owned_and_reaped(self):
        self.exercise_interruption(signal.SIGTERM, during_spawn=True)

    def test_sigint_during_spawn_is_owned_and_reaped(self):
        self.exercise_interruption(signal.SIGINT, during_spawn=True)


class CallDrainDriverCleanupTests(DriverCleanupCases, unittest.TestCase):
    driver_name = "test-engine-call-drain.py"


class CallAdmissionDriverCleanupTests(DriverCleanupCases, unittest.TestCase):
    driver_name = "test-engine-call-admission.py"


if __name__ == "__main__":
    unittest.main()
