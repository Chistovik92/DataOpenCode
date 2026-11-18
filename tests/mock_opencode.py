import json
import os
from pathlib import Path
import sys

version = os.environ.get("MOCK_OPENCODE_VERSION", "2.3.2")
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
    session_id = data["info"]["id"]
    target = destination / f"{session_id}.json"
    if target.exists():
        print("ImportConflictError", file=sys.stderr)
        raise SystemExit(3)
    target.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
    print(session_id)


if args == ["--version"]:
    print(f"opencode v{version}")
elif args[:2] == ["debug", "paths"] and args[2:] == ["db"]:
    print(state / "opencode.db")
elif version.startswith("1.") and args[:2] == ["session", "list"]:
    items = [{"id": path.stem, "directory": str(state)} for path in sessions(state / "exported")] + [
        {"id": path.stem, "directory": str(state)} for path in sessions(state / "imported")
    ]
    print(json.dumps(items))
elif version.startswith("2.") and args[:3] == ["api", "get", "/api/session"]:
    items = [{"id": path.stem} for path in sessions(state / "exported")] + [{"id": path.stem} for path in sessions(state / "imported")]
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
