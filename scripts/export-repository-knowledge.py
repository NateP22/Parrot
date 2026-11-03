#!/usr/bin/env python3
"""GET-only GitHub code export. Uses gh's existing auth without reading a token.

No model, fact generation, repository writes, environment keys or background job.
The output is private source code: never upload it to the public Parrot fork.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import tempfile
from urllib.parse import quote

MAX_BYTES = 24 * 1024 * 1024
MAX_FILE_BYTES = 512 * 1024
EXCLUDED = {"node_modules", "vendor", "dist", "build", ".build", "coverage", "test", "tests",
            "__tests__", "fixtures", "docs", "documentation", "__snapshots__", "generated",
            "logs", "tmp", "cache", "certificates", "credentials", "secrets", "output", "outputs", "qa", "e2e",
            "test-data", "test_data", "testdata", "artifacts", "evidence", "backup", "backups", "archive", "archives",
            "snapshots", "examples", "samples", "scripts", "benchmarks"}
EXTENSIONS = {"js", "mjs", "cjs", "jsx", "jsxinc", "ts", "tsx", "swift", "json", "html", "css", "scss", "vue", "svelte",
              "py", "go", "rs", "java", "kt", "c", "h", "cpp", "m", "mm", "sql", "xml"}
SECRET = re.compile(r"sk-ant-[A-Za-z0-9_-]{16,}|sk-(?:proj-)?[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{16,}|AIza[A-Za-z0-9_-]{30,}|(?:AKIA|ASIA)[A-Z0-9]{16}|-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----")
ASSIGNMENT = re.compile(r'''(?i)(?:api[_-]?key|access[_-]?token|auth[_-]?token|password|client[_-]?secret)["']?\s*[:=]\s*["'][A-Za-z0-9_+/=\-]{12,}["']''')


def permits(path):
    if not isinstance(path, str) or not path or len(path.encode()) > 512 or path.startswith("/") or "\\" in path or any(ord(c) < 32 for c in path):
        return False
    parts = path.lower().split("/")
    if any(not p or p in {".", ".."} or p.startswith(".") or p in EXCLUDED or "installed-backup" in p for p in parts):
        return False
    name = parts[-1]
    credential_name = name.replace("-", "").replace("_", "")
    if any(x in credential_name for x in ("token", "apikey", "privatekey", "password", "keychain")):
        return False
    return not any(x in name for x in ("secret", "credential", "private-key", ".test.", ".spec.")) and not name.endswith(".min.js") and PurePosixPath(path).suffix.lower().lstrip(".") in EXTENSIONS


def github(endpoint, gh="/Users/pubge/.local/bin/gh"):
    # No shell, auth command, token output or secret-bearing argv. gh supplies
    # its existing authentication internally to these read-only API requests.
    result = subprocess.run([gh, "api", "--method", "GET", endpoint], stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=60, check=False)
    if result.returncode:
        raise RuntimeError("GitHub GET failed; no source package published")
    return json.loads(result.stdout)


def export(repository, ref, api=github):
    if not re.fullmatch(r"[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Invalid repository")
    if not ref or len(ref.encode()) > 256:
        raise ValueError("Invalid ref")
    prefix = "/repos/" + repository
    commit = api(prefix + "/commits/" + quote(ref, safe=""))
    sha = commit["sha"]
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError("Invalid resolved commit")
    tree_sha = commit["commit"]["tree"]["sha"]
    tree = api(prefix + "/git/trees/" + tree_sha + "?recursive=1")
    if tree.get("truncated") is not False or tree.get("sha") != tree_sha:
        raise ValueError("Incomplete or wrong GitHub tree")
    files, excluded, seen = [], [], set()
    total = 0
    for row in sorted(tree["tree"], key=lambda x: x["path"]):
        path = row["path"]
        if row["type"] == "tree":
            continue
        if row.get("mode") not in {"100644", "100755"} or row["type"] != "blob" or not permits(path):
            excluded.append({"path": path, "reason": "not permitted runtime source"})
            continue
        if not 0 < row.get("size", 0) <= MAX_FILE_BYTES:
            excluded.append({"path": path, "reason": "empty or oversized"})
            continue
        if path.lower() in seen:
            raise ValueError("Case-colliding paths")
        seen.add(path.lower())
        blob = api(prefix + "/git/blobs/" + row["sha"])
        if blob.get("encoding") != "base64" or blob.get("sha") != row["sha"]:
            raise ValueError("Unexpected Git blob")
        raw = base64.b64decode(blob["content"].replace("\n", ""), validate=True)
        if len(raw) != row["size"] or blob.get("size") != len(raw) or hashlib.sha1(b"blob " + str(len(raw)).encode() + b"\0" + raw).hexdigest() != row["sha"]:
            raise ValueError("Git blob integrity failed")
        try:
            text = raw.decode("utf-8", errors="strict")
        except UnicodeDecodeError:
            excluded.append({"path": path, "reason": "not UTF-8"})
            continue
        if "\0" in text:
            excluded.append({"path": path, "reason": "binary"})
            continue
        if SECRET.search(text) or ASSIGNMENT.search(text):
            # Omit the WHOLE original file and retain an explicit coverage gap.
            # Never write its content or alter a blob while keeping its citation.
            excluded.append({"path": path, "reason": "credential-like content withheld"})
            continue
        total += len(raw)
        if total > MAX_BYTES or len(files) >= 2000:
            raise ValueError("Source inventory exceeds bounded import")
        files.append({"path": path, "blob": row["sha"], "sha256": hashlib.sha256(raw).hexdigest(), "text": text})
    if not files:
        raise ValueError("No runtime code")
    result = {"schemaVersion": 1, "repository": repository, "requestedRef": ref, "commit": sha,
              "files": files, "exportEvidence": {"tree": tree_sha, "method": "GET-only pinned GitHub tree and verified original blobs",
              "excluded": excluded, "selectedCodeBytes": total, "documentsPrimary": False}}
    raw = json.dumps(result, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    if len(raw) > MAX_BYTES:
        raise ValueError("Encoded package too large")
    return raw


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--ref", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if not args.output.is_absolute() or args.output.suffix != ".parrotrepo" or args.output.exists():
        raise ValueError("Use a new absolute .parrotrepo path")
    data = export(args.repository, args.ref)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".code-export-", dir=args.output.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.link(temporary, args.output)  # exclusive publication, no overwrite
    finally:
        os.unlink(temporary)
    if args.output.read_bytes() != data:
        raise RuntimeError("Export readback failed")
    package = json.loads(data)
    print(json.dumps({"status": "CODE_SNAPSHOT_EXPORTED_NOT_NATIVE_ACCEPTANCE", "commit": package["commit"],
                      "files": len(package["files"]), "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
                      "excluded": len(package["exportEvidence"]["excluded"])}))


if __name__ == "__main__":
    main()
