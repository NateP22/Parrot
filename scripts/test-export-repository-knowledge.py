#!/usr/bin/env python3
import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("repo_export", Path(__file__).with_name("export-repository-knowledge.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ExportTests(unittest.TestCase):
    def fixture(self, content=b"const includeLinks = false;\r\n", truncate=False, mode="100644"):
        commit, tree = "a" * 40, "b" * 40
        blob = hashlib.sha1(b"blob " + str(len(content)).encode() + b"\0" + content).hexdigest()
        responses = {"/repos/fictional/atlas/commits/main": {"sha": commit, "commit": {"tree": {"sha": tree}}},
            "/repos/fictional/atlas/git/trees/" + tree + "?recursive=1": {"sha": tree, "truncated": truncate,
            "tree": [{"path": "client/settings.json", "type": "blob", "mode": mode, "sha": blob, "size": len(content)}]},
            "/repos/fictional/atlas/git/blobs/" + blob: {"sha": blob, "size": len(content), "encoding": "base64", "content": base64.b64encode(content).decode()}}
        return responses

    def test_original_bytes_and_pinned_commit(self):
        responses = self.fixture()
        result = json.loads(module.export("fictional/atlas", "main", api=responses.__getitem__))
        self.assertEqual(result["commit"], "a" * 40)
        self.assertEqual(result["files"][0]["text"], "const includeLinks = false;\r\n")

    def test_truncated_inventory_rejected(self):
        with self.assertRaises(ValueError):
            module.export("fictional/atlas", "main", api=self.fixture(truncate=True).__getitem__)

    def test_symlink_not_source(self):
        with self.assertRaises(ValueError):
            module.export("fictional/atlas", "main", api=self.fixture(mode="120000").__getitem__)

    def test_blob_mismatch_rejected(self):
        responses = self.fixture()
        next(v for k, v in responses.items() if "/git/blobs/" in k)["content"] = base64.b64encode(b"tampered").decode()
        with self.assertRaises(ValueError):
            module.export("fictional/atlas", "main", api=responses.__getitem__)

    def test_secret_never_exported(self):
        with self.assertRaises(ValueError):
            module.export("fictional/atlas", "main", api=self.fixture(b"sk-ant-" + b"X" * 30).__getitem__)

    def test_unsafe_paths(self):
        for path in ("/x.js", "../x.js", "x/../x.js", "x//x.js", ".env.json", "secrets/x.json", "x.min.js", "tests/a.js", "vendor/x.js", "token.json", "api-keys.json", "keychain.json", "output/qa/installed-backup/client/index.html", "archives/old/host/a.jsx", "snapshots/client/a.js", "server/scripts/fixture.mjs"):
            self.assertFalse(module.permits(path), path)

    def test_additional_credential_families(self):
        for marker in ("sk-" + "Q" * 30, "xoxb-" + "Q" * 30, "AIza" + "Q" * 32, "AKIA" + "Q" * 16, 'const password = "fictionalLongValue123";'):
            with self.assertRaises(ValueError):
                module.export("fictional/atlas", "main", api=self.fixture(marker.encode()).__getitem__)

    def test_withheld_file_is_a_coverage_gap_never_redacted_code(self):
        responses = self.fixture()
        tree = next(v for k, v in responses.items() if "/git/trees/" in k)
        raw = b"sk-" + b"Q" * 30
        blob = hashlib.sha1(b"blob " + str(len(raw)).encode() + b"\0" + raw).hexdigest()
        tree["tree"].append({"path": "client/connection.js", "type": "blob", "mode": "100644", "sha": blob, "size": len(raw)})
        responses["/repos/fictional/atlas/git/blobs/" + blob] = {"sha": blob, "size": len(raw), "encoding": "base64", "content": base64.b64encode(raw).decode()}
        encoded = module.export("fictional/atlas", "main", api=responses.__getitem__)
        self.assertNotIn(raw, encoded)
        package = json.loads(encoded)
        self.assertEqual(len(package["files"]), 1)
        self.assertEqual(package["exportEvidence"]["excluded"], [{"path": "client/connection.js", "reason": "credential-like content withheld"}])

    def test_nested_same_basename_allowed(self):
        self.assertTrue(module.permits("client/settings.json"))
        self.assertTrue(module.permits("host/settings.json"))
        self.assertTrue(module.permits("server/runtime.mjs"))
        self.assertTrue(module.permits("host/shared.jsxinc"))

    def test_only_get_endpoints_and_ref_resolved_once(self):
        responses = self.fixture()
        calls = []
        def api(endpoint):
            calls.append(endpoint)
            return responses[endpoint]
        module.export("fictional/atlas", "main", api=api)
        self.assertEqual(sum("/commits/" in x for x in calls), 1)
        self.assertEqual(len(calls), 3)


if __name__ == "__main__":
    unittest.main()
