import json
import os
from pathlib import Path
import sys

version = os.environ.get("MOCK_OPENCODE_VERSION", "2.3.2")
role = os.environ.get("MOCK_OPENCODE_ROLE", "source")
state = Path(os.environ["MOCK_OPENCODE_STATE"])
args = sys.argv[1:]


def sessions(directory):
    return sorted(directory.glob("ses_*.json"))


def output_session(source, session_id):
    path = source / f"{session_id}.json"
    if not path.exists():
        print("session not found", file=sys.stderr)
        raise SystemExit(2)
    sys.stdout.write(path.read_text(encoding="utf-8"))


def import_session(destination, filename):
    data = json.loads(Path(filename).read_text(encoding="utf-8"))
    if version.startswith("1."):
        if data["messages"]:
            assert data["messages"][0]["info"]["role"] in ("user", "assistant")
            assert "parts" in data["messages"][0]
    else:
        if data["messages"]:
            assert data["messages"][0]["type"]
            assert "info" not in data["messages"][0]
    session_id = data["info"]["id"]
    parent_id = data["info"].get("parentID")
    if parent_id and not (destination / f"{parent_id}.json").exists():
        print("parent session must be imported first", file=sys.stderr)
        raise SystemExit(4)
    target = destination / f"{session_id}.json"
    if target.exists():
        print("ImportConflictError", file=sys.stderr)
        raise SystemExit(3)
    target.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
    with (state / "import-order.log").open("a", encoding="utf-8") as log:
        log.write(session_id + "\n")
    print(session_id)


if os.environ.get("MOCK_OPENCODE_FAIL_SECRET"):
    print("authentication failed " + os.environ["MOCK_OPENCODE_FAIL_SECRET"], file=sys.stderr)
    raise SystemExit(9)
elif args == ["--version"]:
    print(f"opencode v{version}")
elif args[:2] == ["debug", "paths"] and args[2:] == ["db"]:
    print(state / "opencode.db")
elif version.startswith("1.") and args[:2] == ["session", "list"]:
    directory = state / ("exported" if role == "source" else "imported")
    items = [{"id": path.stem, "directory": str(state)} for path in sessions(directory)]
    print(json.dumps(items))
elif version.startswith("2.") and args[:3] == ["api", "get", "/api/session"]:
    directory = state / ("exported" if role == "source" else "imported")
    items = [{"id": path.stem} for path in sessions(directory)]
    print(json.dumps({"data": items, "cursor": None}))
elif version.startswith("1.") and args[:1] == ["export"]:
    output_session(state / "exported", args[1])
elif version.startswith("2.") and args[:2] == ["session", "export"]:
    output_session(state / "exported", args[2])
elif version.startswith("1.") and args[:1] == ["import"]:
    import_session(state / "imported", args[1])
elif version.startswith("2.") and args[:2] == ["session", "import"]:
    import_session(state / "imported", args[2])
else:
    print("unsupported mock invocation: " + " ".join(args), file=sys.stderr)
    raise SystemExit(64)
