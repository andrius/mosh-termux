import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
BASH = shutil.which("bash")


class BuildInstallationTests(unittest.TestCase):
    def run_build(self, manager, broken=False):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        base = Path(temporary.name)
        home = base / "home"
        prefix = base / "prefix"
        commands = base / "commands"
        work = base / "work"
        for directory in (home, prefix / "bin", commands, work):
            directory.mkdir(parents=True)
        original = prefix / "bin/mosh-client"
        original.write_text("packaged client\n")
        (prefix / "bin/termux-setup-package-manager").write_text(
            f"export TERMUX_APP_PACKAGE_MANAGER={manager}\n"
        )
        (work / "mosh-1.4.0.tar.gz").touch()
        log = base / "calls"
        log.touch()
        for name in ("pkg", "pacman", "apt-mark", "sha256sum", "patch"):
            self.command(commands / name, 'printf "%s\\n" "$0 $*" >> "$CALLS"\n')
        self.command(commands / "tar", """
mkdir -p mosh-1.4.0/src/frontend
printf '#!%s\nexit 0\n' "$TEST_BASH" > mosh-1.4.0/configure
chmod +x mosh-1.4.0/configure
""")
        self.command(commands / "make", """
printf '#!%s\nexit %s\n' "$TEST_BASH" "$CLIENT_STATUS" > src/frontend/mosh-client
chmod +x src/frontend/mosh-client
""")
        env = dict(os.environ, HOME=str(home), PREFIX=str(prefix), WORK=str(work),
                   PATH=f"{commands}{os.pathsep}{os.environ['PATH']}",
                   CALLS=str(log), TEST_BASH=BASH,
                   CLIENT_STATUS="17" if broken else "0")
        result = subprocess.run([BASH, str(ROOT / "build.sh"), "--install"],
                                env=env, capture_output=True, text=True)
        return result, home, prefix, log.read_text()

    @staticmethod
    def command(path, body):
        path.write_text(f"#!{BASH}\nset -eu\n{body}")
        path.chmod(0o755)

    def test_pacman_installs_private_client_without_changing_packaged_binary(self):
        result, home, prefix, calls = self.run_build("pacman")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("pacman -Syu --needed --noconfirm", calls)
        self.assertNotIn("apt-mark", calls)
        self.assertEqual((prefix / "bin/mosh-client").read_text(), "packaged client\n")
        self.assertTrue((home / "tools/mosh-termux/bin/mosh-client").is_file())
        self.assertIn('export PATH="$HOME/tools/mosh-termux/bin:$PATH"', result.stdout)

    def test_apt_preserves_backup_and_holds_package(self):
        result, _, prefix, calls = self.run_build("apt")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("pkg install -y", calls)
        self.assertIn("apt-mark hold mosh", calls)
        self.assertNotIn("pacman -", calls)
        self.assertEqual((prefix / "bin/mosh-client.orig").read_text(), "packaged client\n")

    def test_unloadable_build_does_not_replace_client(self):
        for manager in ("apt", "pacman"):
            with self.subTest(manager=manager):
                result, home, prefix, calls = self.run_build(manager, broken=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((prefix / "bin/mosh-client").read_text(), "packaged client\n")
                self.assertFalse((home / "tools/mosh-termux/bin/mosh-client").exists())
                self.assertNotIn("apt-mark hold", calls)

    def test_unsupported_manager_stops_before_building(self):
        result, _, prefix, calls = self.run_build("unsupported")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unsupported Termux package manager", result.stderr)
        self.assertNotIn("sha256sum", calls)
        self.assertEqual((prefix / "bin/mosh-client").read_text(), "packaged client\n")


if __name__ == "__main__":
    unittest.main()
