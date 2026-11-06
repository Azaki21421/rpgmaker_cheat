#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tests/test_all.py — End-to-end unit and integration tests for RPGMCheat.
Covers:
  - Lossless Ruby Marshal 4.8 Codec
  - RGSSAD v1 / v2 / v3 archive parsing, extraction, patching and reverting
  - MV / MZ project auto-detection, installation and removal
  - Loose RGSS Scripts.* injection and removal
"""

import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from inject import (
    MarshalReader,
    MarshalWriter,
    RgssArchive,
    RubyStr,
    RubySym,
    discover_from_path,
    inject_into_scripts_bytes,
    install_js_target,
    install_rgss_target,
    rgss_xor_bytes,
    uninstall_js_target,
    uninstall_rgss_target,
)


def create_mock_rgss3a(archive_path, entries_dict):
    seed = 0x12345678
    key = (seed * 9 + 3) & 0xFFFFFFFF
    k_bytes = (key & 0xFF, (key >> 8) & 0xFF, (key >> 16) & 0xFF, (key >> 24) & 0xFF)

    index_size = sum(16 + len(name.encode("utf-8")) for name in entries_dict) + 4
    current_data_pos = 12 + index_size

    entry_infos = []
    for name, payload in entries_dict.items():
        name_bytes = name.encode("utf-8")
        subkey = 0xABCD1234
        entry_infos.append({
            "name_bytes": name_bytes,
            "offset": current_data_pos,
            "size": len(payload),
            "subkey": subkey,
            "payload": payload,
        })
        current_data_pos += len(payload)

    with open(archive_path, "wb") as f:
        f.write(b"RGSSAD\x00\x03")
        f.write(struct.pack("<I", seed))
        for e in entry_infos:
            f.write(
                struct.pack(
                    "<IIII",
                    e["offset"] ^ key,
                    e["size"] ^ key,
                    e["subkey"] ^ key,
                    len(e["name_bytes"]) ^ key,
                )
            )
            enc_name = bytearray(len(e["name_bytes"]))
            for i in range(len(e["name_bytes"])):
                enc_name[i] = e["name_bytes"][i] ^ k_bytes[i & 3]
            f.write(enc_name)
        f.write(struct.pack("<I", 0 ^ key))

        for e in entry_infos:
            f.write(rgss_xor_bytes(e["payload"], e["subkey"]))


def create_mock_rgssad_v1(archive_path, entries_dict):
    key = 0xDEADCAFE
    with open(archive_path, "wb") as f:
        f.write(b"RGSSAD\x00\x01")
        for name, payload in entries_dict.items():
            name_bytes = name.encode("utf-8")
            nlen = len(name_bytes)
            f.write(struct.pack("<I", nlen ^ key))
            key = (key * 7 + 3) & 0xFFFFFFFF

            enc_name = bytearray(nlen)
            for i in range(nlen):
                enc_name[i] = name_bytes[i] ^ (key & 0xFF)
                key = (key * 7 + 3) & 0xFFFFFFFF
            f.write(enc_name)

            f.write(struct.pack("<I", len(payload) ^ key))
            key = (key * 7 + 3) & 0xFFFFFFFF

            f.write(rgss_xor_bytes(payload, key))


class TestRPGMCheat(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        cls.cheat_js = os.path.join(cls.root_dir, "cheat.js")
        cls.cheat_rb = os.path.join(cls.root_dir, "cheat.rb")

    def test_syntax_cheat_files(self):
        self.assertTrue(os.path.isfile(self.cheat_js))
        self.assertTrue(os.path.isfile(self.cheat_rb))

        if shutil.which("node"):
            res = subprocess.run(["node", "-c", self.cheat_js], capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, f"Node syntax error in cheat.js: {res.stderr}")

        if shutil.which("ruby"):
            res = subprocess.run(["ruby", "-c", self.cheat_rb], capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, f"Ruby syntax error in cheat.rb: {res.stderr}")

    def test_marshal_roundtrip(self):
        scripts = [
            [12345, RubyStr(b"Vocab", [(RubySym(b"E"), True)]), RubyStr(zlib.compress(b"# vocab"), [])],
            [67890, RubyStr(b"Main", [(RubySym(b"E"), True)]), RubyStr(zlib.compress(b"# main\nrgss_main"), [])],
        ]
        dumped = MarshalWriter().dump(scripts)
        loaded = MarshalReader(dumped).load()
        self.assertEqual(len(loaded), 2)
        self.assertEqual(loaded[0][0], 12345)
        self.assertEqual(loaded[0][1].raw, b"Vocab")
        self.assertEqual(loaded[1][1].raw, b"Main")

        new_data, status = inject_into_scripts_bytes(dumped, "Scripts.rvdata2", b"# cheat", False)
        self.assertIn("inserted above Main", status)
        loaded2 = MarshalReader(new_data).load()
        self.assertEqual(len(loaded2), 3)
        self.assertEqual(loaded2[1][1].raw, b"[CheatMenu]")

    def test_rgss3a_patching_and_revert(self):
        tmp = tempfile.mkdtemp()
        try:
            arc_path = os.path.join(tmp, "Game.rgss3a")
            scripts = [
                [10, RubyStr(b"Vocab", [(RubySym(b"E"), True)]), RubyStr(zlib.compress(b"# vocab"), [])],
                [20, RubyStr(b"Main", [(RubySym(b"E"), True)]), RubyStr(zlib.compress(b"# main\nrgss_main"), [])],
            ]
            scripts_bytes = MarshalWriter().dump(scripts)
            create_mock_rgss3a(arc_path, {
                "Data/Scripts.rvdata2": scripts_bytes,
                "Data/System.rvdata2": b"system_dummy",
            })

            target = discover_from_path(tmp)
            self.assertIsNotNone(target)
            self.assertEqual(target["kind"], "rgss")

            # Install
            ret = install_rgss_target(target, self.cheat_rb, standalone=False)
            self.assertEqual(ret, 0)

            arc = RgssArchive(arc_path)
            s_entry = arc.find_scripts_entry()
            patched_bytes = arc.read_entry_bytes(s_entry)
            loaded = MarshalReader(patched_bytes).load()
            self.assertEqual(len(loaded), 3)
            self.assertEqual(loaded[1][1].raw, b"[CheatMenu]")

            # Uninstall
            ret = uninstall_rgss_target(target, self.cheat_rb)
            self.assertEqual(ret, 0)
            arc_rev = RgssArchive(arc_path)
            rev_bytes = arc_rev.read_entry_bytes(arc_rev.find_scripts_entry())
            self.assertEqual(rev_bytes, scripts_bytes)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_rgssad_v1_patching_and_revert(self):
        tmp = tempfile.mkdtemp()
        try:
            arc_path = os.path.join(tmp, "Game.rgssad")
            scripts = [
                [1, RubyStr(b"Vocab", []), RubyStr(zlib.compress(b"# vocab"), [])],
                [2, RubyStr(b"Main", []), RubyStr(zlib.compress(b"# main\n$scene = Scene_Map.new"), [])],
            ]
            scripts_bytes = MarshalWriter().dump(scripts)
            create_mock_rgssad_v1(arc_path, {
                "Data/Scripts.rxdata": scripts_bytes,
                "Data/System.rxdata": b"system_dummy_content",
            })

            target = discover_from_path(tmp)
            self.assertIsNotNone(target)
            self.assertEqual(target["kind"], "rgss")

            # Install
            ret = install_rgss_target(target, self.cheat_rb, standalone=False)
            self.assertEqual(ret, 0)

            arc = RgssArchive(arc_path)
            s_entry = arc.find_scripts_entry()
            patched_bytes = arc.read_entry_bytes(s_entry)
            loaded = MarshalReader(patched_bytes).load()
            self.assertEqual(len(loaded), 3)

            # Uninstall
            ret = uninstall_rgss_target(target, self.cheat_rb)
            self.assertEqual(ret, 0)
            arc_rev = RgssArchive(arc_path)
            rev_bytes = arc_rev.read_entry_bytes(arc_rev.find_scripts_entry())
            self.assertEqual(rev_bytes, scripts_bytes)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_mv_and_mz_injection(self):
        # MV test (www/js/plugins.js)
        tmp_mv = tempfile.mkdtemp()
        try:
            js_dir = os.path.join(tmp_mv, "www", "js")
            os.makedirs(os.path.join(js_dir, "plugins"))
            pjs = os.path.join(js_dir, "plugins.js")
            with open(pjs, "w", encoding="utf-8") as f:
                f.write("var $plugins = [];\n")

            target = discover_from_path(tmp_mv)
            self.assertIsNotNone(target)
            self.assertEqual(target["kind"], "js")
            self.assertEqual(install_js_target(target, self.cheat_js), 0)

            with open(pjs, "r", encoding="utf-8") as f:
                self.assertIn("RPGMCheat", f.read())

            self.assertEqual(uninstall_js_target(target), 0)
            with open(pjs, "r", encoding="utf-8") as f:
                self.assertNotIn("RPGMCheat", f.read())
        finally:
            shutil.rmtree(tmp_mv, ignore_errors=True)

        # MZ test (js/plugins.js + data/System.json)
        tmp_mz = tempfile.mkdtemp()
        try:
            js_dir = os.path.join(tmp_mz, "js")
            data_dir = os.path.join(tmp_mz, "data")
            os.makedirs(os.path.join(js_dir, "plugins"))
            os.makedirs(data_dir)
            with open(os.path.join(data_dir, "System.json"), "w") as f:
                f.write("{}")
            pjs = os.path.join(js_dir, "plugins.js")
            with open(pjs, "w", encoding="utf-8") as f:
                f.write("var $plugins = [];\n")

            target = discover_from_path(tmp_mz)
            self.assertIsNotNone(target)
            self.assertEqual(target["kind"], "js")
            self.assertEqual(install_js_target(target, self.cheat_js), 0)

            with open(pjs, "r", encoding="utf-8") as f:
                self.assertIn("RPGMCheat", f.read())

            self.assertEqual(uninstall_js_target(target), 0)
            with open(pjs, "r", encoding="utf-8") as f:
                self.assertNotIn("RPGMCheat", f.read())
        finally:
            shutil.rmtree(tmp_mz, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
