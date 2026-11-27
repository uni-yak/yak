"""验证协议夹具出错或子进程停滞时能有界地退出。"""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from lsp_frame_check import check_eof, open_pipe


class PipeCleanupTests(unittest.TestCase):
    def setUp(self):
        self.processes = []

    def exercise(self, child, fixture, *, timeout=2):
        open_pipe([sys.executable, "-c", child], fixture,
                  on_start=self.processes.append, timeout=timeout)

    def assert_child_stopped(self):
        self.assertEqual(len(self.processes), 1)
        proc = self.processes[0]
        self.assertIsInstance(proc, subprocess.Popen)
        self.assertIsNotNone(proc.returncode)
        for stream in (proc.stdin, proc.stdout, proc.stderr):
            self.assertTrue(stream.closed)

    def test_fixture_exception_stops_waiting_child(self):
        def fixture(send, receive, quiet):
            receive(b"ready", "子进程已开始")
            raise NameError("测试夹具异常")

        child = "import sys; print('ready', end='', flush=True); sys.stdin.buffer.read()"
        with self.assertRaisesRegex(NameError, "测试夹具异常"):
            self.exercise(child, fixture)
        self.assert_child_stopped()

    def test_blocked_pipe_write_has_deadline(self):
        def fixture(send, receive, quiet):
            receive(b"ready", "子进程已开始")
            send(b"x" * (4 * 1024 * 1024))
            return 0

        child = "import time; print('ready', end='', flush=True); time.sleep(30)"
        with self.assertRaisesRegex(RuntimeError, "未写完.*管道输入"):
            self.exercise(child, fixture)
        self.assert_child_stopped()

    def test_stderr_is_drained_without_unbounded_failure_detail(self):
        def fixture(send, receive, quiet):
            receive(b"ready", "子进程已排空写端")
            return 0

        child = "import sys; sys.stderr.buffer.write(b'x' * (4 * 1024 * 1024) + b'END'); print('ready', end='', flush=True)"
        with self.assertRaisesRegex(RuntimeError, "协议退出出现标准错误输出") as error:
            self.exercise(child, fixture)
        self.assertLess(len(str(error.exception)), 4200)
        self.assertNotIn("END", str(error.exception))
        self.assert_child_stopped()


class EofTests(unittest.TestCase):
    def test_file_and_pipe_expect_same_eof_status(self):
        with tempfile.TemporaryDirectory() as work:
            for status in (0, 1):
                with self.subTest(status=status):
                    command = [sys.executable, "-c", f"import sys; sys.stdin.buffer.read(); raise SystemExit({status})"]
                    check_eof(command, Path(work), status)

    def test_read_trap_is_not_accepted_as_eof(self):
        command = ["candidate"]
        file_eof = subprocess.CompletedProcess(command, 1, b"", b"")
        failed_read = subprocess.CompletedProcess(command, 70, b"", b"yak: read failed\n")
        with tempfile.TemporaryDirectory() as work, patch("lsp_frame_check.subprocess.run", side_effect=[file_eof, failed_read]):
            with self.assertRaisesRegex(RuntimeError, "关闭输入管道的结果异常"):
                check_eof(command, Path(work), 1)


if __name__ == "__main__":
    unittest.main()
