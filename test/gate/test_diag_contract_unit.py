#!/usr/bin/env python3
"""诊断门禁校验器的反例与合法输入对照。"""

import json
import unittest

from test_diag_contract import Failure, check_arm_collision, check_duplicate_decl, parse_jsonl


def row(code=4009, off=3, refs=None, args=None):
    return {"unit": "a::b", "code": code, "severity": "error", "span": {"off": off, "len": 1},
            "refs": [] if refs is None else refs, "args": {} if args is None else args}


def encode(*rows):
    return "".join(json.dumps(item, ensure_ascii=False) + "\n" for item in rows).encode()


class DiagContractTests(unittest.TestCase):
    def test_accepts_qualified_unit_and_reference_domains(self):
        value = row(refs=[{"kind": "def", "id": 2**32 - 1}, {"kind": "builtin", "id": 8},
                          {"kind": "import", "id": [2, 900]}, {"kind": "field", "id": 0},
                          {"kind": "variant", "id": 9}, {"kind": "local", "id": 70000}],
                    args={"label": "有\u2028效", "format": "name\\literal"})
        self.assertEqual(parse_jsonl(encode(value)), [value])

    def test_rejects_wrong_id_domains_and_widths(self):
        for kind, identity in [("name", 2), ("scope", 2), ("import", [1, True]),
                               ("import", [65536, 1]), ("field", 65536), ("def", -1)]:
            with self.subTest(kind=kind, identity=identity), self.assertRaises(Failure):
                parse_jsonl(encode(row(refs=[{"kind": kind, "id": identity}])))

    def test_rejects_boolean_offset_and_code(self):
        for value in [row(code=True), row(off=False)]:
            with self.assertRaises(Failure):
                parse_jsonl(encode(value))

    def test_rejects_host_information(self):
        cases = [dict(row(), unit="/tmp/source.yak"), dict(row(), unit="Z:source.yak"),
                 row(args={"nested": [{"host_pointer": 10}]}),
                 row(args={"nested": ["/tmp/source.yak"]}),
                 row(args={"nested": ["D:\\source.yak"]}), row(args={"nested": {"timestamp": 1}})]
        for value in cases:
            with self.subTest(value=value), self.assertRaises(Failure):
                parse_jsonl(encode(value))

    def test_rejects_duplicate_keys_and_non_json_constants(self):
        valid = encode(row())
        for raw in [valid.replace(b'"code": 4009', b'"code": 1, "code": 4009'),
                    valid.replace(b'"args": {}', b'"args": {"a": {"b": 1, "b": 2}}'),
                    valid.replace(b'"args": {}', b'"args": {"a": NaN}')]:
            with self.assertRaises(Failure):
                parse_jsonl(raw)

    def test_rejects_wrong_order_and_line_endings(self):
        valid = encode(row())
        for raw in [encode(row(off=2), row(off=1)), encode(row(code=4009), row(code=4001)),
                    b"", valid[:-1], valid + b"\n", valid.replace(b"\n", b"\r\n")]:
            with self.assertRaises(Failure):
                parse_jsonl(raw)

    def test_duplicate_fixture_requires_exact_defs_and_spans(self):
        refs = [{"kind": "def", "id": 2}, {"kind": "def", "id": 3}]
        original = (dict(row(), span={"off": 184, "len": 0}),
                    dict(row(4001, refs=refs), span={"off": 207, "len": 18}),
                    dict(row(), span={"off": 207, "len": 0}))
        check_duplicate_decl(parse_jsonl(encode(*original)), "a::b")
        for patch in [dict(refs=[]), dict(refs=[refs[0], refs[0]]), dict(refs=refs[::-1]),
                      dict(refs=[refs[0], {"kind": "def", "id": 4}]),
                      dict(refs=[refs[0], {"kind": "local", "id": 3}]),
                      dict(span={"off": 206, "len": 18}), dict(span={"off": 207, "len": 17})]:
            with self.subTest(patch=patch), self.assertRaises(Failure):
                check_duplicate_decl(parse_jsonl(encode(original[0], dict(original[1], **patch),
                                                        original[2])), "a::b")


    def test_arm_collision_requires_old_and_rejected_defs(self):
        refs = [{"kind": "def", "id": 5}, {"kind": "def", "id": 6}]
        original = dict(row(4010, refs=refs), span={"off": 353, "len": 22})
        check_arm_collision(parse_jsonl(encode(original)), "a::b")
        for patch in [dict(code=4001), dict(refs=refs[::-1]),
                      dict(refs=[refs[0], {"kind": "local", "id": 6}]),
                      dict(span={"off": 353, "len": 21})]:
            with self.subTest(patch=patch), self.assertRaises(Failure):
                check_arm_collision(parse_jsonl(encode(dict(original, **patch))), "a::b")
        with self.assertRaises(Failure):
            check_arm_collision(parse_jsonl(encode(original, original)), "a::b")


if __name__ == "__main__":
    unittest.main()
