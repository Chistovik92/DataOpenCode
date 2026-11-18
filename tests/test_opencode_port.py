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


def make_archive(path, config=None, auth=None, env_vars=None, sessions=None, source_major=2):
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "opencode-port"
        if config is not None:
            (root / "config").mkdir(parents=True)
            (root / "config" / "opencode.json").write_text(config, encoding="utf-8")
        if auth is not None:
            if isinstance(auth, str):
                (root / "data").mkdir(parents=True, exist_ok=True)
                (root / "data" / "auth.json").write_text(auth, encoding="utf-8")
            else:
                write_json(root / "data" / "auth.json", auth)
        if env_vars is not None:
            (root / "env").mkdir(parents=True)
            (root / "env" / "env.json").write_text(env_vars, encoding="utf-8")
        session_files = []
        for session in sessions or []:
            name = f"{session['info']['id']}.json"
            write_json(root / "sessions" / name, session)
            session_files.append(name)
        write_json(
            root / "manifest.json",
            {
                "format": "opencode-port",
                "version": 2,
                "providers": [],
                "sessions": {"sourceMajor": source_major, "files": session_files},
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
                if source_version.startswith("1."):
                    session = {
                        "info": {"id": "ses_transfer", "projectID": "prj_source", "slug": "test", "directory": str(source), "title": "synthetic", "version": "1.2.27", "time": {"created": 1, "updated": 2}},
                        "messages": [{"info": {"id": "msg_one", "sessionID": "ses_transfer", "role": "user", "agent": "default", "model": {"providerID": "test", "modelID": "test"}, "time": {"created": 1}}, "parts": [{"id": "prt_one", "sessionID": "ses_transfer", "messageID": "msg_one", "type": "text", "text": "hello"}]}],
                    }
                else:
                    session = {
                        "info": {"id": "ses_transfer", "projectID": "prj_source", "title": "synthetic", "cost": 0, "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}}, "location": {"directory": str(source)}, "time": {"created": 1, "updated": 2}},
                        "messages": [{"id": "msg_one", "type": "user", "text": "hello", "time": {"created": 1}}],
                    }
                write_json(state / "exported" / "ses_transfer.json", session)
                write_json(state / "imported" / "ses_existing.json", {"info": {"id": "ses_existing"}, "messages": []})
                archive = case / "port.zip"
                env = self.cli_env(source_version)
                env["MOCK_OPENCODE_STATE"] = str(state)
                env["MOCK_OPENCODE_ROLE"] = "source"
                exported = run_port("export", "-Out", archive, "-HomeDir", source, "-Secrets", "None", env=env)
                self.assertEqual(exported.returncode, 0, exported.stdout + exported.stderr)
                with zipfile.ZipFile(archive) as zf:
                    self.assertIn("opencode-port/sessions/ses_transfer.json", zf.namelist())
                    self.assertEqual(json.loads(zf.read("opencode-port/sessions/ses_transfer.json")), session)

                env["MOCK_OPENCODE_VERSION"] = target_version
                env["MOCK_OPENCODE_ROLE"] = "target"
                imported = run_port("import", "-Zip", archive, "-HomeDir", target, "-SessionDirectory", target / "work", env=env)
                self.assertEqual(imported.returncode, 0, imported.stdout + imported.stderr)
                actual = json.loads((state / "imported" / "ses_transfer.json").read_text(encoding="utf-8"))
                if source_version.startswith(target_version[0] + "."):
                    self.assertEqual(actual, session)
                elif target_version.startswith("2."):
                    self.assertEqual(actual["messages"][0]["type"], "user")
                    self.assertEqual(actual["messages"][0]["text"], "hello")
                    self.assertIn("opencodePortV1", actual["info"]["metadata"])
                else:
                    self.assertEqual(actual["messages"][0]["info"]["role"], "user")
                    self.assertEqual(actual["messages"][0]["parts"][0]["text"], "hello")
                    self.assertIn("opencodePortV2", actual["info"]["metadata"])
                self.assertTrue((state / "imported" / "ses_existing.json").exists())
                backups = list(state.glob("opencode.db.*.bak"))
                self.assertTrue(backups)
    def test_invalid_auth_does_not_modify_config(self):
        for local_invalid in (False, True):
            with self.subTest(local_invalid=local_invalid):
                case = self.base / f"auth-preflight-{local_invalid}"
                target = case / "target"
                config_path = target / ".config" / "opencode" / "opencode.json"
                write_json(config_path, {"provider": {"local": {}}})
                original = config_path.read_text(encoding="utf-8")
                archive = case / "auth.zip"
                incoming_auth = "{ broken" if not local_invalid else {"new": {"key": "new"}}
                if local_invalid:
                    auth_path = target / ".local" / "share" / "opencode" / "auth.json"
                    auth_path.parent.mkdir(parents=True)
                    auth_path.write_text("{ broken", encoding="utf-8")
                make_archive(archive, '{"provider":{"new":{}}}', incoming_auth)

                result = self.import_archive(archive, target)

                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(config_path.read_text(encoding="utf-8"), original)

    def test_cross_version_external_attachment_reference_is_preserved(self):
        session = {
            "info": {"id": "ses_attachment", "projectID": "prj", "slug": "test", "directory": "C:\\old", "title": "test", "version": "1.2.27", "time": {"created": 1, "updated": 1}},
            "messages": [{"info": {"id": "msg_attachment", "sessionID": "ses_attachment", "role": "user", "agent": "default", "model": {"providerID": "test", "modelID": "test"}, "time": {"created": 1}}, "parts": [{"id": "prt_file", "sessionID": "ses_attachment", "messageID": "msg_attachment", "type": "file", "mime": "application/pdf", "filename": "test.pdf", "url": "https://example.invalid/test.pdf"}]}],
        }
        archive = self.base / "attachment.zip"
        make_archive(archive, "{}", sessions=[session], source_major=1)
        env = self.cli_env("2.3.2")
        env["MOCK_OPENCODE_ROLE"] = "target"

        result = self.import_archive(archive, self.target, "-SessionDirectory", self.target / "work", env=env)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        imported = json.loads((self.mock_state / "imported" / "ses_attachment.json").read_text(encoding="utf-8"))
        attachment = imported["messages"][0]["files"][0]
        self.assertEqual(attachment["source"], {"type": "uri", "uri": "https://example.invalid/test.pdf"})
        self.assertEqual(attachment["data"], "")

    def test_valid_env_json_supports_dry_run_without_applying_variables(self):
        name = "OPENCODE_PORT_TEST_UNUSED_VARIABLE"
        archive = self.base / "valid-env.zip"
        make_archive(archive, "{}", env_vars=json.dumps({"vars": [{"name": name, "scope": "Machine", "value": "synthetic"}]}))

        result = self.import_archive(archive, self.target, "-DryRun")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIsNone(os.environ.get(name))

    def test_unicode_session_export_round_trip(self):
        text = "Привет, 世界"
        session = {"info": {"id": "ses_unicode", "title": text}, "messages": [{"id": "msg_unicode", "type": "user", "text": text, "time": {"created": 1}}]}
        write_json(self.mock_state / "exported" / "ses_unicode.json", session)
        archive = self.base / "unicode.zip"
        env = self.cli_env("2.3.2")

        result = run_port("export", "-Out", archive, "-HomeDir", self.source, "-Secrets", "None", env=env)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        with zipfile.ZipFile(archive) as zf:
            exported = json.loads(zf.read("opencode-port/sessions/ses_unicode.json").decode("utf-8"))
        self.assertEqual(exported["info"]["title"], text)
        self.assertEqual(exported["messages"][0]["text"], text)

    def test_cli_stderr_never_leaks_secret_values(self):
        archive = self.base / "secret.zip"
        env = self.cli_env("2.3.2")
        env["MOCK_OPENCODE_FAIL_SECRET"] = "sk-synthetic-secret"

        result = run_port("export", "-Out", archive, "-HomeDir", self.source, "-Secrets", "None", env=env)

        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("sk-synthetic-secret", result.stdout + result.stderr)

    def test_v2_streaming_tool_and_external_file_convert_to_v1(self):
        session = {
            "info": {"id": "ses_tool", "projectID": "prj", "time": {"created": 1, "updated": 1}},
            "messages": [
                {"id": "msg_user", "type": "user", "text": "test", "time": {"created": 1}, "files": [{"mime": "application/pdf", "name": "remote.pdf", "data": "", "source": {"type": "uri", "uri": "https://example.invalid/remote.pdf"}}]},
                {"id": "msg_assistant", "type": "assistant", "agent": "default", "model": {"providerID": "test", "id": "test"}, "time": {"created": 2, "completed": 2}, "content": [{"type": "tool", "id": "call_one", "name": "read", "state": {"status": "streaming", "input": "{}"}, "time": {"created": 2}}]},
            ],
        }
        archive = self.base / "tool.zip"
        make_archive(archive, "{}", sessions=[session])
        env = self.cli_env("1.2.27")
        env["MOCK_OPENCODE_ROLE"] = "target"

        result = self.import_archive(archive, self.target, "-SessionDirectory", self.target / "work", env=env)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        imported = json.loads((self.mock_state / "imported" / "ses_tool.json").read_text(encoding="utf-8"))
        self.assertEqual(imported["messages"][0]["parts"][1]["url"], "https://example.invalid/remote.pdf")
        self.assertEqual(imported["messages"][1]["parts"][0]["state"]["status"], "pending")

    def test_existing_session_id_is_not_overwritten(self):
        session = {"info": {"id": "ses_same", "title": "incoming"}, "messages": []}
        write_json(self.mock_state / "imported" / "ses_same.json", {"info": {"id": "ses_same", "title": "local"}, "messages": []})
        archive = self.base / "duplicate.zip"
        make_archive(archive, "{}", sessions=[session])
        env = self.cli_env("2.3.2")
        env["MOCK_OPENCODE_ROLE"] = "target"

        result = self.import_archive(archive, self.target, env=env)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        existing = json.loads((self.mock_state / "imported" / "ses_same.json").read_text(encoding="utf-8"))
        self.assertEqual(existing["info"]["title"], "local")

    def test_zip_entry_count_limit_is_enforced(self):
        archive = self.base / "too-many.zip"
        with zipfile.ZipFile(archive, "w") as zf:
            for index in range(10001):
                zf.writestr(f"opencode-port/{index}.txt", "")

        result = self.import_archive(archive)

        self.assertNotEqual(result.returncode, 0)

    def test_child_session_is_imported_after_parent(self):
        parent = {"info": {"id": "ses_parent", "projectID": "prj", "cost": 0, "tokens": {}, "location": {"directory": "C:\\old"}, "time": {"created": 1, "updated": 1}}, "messages": []}
        child = {"info": {"id": "ses_child", "parentID": "ses_parent", "projectID": "prj", "cost": 0, "tokens": {}, "location": {"directory": "C:\\old"}, "time": {"created": 2, "updated": 2}}, "messages": []}
        archive = self.base / "parents.zip"
        make_archive(archive, "{}", sessions=[child, parent])
        env = self.cli_env("2.3.2")
        env["MOCK_OPENCODE_ROLE"] = "target"

        result = self.import_archive(archive, self.target, "-SessionDirectory", self.target / "work", env=env)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        order = (self.mock_state / "import-order.log").read_text(encoding="utf-8").splitlines()
        self.assertEqual(order, ["ses_parent", "ses_child"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
