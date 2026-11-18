import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "opencode-port.ps1"
MOCK = Path(__file__).with_name("mock_opencode.py")


def run_port(*args, env=None, timeout=45):
    command = [
        "powershell",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(SCRIPT),
        *map(str, args),
    ]
    return subprocess.run(
        command,
        cwd=ROOT,
        env=env,
        text=True,
        encoding="utf-8",
        errors="replace",
        capture_output=True,
        timeout=timeout,
    )


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")


def make_archive(path, config=None, auth=None, env_vars=None, sessions=None):
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "opencode-port"
        if config is not None:
            (root / "config").mkdir(parents=True)
            (root / "config" / "opencode.json").write_text(config, encoding="utf-8")
        if auth is not None:
            write_json(root / "data" / "auth.json", auth)
        if env_vars is not None:
            (root / "env").mkdir(parents=True)
            (root / "env" / "env.json").write_text(env_vars, encoding="utf-8")
        session_files = []
        for index, session in enumerate(sessions or []):
            name = f"session-{index}.json"
            write_json(root / "sessions" / name, session)
            session_files.append(name)
        write_json(
            root / "manifest.json",
            {
                "format": "opencode-port",
                "version": 2,
                "providers": [],
                "sessions": {"files": session_files},
            },
        )
        with zipfile.ZipFile(path, "w") as archive:
            for item in root.rglob("*"):
                if item.is_file():
                    archive.write(item, item.relative_to(Path(tmp)).as_posix())


class PortTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="opencode-port-tests-")
        self.base = Path(self.temp.name)
        self.source = self.base / "source"
        self.target = self.base / "target"
        for home in (self.source, self.target):
            write_json(home / ".config" / "opencode" / "opencode.json", {})
        self.mock_state = self.base / "mock-state"
        self.mock_state.mkdir()
        (self.mock_state / "exported").mkdir()
        (self.mock_state / "imported").mkdir()
        (self.mock_state / "opencode.db").write_bytes(b"synthetic sqlite backup")

    def tearDown(self):
        self.temp.cleanup()

    def cli_env(self, version):
        env = os.environ.copy()
        mock_cmd = self.base / "mock-opencode.cmd"
        mock_cmd.write_text(f'@echo off\r\npython "{MOCK}" %*\r\nexit /b %ERRORLEVEL%\r\n', encoding="ascii")
        env["OPENCODE_PORT_CLI"] = str(mock_cmd)
        env["MOCK_OPENCODE_VERSION"] = version
        env["MOCK_OPENCODE_STATE"] = str(self.mock_state)
        return env

    def import_archive(self, archive, home=None, *extra, env=None):
        home = home or self.target
        return run_port("import", "-Zip", archive, "-HomeDir", home, *extra, env=env)

    def test_merges_both_provider_spellings_without_replacing_local_values(self):
        local = {
            "provider": {"same": {"options": {"local": True}, "models": {"old": {}}}, "legacy-local": {}},
            "providers": {"native-local": {}},
            "permission": {"edit": "ask"},
        }
        incoming = {
            "provider": {"same": {"options": {"incoming": True}, "models": {"new": {}}}, "legacy-new": {}},
            "providers": {"same": {"settings": {"baseURL": "https://native.invalid"}}, "native-new": {}},
            "permission": {"edit": "allow"},
        }
        write_json(self.target / ".config" / "opencode" / "opencode.json", local)
        archive = self.base / "providers.zip"
        make_archive(archive, json.dumps(incoming), {"new": {"type": "api", "key": "incoming-secret"}})
        write_json(self.target / ".local" / "share" / "opencode" / "auth.json", {"local": {"type": "api", "key": "local-secret"}})

        result = self.import_archive(archive)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        merged = json.loads((self.target / ".config" / "opencode" / "opencode.json").read_text(encoding="utf-8"))
        self.assertTrue(merged["provider"]["same"]["options"]["local"])
        self.assertTrue(merged["provider"]["same"]["options"]["incoming"])
        self.assertIn("old", merged["provider"]["same"]["models"])
        self.assertIn("new", merged["provider"]["same"]["models"])
        self.assertIn("legacy-new", merged["provider"])
        self.assertIn("native-new", merged["providers"])
        self.assertEqual(merged["permission"], {"edit": "ask"})
        auth = json.loads((self.target / ".local" / "share" / "opencode" / "auth.json").read_text(encoding="utf-8"))
        self.assertEqual(set(auth), {"local", "new"})
        self.assertNotIn("incoming-secret", result.stdout + result.stderr)
        self.assertNotIn("local-secret", result.stdout + result.stderr)

    def test_invalid_local_config_is_not_overwritten(self):
        path = self.target / ".config" / "opencode" / "opencode.json"
        path.write_text("{ broken", encoding="utf-8")
        archive = self.base / "invalid-local.zip"
        make_archive(archive, '{"provider":{"new":{}}}')

        result = self.import_archive(archive)

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(path.read_text(encoding="utf-8"), "{ broken")

    def test_invalid_archive_config_is_rejected_not_copied(self):
        path = self.target / ".config" / "opencode" / "opencode.json"
        original = path.read_text(encoding="utf-8")
        archive = self.base / "invalid-archive.zip"
        make_archive(archive, "{ broken")

        result = self.import_archive(archive)

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(path.read_text(encoding="utf-8"), original)

    def test_invalid_env_json_is_rejected(self):
        archive = self.base / "invalid-env.zip"
        make_archive(archive, "{}", env_vars="{ broken")

        result = self.import_archive(archive)

        self.assertNotEqual(result.returncode, 0)

    def test_zip_path_traversal_is_rejected(self):
        archive = self.base / "traversal.zip"
        with zipfile.ZipFile(archive, "w") as zf:
            zf.writestr("opencode-port/manifest.json", '{"format":"opencode-port","version":2}')
            zf.writestr("../outside.txt", "must not escape")

        result = self.import_archive(archive)

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.base / "outside.txt").exists())

    def test_local_opencode_files_are_preserved_and_new_files_added(self):
        local_dir = self.target / ".config" / "opencode" / ".opencode"
        local_dir.mkdir(parents=True)
        (local_dir / "keep.txt").write_text("local", encoding="utf-8")
        archive = self.base / "local-files.zip"
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "opencode-port"
            write_json(root / "manifest.json", {"format": "opencode-port", "version": 2, "sessions": {"files": []}})
            write_json(root / "config" / "opencode.json", {})
            (root / "config" / ".opencode").mkdir(parents=True)
            (root / "config" / ".opencode" / "keep.txt").write_text("incoming", encoding="utf-8")
            (root / "config" / ".opencode" / "new.txt").write_text("new", encoding="utf-8")
            with zipfile.ZipFile(archive, "w") as zf:
                for item in root.rglob("*"):
                    if item.is_file():
                        zf.write(item, item.relative_to(Path(tmp)).as_posix())

        result = self.import_archive(archive)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((local_dir / "keep.txt").read_text(encoding="utf-8"), "local")
        self.assertEqual((local_dir / "new.txt").read_text(encoding="utf-8"), "new")
        backups = list(local_dir.parent.glob(".opencode.*.bak"))
        self.assertTrue(backups)
        self.assertEqual((backups[0] / "keep.txt").read_text(encoding="utf-8"), "local")

    def test_dry_run_does_not_modify_config_auth_or_sessions(self):
        local = {"provider": {"local": {}}}
        write_json(self.target / ".config" / "opencode" / "opencode.json", local)
        archive = self.base / "dry-run.zip"
        session = {"info": {"id": "ses_dry"}, "messages": []}
        make_archive(archive, '{"provider":{"new":{}}}', {"new": {"key": "secret"}}, sessions=[session])
        env = self.cli_env("2.3.2")

        result = self.import_archive(archive, self.target, "-DryRun", "-SessionDirectory", self.target / "work", env=env)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads((self.target / ".config" / "opencode" / "opencode.json").read_text(encoding="utf-8")), local)
        self.assertFalse((self.target / ".local" / "share" / "opencode" / "auth.json").exists())
        self.assertFalse(any((self.mock_state / "imported").iterdir()))

    def test_four_session_transfer_directions_are_additive(self):
        for source_version, target_version in (("1.2.27", "1.2.27"), ("1.2.27", "2.3.2"), ("2.3.2", "1.2.27"), ("2.3.2", "2.3.2")):
            with self.subTest(source=source_version, target=target_version):
                case = self.base / f"case-{source_version}-{target_version}"
                source = case / "source"
                target = case / "target"
                write_json(source / ".config" / "opencode" / "opencode.json", {"provider": {"source": {}}})
                write_json(target / ".config" / "opencode" / "opencode.json", {"providers": {"target": {}}})
                state = case / "state"
                (state / "exported").mkdir(parents=True)
                (state / "imported").mkdir()
                (state / "opencode.db").write_bytes(b"synthetic database")
                session = {"info": {"id": "ses_transfer", "title": "synthetic"}, "messages": [{"info": {"id": "msg_one"}, "parts": []}]}
                write_json(state / "exported" / "ses_transfer.json", session)
                write_json(state / "imported" / "ses_existing.json", {"info": {"id": "ses_existing"}, "messages": []})
                archive = case / "port.zip"
                env = self.cli_env(source_version)
                env["MOCK_OPENCODE_STATE"] = str(state)
                exported = run_port("export", "-Out", archive, "-HomeDir", source, "-Secrets", "None", env=env)
                self.assertEqual(exported.returncode, 0, exported.stdout + exported.stderr)
                with zipfile.ZipFile(archive) as zf:
                    self.assertIn("opencode-port/sessions/ses_transfer.json", zf.namelist())
                    self.assertEqual(json.loads(zf.read("opencode-port/sessions/ses_transfer.json")), session)

                env["MOCK_OPENCODE_VERSION"] = target_version
                imported = run_port("import", "-Zip", archive, "-HomeDir", target, "-SessionDirectory", target / "work", env=env)
                self.assertEqual(imported.returncode, 0, imported.stdout + imported.stderr)
                self.assertEqual(json.loads((state / "imported" / "ses_transfer.json").read_text(encoding="utf-8")), session)
                self.assertTrue((state / "imported" / "ses_existing.json").exists())
                backups = list(state.glob("opencode.db.*.bak"))
                self.assertTrue(backups)


if __name__ == "__main__":
    unittest.main(verbosity=2)
