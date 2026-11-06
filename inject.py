#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
inject.py — Universal Zero-Ruby Installer, Uninstaller & RGSS Decryptor
Works on any system with Python 3 (standard library only, no Ruby required).

Supported RPG Maker engines & encrypted archives:
  - RPG Maker MV     (www/js/plugins.js, www/index.html, www/data/*.json) -> cheat.js
  - RPG Maker MZ     (js/plugins.js, index.html, data/*.json)             -> cheat.js
  - RPG Maker VX Ace (Data/Scripts.rvdata2 OR packed *.rgss3a archive!)   -> cheat.rb
  - RPG Maker VX     (Data/Scripts.rvdata  OR packed *.rgss2a archive!)   -> cheat.rb
  - RPG Maker XP     (Data/Scripts.rxdata  OR packed *.rgssad archive!)   -> cheat.rb

Usage:
  python3 inject.py "/path/to/GameFolder"               # Install cheat (works on .rgss3a too!)
  python3 inject.py --standalone "/path/to/GameFolder"  # Embed inside Scripts.* only (RGSS)
  python3 inject.py --decrypt "/path/to/GameFolder"     # Unpack all files from .rgss3a/.rgss2a/.rgssad
  python3 inject.py --remove "/path/to/GameFolder"      # Uninstall cheat & restore original files
"""

import json
import os
import random
import re
import shutil
import struct
import sys
import zlib

SECTION_TAG = "[CheatMenu]"
JS_PLUGIN_NAME = "RPGMCheat"
JS_PLUGIN_ENTRY = '{"name":"RPGMCheat","status":true,"description":"Universal Cheat Menu [F8]","parameters":{}}'
HTML_SCRIPT_TAG = '<script type="text/javascript" src="js/rpgm_cheat.js"></script>'

SCRIPT_FILES = ("Scripts.rvdata2", "Scripts.rvdata", "Scripts.rxdata")
ARCHIVE_EXTS = (".rgss3a", ".rgss2a", ".rgssad")
SUBDIR_PARENTS = {
    "www", "data", "js", "plugins", "audio", "img", "movies",
    "save", "locales", "swiftshader", "fonts", "system", "graphics"
}
SKIP_SCAN_DIRS = {
    "img", "audio", "movies", "locales", "swiftshader", "save",
    "graphics", "fonts", "node_modules", ".git", "__pycache__"
}

FIXNUM_MAX = (1 << 30) - 1
FIXNUM_MIN = -(1 << 30)

_BLOCK_WORDS = 16384
_BLOCK_BYTES = _BLOCK_WORDS * 4
_PACK_16K = struct.Struct(f"<{_BLOCK_WORDS}I").pack


# ============================================================================
# RGSSAD / RGSS2A / RGSS3A Archive Decryptor & Surgical Patcher
# ============================================================================

def rgss_xor_bytes(data, initial_key):
    """Symmetric RGSS LCG XOR cipher on an in-memory byte buffer."""
    size = len(data)
    if size == 0:
        return b""
    out = bytearray(size)
    k = initial_key & 0xFFFFFFFF
    offset = 0

    while size - offset >= _BLOCK_BYTES:
        ks = [0] * _BLOCK_WORDS
        for i in range(_BLOCK_WORDS):
            ks[i] = k
            k = (k * 7 + 3) & 0xFFFFFFFF
        ks_bytes = _PACK_16K(*ks)
        c_int = int.from_bytes(data[offset:offset + _BLOCK_BYTES], "little")
        k_int = int.from_bytes(ks_bytes, "little")
        out[offset:offset + _BLOCK_BYTES] = (c_int ^ k_int).to_bytes(_BLOCK_BYTES, "little")
        offset += _BLOCK_BYTES

    rem = size - offset
    if rem > 0:
        words = (rem + 3) // 4
        ks = [0] * words
        for i in range(words):
            ks[i] = k
            k = (k * 7 + 3) & 0xFFFFFFFF
        ks_bytes = struct.pack(f"<{words}I", *ks)[:rem]
        c_int = int.from_bytes(data[offset:], "little")
        k_int = int.from_bytes(ks_bytes, "little")
        out[offset:] = (c_int ^ k_int).to_bytes(rem, "little")

    return bytes(out)


def decode_rgss_name(raw_bytes):
    for enc in ("utf-8", "cp932", "cp1252"):
        try:
            return raw_bytes.decode(enc)
        except UnicodeDecodeError:
            pass
    return raw_bytes.decode("utf-8", errors="replace")


def sanitize_rel_path(entry_name):
    norm = entry_name.replace("\\", "/").lstrip("/")
    norm = re.sub(r"^[A-Za-z]:/+", "", norm)
    parts = [p for p in norm.split("/") if p and p != "."]
    if not parts or ".." in parts:
        raise ValueError(f"Unsafe archive entry path rejected: {entry_name!r}")
    return os.path.join(*parts)


class RgssArchive(object):
    """Stream-based reader, unpacker, and patcher for RGSSAD v1/v2/v3 archives."""

    def __init__(self, path):
        self.path = path
        self.file_size = os.path.getsize(path)
        self.version = 0
        self.master_key = 0
        self.entries = []
        self._parse_index()

    def _parse_index(self):
        with open(self.path, "rb") as f:
            hdr = f.read(8)
            if len(hdr) < 8 or hdr[:7] != b"RGSSAD\x00":
                raise ValueError(f"Not a valid RGSSAD archive (header mismatch): {self.path}")
            self.version = hdr[7]

            if self.version == 3:
                seed_raw = f.read(4)
                if len(seed_raw) < 4:
                    raise ValueError("Truncated RGSS3A key header.")
                seed = struct.unpack("<I", seed_raw)[0]
                key = (seed * 9 + 3) & 0xFFFFFFFF
                self.master_key = key

                while True:
                    entry_pos = f.tell()
                    off_raw = f.read(4)
                    if len(off_raw) < 4:
                        break
                    offset = struct.unpack("<I", off_raw)[0] ^ key
                    if offset == 0:
                        break
                    rest = f.read(12)
                    if len(rest) < 12:
                        raise ValueError("Truncated RGSS3A directory entry.")
                    r_size, r_subkey, r_nlen = struct.unpack("<III", rest)
                    size = r_size ^ key
                    subkey = r_subkey ^ key
                    nlen = r_nlen ^ key

                    if nlen > 4096 or offset < 16 or offset + size > self.file_size:
                        raise ValueError(
                            "Archive uses a non-standard custom key protection and cannot be read with standard RGSS keys."
                        )

                    enc_name = f.read(nlen)
                    if len(enc_name) < nlen:
                        raise ValueError("Truncated RGSS3A entry filename.")
                    dec_name = bytearray(nlen)
                    k_bytes = (key & 0xFF, (key >> 8) & 0xFF, (key >> 16) & 0xFF, (key >> 24) & 0xFF)
                    for i in range(nlen):
                        dec_name[i] = enc_name[i] ^ k_bytes[i & 3]

                    self.entries.append({
                        "name": decode_rgss_name(bytes(dec_name)),
                        "offset": offset,
                        "size": size,
                        "subkey": subkey,
                        "header_pos": entry_pos,
                    })

            elif self.version in (1, 2):
                key = 0xDEADCAFE
                self.master_key = key
                while f.tell() < self.file_size:
                    entry_pos = f.tell()
                    nl_raw = f.read(4)
                    if not nl_raw:
                        break
                    if len(nl_raw) < 4:
                        raise ValueError("Truncated RGSSAD v1 entry header.")
                    nlen = struct.unpack("<I", nl_raw)[0] ^ key
                    key = (key * 7 + 3) & 0xFFFFFFFF

                    if nlen == 0 or nlen > 4096 or f.tell() + nlen + 4 > self.file_size:
                        raise ValueError(
                            "Archive uses a non-standard custom key protection and cannot be read with standard RGSS keys."
                        )

                    enc_name = f.read(nlen)
                    dec_name = bytearray(nlen)
                    for i in range(nlen):
                        dec_name[i] = enc_name[i] ^ (key & 0xFF)
                        key = (key * 7 + 3) & 0xFFFFFFFF

                    sz_raw = f.read(4)
                    size_xor_key = key
                    size = struct.unpack("<I", sz_raw)[0] ^ key
                    key = (key * 7 + 3) & 0xFFFFFFFF

                    data_offset = f.tell()
                    if data_offset + size > self.file_size:
                        raise ValueError("Truncated RGSSAD v1 entry payload.")

                    self.entries.append({
                        "name": decode_rgss_name(bytes(dec_name)),
                        "offset": data_offset,
                        "size": size,
                        "subkey": key,
                        "header_pos": entry_pos,
                        "raw_name_header": nl_raw + enc_name,
                        "size_xor_key": size_xor_key,
                    })
                    f.seek(data_offset + size)
            else:
                raise ValueError(f"Unsupported RGSSAD version: {self.version}")

    def find_scripts_entry(self, custom_rel=None):
        targets = []
        if custom_rel:
            targets.append(custom_rel.replace("/", "\\").lower())
        targets.extend([
            "data\\scripts.rvdata2",
            "data\\scripts.rvdata",
            "data\\scripts.rxdata",
            "scripts.rvdata2",
            "scripts.rvdata",
            "scripts.rxdata",
        ])
        by_norm = {e["name"].replace("/", "\\").lower(): e for e in self.entries}
        for t in targets:
            if t in by_norm:
                return by_norm[t]
        return None

    def read_entry_bytes(self, entry):
        with open(self.path, "rb") as f:
            f.seek(entry["offset"])
            enc = f.read(entry["size"])
        return rgss_xor_bytes(enc, entry["subkey"])

    def extract_all(self, dest_dir):
        total = len(self.entries)
        with open(self.path, "rb") as f:
            for idx, entry in enumerate(self.entries, 1):
                rel = sanitize_rel_path(entry["name"])
                out_path = os.path.join(dest_dir, rel)
                os.makedirs(os.path.dirname(out_path), exist_ok=True)

                f.seek(entry["offset"])
                rem = entry["size"]
                k = entry["subkey"] & 0xFFFFFFFF

                with open(out_path, "wb") as out_f:
                    while rem > 0:
                        take = min(rem, _BLOCK_BYTES)
                        chunk = f.read(take)
                        if not chunk:
                            break
                        words = (len(chunk) + 3) // 4
                        ks = [0] * words
                        for i in range(words):
                            ks[i] = k
                            k = (k * 7 + 3) & 0xFFFFFFFF
                        ks_bytes = (_PACK_16K(*ks) if words == _BLOCK_WORDS else struct.pack(f"<{words}I", *ks))[:len(chunk)]
                        c_int = int.from_bytes(chunk, "little")
                        k_int = int.from_bytes(ks_bytes, "little")
                        out_f.write((c_int ^ k_int).to_bytes(len(chunk), "little"))
                        rem -= len(chunk)

                if idx == 1 or idx % 200 == 0 or idx == total:
                    print(f"[Decryptor] Extracted {idx}/{total} files...")

    def patch_scripts_entry(self, entry, new_plain_bytes):
        enc_payload = rgss_xor_bytes(new_plain_bytes, entry["subkey"])
        new_size = len(enc_payload)

        if self.version == 3:
            meta_bak = self.path + ".rpgmcheat_bak"
            if os.path.isfile(meta_bak):
                with open(meta_bak, "rb") as f:
                    meta = json.loads(f.read().decode("utf-8"))
                append_offset = int(meta["orig_archive_size"])
            else:
                append_offset = self.file_size
                meta = {
                    "version": 3,
                    "orig_archive_size": self.file_size,
                    "header_pos": entry["header_pos"],
                    "orig_offset": entry["offset"],
                    "orig_size": entry["size"],
                }
                with open(meta_bak, "wb") as f:
                    f.write(json.dumps(meta, indent=2).encode("utf-8"))

            with open(self.path, "r+b") as f:
                f.seek(append_offset)
                f.write(enc_payload)
                f.truncate(append_offset + new_size)
                f.seek(entry["header_pos"])
                f.write(struct.pack("<II", append_offset ^ self.master_key, new_size ^ self.master_key))
            self.file_size = append_offset + new_size
        else:
            bak_path = self.path + ".bak"
            if not os.path.exists(bak_path):
                shutil.copy2(self.path, bak_path)
                print(f"[Backup] Created archive backup: {bak_path}")

            tmp_path = self.path + ".tmp"
            with open(self.path, "rb") as src, open(tmp_path, "wb") as dst:
                dst.write(src.read(8))
                for e in self.entries:
                    if e is entry:
                        dst.write(e["raw_name_header"])
                        dst.write(struct.pack("<I", new_size ^ e["size_xor_key"]))
                        dst.write(enc_payload)
                    else:
                        src.seek(e["header_pos"])
                        total_raw = (e["offset"] - e["header_pos"]) + e["size"]
                        rem = total_raw
                        while rem > 0:
                            buf = src.read(min(rem, 65536))
                            if not buf:
                                break
                            dst.write(buf)
                            rem -= len(buf)
            os.replace(tmp_path, self.path)
            self.file_size = os.path.getsize(self.path)

    @staticmethod
    def revert_patch(archive_path):
        meta_bak = archive_path + ".rpgmcheat_bak"
        if os.path.isfile(meta_bak):
            with open(meta_bak, "rb") as f:
                meta = json.loads(f.read().decode("utf-8"))
            with open(archive_path, "r+b") as f:
                f.seek(8)
                seed = struct.unpack("<I", f.read(4))[0]
                key = (seed * 9 + 3) & 0xFFFFFFFF
                f.seek(int(meta["header_pos"]))
                f.write(struct.pack("<II", int(meta["orig_offset"]) ^ key, int(meta["orig_size"]) ^ key))
                f.truncate(int(meta["orig_archive_size"]))
            os.remove(meta_bak)
            return True

        bak_path = archive_path + ".bak"
        if os.path.isfile(bak_path):
            with open(archive_path, "rb") as f:
                hdr = f.read(8)
            if len(hdr) == 8 and hdr[:7] == b"RGSSAD\x00" and hdr[7] in (1, 2):
                os.replace(bak_path, archive_path)
                return True
        return False


# ============================================================================
# Lossless Ruby Marshal 4.8 Codec (for XP / VX / VX Ace Scripts.*)
# ============================================================================

class RubySym(object):
    __slots__ = ("raw",)

    def __init__(self, raw):
        self.raw = raw


class RubyStr(object):
    __slots__ = ("raw", "ivars")

    def __init__(self, raw, ivars=None):
        self.raw = raw
        self.ivars = ivars if ivars is not None else []


class MarshalReader(object):
    def __init__(self, data):
        self.data = data
        self.pos = 0
        self.symbols = []
        self.objects = []

    def read_byte(self):
        if self.pos >= len(self.data):
            raise ValueError("Unexpected EOF in Marshal stream")
        b = self.data[self.pos]
        self.pos += 1
        return b

    def read_bytes(self, n):
        end = self.pos + n
        if end > len(self.data):
            raise ValueError("Unexpected EOF while reading byte slice")
        chunk = self.data[self.pos:end]
        self.pos = end
        return chunk

    def read_long(self):
        b = self.read_byte()
        c = b if b < 128 else b - 256
        if c == 0:
            return 0
        if c > 0:
            if c > 4:
                return c - 5
            val = 0
            for i in range(c):
                val |= self.read_byte() << (8 * i)
            return val
        else:
            if c < -4:
                return c + 5
            cnt = -c
            val = 0xFFFFFFFF
            for i in range(cnt):
                val &= ~(0xFF << (8 * i))
                val |= self.read_byte() << (8 * i)
            if val >= 0x80000000:
                val -= 0x100000000
            return val

    def load(self):
        major = self.read_byte()
        minor = self.read_byte()
        if major != 4 or minor != 8:
            raise ValueError(f"Unsupported Marshal version: {major}.{minor} (expected 4.8)")
        return self.read_value()

    def read_value(self):
        tag = self.read_byte()

        if tag == 0x30:
            return None
        if tag == 0x54:
            return True
        if tag == 0x46:
            return False
        if tag == 0x69:
            return self.read_long()

        if tag == 0x3A:
            ln = self.read_long()
            sym = RubySym(self.read_bytes(ln))
            self.symbols.append(sym)
            return sym

        if tag == 0x3B:
            idx = self.read_long()
            return self.symbols[idx]

        if tag == 0x40:
            idx = self.read_long()
            target = self.objects[idx]
            if isinstance(target, RubyStr):
                return RubyStr(target.raw, list(target.ivars))
            return target

        if tag == 0x6C:
            sign_byte = self.read_byte()
            word_len = self.read_long()
            raw_num = self.read_bytes(word_len * 2)
            val = int.from_bytes(raw_num, "little")
            if sign_byte == 0x2D:
                val = -val
            self.objects.append(val)
            return val

        if tag == 0x49:
            inner = self.read_value()
            ivar_count = self.read_long()
            ivars = []
            for _ in range(ivar_count):
                k = self.read_value()
                v = self.read_value()
                ivars.append((k, v))
            if isinstance(inner, RubyStr):
                inner.ivars.extend(ivars)
            return inner

        if tag == 0x22:
            ln = self.read_long()
            s = RubyStr(self.read_bytes(ln))
            self.objects.append(s)
            return s

        if tag == 0x5B:
            ln = self.read_long()
            arr = []
            self.objects.append(arr)
            for _ in range(ln):
                arr.append(self.read_value())
            return arr

        raise ValueError(f"Unsupported Marshal tag byte: 0x{tag:02X}")


class MarshalWriter(object):
    def __init__(self):
        self.buf = bytearray(b"\x04\x08")
        self.symbols = {}

    def write_long(self, x):
        if x == 0:
            self.buf.append(0x00)
        elif 0 < x < 123:
            self.buf.append(x + 5)
        elif -124 < x < 0:
            self.buf.append((x - 5) & 0xFF)
        elif x >= 123:
            if x <= 0xFF:
                self.buf.extend((1, x))
            elif x <= 0xFFFF:
                self.buf.extend((2, x & 0xFF, (x >> 8) & 0xFF))
            elif x <= 0xFFFFFF:
                self.buf.extend((3, x & 0xFF, (x >> 8) & 0xFF, (x >> 16) & 0xFF))
            else:
                self.buf.extend((4, x & 0xFF, (x >> 8) & 0xFF, (x >> 16) & 0xFF, (x >> 24) & 0xFF))
        else:
            u = x & 0xFFFFFFFF
            if x >= -0x100:
                self.buf.extend((0xFF, u & 0xFF))
            elif x >= -0x10000:
                self.buf.extend((0xFE, u & 0xFF, (u >> 8) & 0xFF))
            elif x >= -0x1000000:
                self.buf.extend((0xFD, u & 0xFF, (u >> 8) & 0xFF, (u >> 16) & 0xFF))
            else:
                self.buf.extend((0xFC, u & 0xFF, (u >> 8) & 0xFF, (u >> 16) & 0xFF, (u >> 24) & 0xFF))

    def write_sym(self, sym_bytes):
        if sym_bytes in self.symbols:
            self.buf.append(0x3B)
            self.write_long(self.symbols[sym_bytes])
        else:
            idx = len(self.symbols)
            self.symbols[sym_bytes] = idx
            self.buf.append(0x3A)
            self.write_long(len(sym_bytes))
            self.buf.extend(sym_bytes)

    def write_value(self, val):
        if val is None:
            self.buf.append(0x30)
        elif val is True:
            self.buf.append(0x54)
        elif val is False:
            self.buf.append(0x46)
        elif isinstance(val, int):
            if FIXNUM_MIN <= val <= FIXNUM_MAX:
                self.buf.append(0x69)
                self.write_long(val)
            else:
                self.buf.append(0x6C)
                self.buf.append(0x2D if val < 0 else 0x2B)
                mag = abs(val)
                nbytes = max((mag.bit_length() + 7) // 8, 1)
                if nbytes % 2 == 1:
                    nbytes += 1
                self.write_long(nbytes // 2)
                self.buf.extend(mag.to_bytes(nbytes, "little"))
        elif isinstance(val, RubySym):
            self.write_sym(val.raw)
        elif isinstance(val, RubyStr):
            if val.ivars:
                self.buf.append(0x49)
            self.buf.append(0x22)
            self.write_long(len(val.raw))
            self.buf.extend(val.raw)
            if val.ivars:
                self.write_long(len(val.ivars))
                for k, v in val.ivars:
                    self.write_value(k)
                    self.write_value(v)
        elif isinstance(val, list):
            self.buf.append(0x5B)
            self.write_long(len(val))
            for item in val:
                self.write_value(item)
        else:
            raise TypeError(f"Unsupported value for Marshal dump: {type(val)}")

    def dump(self, root):
        self.write_value(root)
        return bytes(self.buf)


# ============================================================================
# Smart Game & Engine Discovery
# ============================================================================

def find_ci_child(parent_dir, target_name):
    if not os.path.isdir(parent_dir):
        return None
    exact = os.path.join(parent_dir, target_name)
    if os.path.exists(exact):
        return exact
    low = target_name.lower()
    try:
        for entry in os.listdir(parent_dir):
            if entry.lower() == low:
                return os.path.join(parent_dir, entry)
    except OSError:
        pass
    return None


def get_ini_scripts_rel(game_dir):
    if not os.path.isdir(game_dir):
        return None
    ini_candidates = []
    g_ini = find_ci_child(game_dir, "Game.ini")
    if g_ini and os.path.isfile(g_ini):
        ini_candidates.append(g_ini)
    try:
        for fn in os.listdir(game_dir):
            if fn.lower().endswith(".ini"):
                full = os.path.join(game_dir, fn)
                if full not in ini_candidates and os.path.isfile(full):
                    ini_candidates.append(full)
    except OSError:
        pass

    for ini_path in ini_candidates:
        try:
            with open(ini_path, "rb") as f:
                text = f.read().decode("utf-8", errors="ignore")
            m = re.search(r"^\s*Scripts\s*=\s*(.+?)\s*$", text, re.MULTILINE | re.IGNORECASE)
            if m:
                return m.group(1).strip().strip("\"'")
        except OSError:
            pass
    return None


def find_rgss_archives(directory):
    if not directory or not os.path.isdir(directory):
        return []
    found = []
    try:
        entries = sorted(os.listdir(directory))
    except OSError:
        return []
    # Prioritize Game.rgss* first
    for pref in ("game.rgss3a", "game.rgss2a", "game.rgssad"):
        for e in entries:
            if e.lower() == pref:
                full = os.path.join(directory, e)
                if os.path.isfile(full):
                    found.append(full)
    for e in entries:
        low = e.lower()
        if low.endswith(ARCHIVE_EXTS):
            full = os.path.join(directory, e)
            if os.path.isfile(full) and full not in found:
                found.append(full)
    return found


def find_rgss_scripts(directory):
    ini_rel = get_ini_scripts_rel(directory)
    if ini_rel:
        cand = os.path.join(directory, ini_rel.replace("\\", os.sep).replace("/", os.sep))
        if os.path.isfile(cand):
            return cand
    data_dir = find_ci_child(directory, "Data")
    for fname in SCRIPT_FILES:
        if data_dir and os.path.isdir(data_dir):
            found = find_ci_child(data_dir, fname)
            if found and os.path.isfile(found):
                return found
        direct = find_ci_child(directory, fname)
        if direct and os.path.isfile(direct):
            return direct
    return None


def is_mv_mz_web_root(web_dir):
    if not web_dir or not os.path.isdir(web_dir):
        return False
    js_dir = find_ci_child(web_dir, "js")
    data_dir = find_ci_child(web_dir, "data")
    if js_dir and os.path.isdir(js_dir):
        for marker in ("plugins.js", "rpg_core.js", "rmmz_core.js", "main.js"):
            m = find_ci_child(js_dir, marker)
            if m and os.path.isfile(m):
                return True
    if data_dir and os.path.isdir(data_dir):
        for marker in ("System.json", "Actors.json", "Items.json", "MapInfos.json"):
            m = find_ci_child(data_dir, marker)
            if m and os.path.isfile(m):
                return True
    return False


def find_html_entry(game_root, web_root):
    idx = find_ci_child(web_root, "index.html")
    if idx and os.path.isfile(idx):
        return idx
    for base in (game_root, web_root):
        pkg = find_ci_child(base, "package.json") if base else None
        if pkg and os.path.isfile(pkg):
            try:
                with open(pkg, "rb") as f:
                    meta = json.loads(f.read().decode("utf-8-sig", errors="ignore"))
                main_rel = str(meta.get("main", "")).strip()
                if main_rel.lower().endswith((".html", ".htm")):
                    cand = os.path.join(base, main_rel.replace("\\", os.sep).replace("/", os.sep))
                    if os.path.isfile(cand):
                        return cand
            except Exception:
                pass
    return None


def probe_directory(cand_dir):
    if not cand_dir or not os.path.isdir(cand_dir):
        return None

    # 1. Check RGSS archives & unpacked RGSS scripts
    # Note: RGSS prioritizes active .rgss3a/.rgss2a/.rgssad archives over unpacked Data/!
    arcs = find_rgss_archives(cand_dir)
    rgss_loose = find_rgss_scripts(cand_dir)
    if arcs or rgss_loose:
        return {
            "kind": "rgss",
            "game_dir": cand_dir,
            "archive_path": arcs[0] if arcs else None,
            "scripts_path": rgss_loose,
            "ini_scripts_rel": get_ini_scripts_rel(cand_dir),
        }

    # 2. Check RPG Maker MV layout (<game_dir>/www)
    www_dir = find_ci_child(cand_dir, "www")
    if www_dir and os.path.isdir(www_dir) and is_mv_mz_web_root(www_dir):
        return {
            "kind": "js",
            "engine_hint": "MV",
            "game_dir": cand_dir,
            "web_root": www_dir,
            "html_path": find_html_entry(cand_dir, www_dir),
        }

    # 3. Check direct web root (RPG Maker MZ, web build, or user pointed at www/ directly)
    if is_mv_mz_web_root(cand_dir):
        parent = os.path.dirname(cand_dir)
        is_www = os.path.basename(cand_dir).lower() == "www"
        game_root = parent if (is_www and parent and parent != cand_dir) else cand_dir
        return {
            "kind": "js",
            "engine_hint": "MV" if is_www else "MV/MZ",
            "game_dir": game_root,
            "web_root": cand_dir,
            "html_path": find_html_entry(game_root, cand_dir),
        }

    return None


def discover_target(raw_arg):
    if not raw_arg or not raw_arg.strip():
        local = discover_from_path(os.getcwd(), report_errors=False)
        if local:
            return local
        try:
            user_in = input("Enter path to the RPG Maker game folder: ").strip().strip("\"'")
        except EOFError:
            user_in = ""
        if not user_in:
            sys.stderr.write("[Error] No path provided.\n")
            return None
        raw_arg = user_in

    return discover_from_path(raw_arg.strip().strip("\"'"), report_errors=True)


def discover_from_path(path_str, report_errors=True):
    expanded = os.path.abspath(path_str)

    if os.path.isfile(expanded):
        low = os.path.basename(expanded).lower()
        if low.endswith((".rvdata2", ".rvdata", ".rxdata")):
            parent = os.path.dirname(expanded)
            root = os.path.dirname(parent) if os.path.basename(parent).lower() == "data" else parent
            return {
                "kind": "rgss",
                "game_dir": root,
                "archive_path": None,
                "scripts_path": expanded,
                "ini_scripts_rel": None,
            }
        if low.endswith(ARCHIVE_EXTS):
            root = os.path.dirname(expanded)
            return {
                "kind": "rgss",
                "game_dir": root,
                "archive_path": expanded,
                "scripts_path": find_rgss_scripts(root),
                "ini_scripts_rel": get_ini_scripts_rel(root),
            }
        start_dir = os.path.dirname(expanded)
    elif os.path.isdir(expanded):
        start_dir = expanded
    else:
        if report_errors:
            sys.stderr.write(f"[Error] Path not found: {expanded}\n")
        return None

    candidates = [start_dir]
    cur = start_dir
    for _ in range(4):
        base_name = os.path.basename(cur).lower()
        parent = os.path.dirname(cur)
        if not parent or parent == cur:
            break
        if base_name in SUBDIR_PARENTS:
            if parent not in candidates:
                candidates.append(parent)
            cur = parent
        else:
            break

    for c in candidates:
        hit = probe_directory(c)
        if hit:
            return hit

    if report_errors:
        level1 = []
        try:
            for entry in sorted(os.listdir(start_dir)):
                if entry.lower() in SKIP_SCAN_DIRS or entry.startswith("."):
                    continue
                sub = os.path.join(start_dir, entry)
                if os.path.isdir(sub):
                    level1.append(sub)
        except OSError:
            pass

        for sub in level1:
            hit = probe_directory(sub)
            if hit:
                return hit

        for sub in level1:
            try:
                for entry in sorted(os.listdir(sub)):
                    if entry.lower() in SKIP_SCAN_DIRS or entry.startswith("."):
                        continue
                    sub2 = os.path.join(sub, entry)
                    if os.path.isdir(sub2):
                        hit = probe_directory(sub2)
                        if hit:
                            return hit
            except OSError:
                pass

        sys.stderr.write(f"[Error] Could not find supported RPG Maker files in: {expanded}\n")
        sys.stderr.write("        Checked for: MV/MZ (www/js/plugins.js, js/plugins.js, index.html, data/*.json)\n")
        sys.stderr.write("                     and XP/VX/VXA (Data/Scripts.*, *.rgss3a/*.rgss2a/*.rgssad, Game.ini).\n")
    return None


# ============================================================================
# MV / MZ JavaScript Injector
# ============================================================================

def splice_plugins_js_install(content):
    existing_re = re.compile(r'\{\s*"name"\s*:\s*"RPGMCheat"[^\r\n]*\}')
    if existing_re.search(content):
        return existing_re.sub(JS_PLUGIN_ENTRY, content, count=1), "updated"

    m_open = re.search(r"\$plugins\s*=\s*\[", content)
    last_close = content.rfind("]")
    if not m_open or last_close == -1 or last_close < m_open.end() - 1:
        return None, "invalid"

    open_bracket_idx = content.find("[", m_open.start())
    inner = content[open_bracket_idx + 1:last_close]
    stripped = inner.rstrip()

    if not stripped:
        new_content = content[:open_bracket_idx + 1] + "\n" + JS_PLUGIN_ENTRY + "\n" + content[last_close:]
    elif stripped.endswith(","):
        insert_pos = open_bracket_idx + 1 + len(stripped)
        new_content = content[:insert_pos] + "\n" + JS_PLUGIN_ENTRY + "\n" + content[last_close:]
    else:
        insert_pos = open_bracket_idx + 1 + len(stripped)
        new_content = content[:insert_pos] + ",\n" + JS_PLUGIN_ENTRY + "\n" + content[last_close:]
    return new_content, "installed"


def splice_plugins_js_remove(content):
    if '"RPGMCheat"' not in content:
        return content, False
    c1, n1 = re.subn(r',\s*\{\s*"name"\s*:\s*"RPGMCheat"[^\r\n]*\}', "", content)
    if n1 > 0:
        return c1, True
    c2, n2 = re.subn(r'\{\s*"name"\s*:\s*"RPGMCheat"[^\r\n]*\}\s*,\s*', "", content)
    if n2 > 0:
        return c2, True
    c3, n3 = re.subn(r'\{\s*"name"\s*:\s*"RPGMCheat"[^\r\n]*\}\r?\n?', "", content)
    return c3, (n3 > 0)


def install_js_target(target, cheat_js_path):
    web_root = target["web_root"]
    js_dir = find_ci_child(web_root, "js")
    if not js_dir:
        js_dir = os.path.join(web_root, "js")
        os.makedirs(js_dir, exist_ok=True)

    plugins_js = find_ci_child(js_dir, "plugins.js")
    main_js = find_ci_child(js_dir, "main.js")
    used_plugins_js = False

    if plugins_js and os.path.isfile(plugins_js):
        with open(plugins_js, "rb") as f:
            raw_text = f.read().decode("utf-8-sig")

        patched, status = splice_plugins_js_install(raw_text)
        if patched is not None:
            plugins_dir = find_ci_child(js_dir, "plugins")
            if not plugins_dir:
                plugins_dir = os.path.join(js_dir, "plugins")
                os.makedirs(plugins_dir, exist_ok=True)

            bak_path = plugins_js + ".bak"
            if not os.path.exists(bak_path):
                shutil.copy2(plugins_js, bak_path)
                print(f"[Backup] Created backup: {bak_path}")

            with open(plugins_js, "wb") as f:
                f.write(patched.encode("utf-8"))

            dest_plugin = os.path.join(plugins_dir, JS_PLUGIN_NAME + ".js")
            shutil.copy2(cheat_js_path, dest_plugin)
            verb = "Updated" if status == "updated" else "Installed"
            print(f"[{verb}] Registered {JS_PLUGIN_NAME} in {plugins_js}")
            print(f"[File] Copied plugin to {dest_plugin}")
            used_plugins_js = True

    if not used_plugins_js:
        html_path = target.get("html_path")
        dest_script = os.path.join(js_dir, "rpgm_cheat.js")
        shutil.copy2(cheat_js_path, dest_script)

        if html_path and os.path.isfile(html_path):
            with open(html_path, "rb") as f:
                html_text = f.read().decode("utf-8-sig")

            if "rpgm_cheat.js" not in html_text:
                bak_html = html_path + ".bak"
                if not os.path.exists(bak_html):
                    shutil.copy2(html_path, bak_html)
                    print(f"[Backup] Created backup: {bak_html}")

                if re.search(r"</body\s*>", html_text, re.IGNORECASE):
                    html_text = re.sub(
                        r"(</body\s*>)",
                        HTML_SCRIPT_TAG + r"\n\1",
                        html_text,
                        count=1,
                        flags=re.IGNORECASE,
                    )
                else:
                    html_text = html_text.rstrip() + "\n" + HTML_SCRIPT_TAG + "\n"

                with open(html_path, "wb") as f:
                    f.write(html_text.encode("utf-8"))
                print(f"[Installed] Injected script tag into {html_path}")
            else:
                print(f"[Updated] Refreshed {dest_script} (already linked in {html_path})")
        elif main_js and os.path.isfile(main_js):
            with open(main_js, "rb") as f:
                main_text = f.read().decode("utf-8-sig")
            hook_line = '\n// RPGMCheat Loader\n(function(){var s=document.createElement("script");s.src="js/rpgm_cheat.js";document.body.appendChild(s);})();\n'
            if "rpgm_cheat.js" not in main_text:
                bak_main = main_js + ".bak"
                if not os.path.exists(bak_main):
                    shutil.copy2(main_js, bak_main)
                    print(f"[Backup] Created backup: {bak_main}")
                with open(main_js, "wb") as f:
                    f.write((main_text + hook_line).encode("utf-8"))
                print(f"[Installed] Appended loader to {main_js}")
        else:
            plugins_dir = os.path.join(js_dir, "plugins")
            os.makedirs(plugins_dir, exist_ok=True)
            dest_plugin = os.path.join(plugins_dir, JS_PLUGIN_NAME + ".js")
            shutil.copy2(cheat_js_path, dest_plugin)
            new_pjs = os.path.join(js_dir, "plugins.js")
            content = "// Generated by RPG Maker.\nvar $plugins =\n[\n" + JS_PLUGIN_ENTRY + "\n];\n"
            with open(new_pjs, "wb") as f:
                f.write(content.encode("utf-8"))
            print(f"[Installed] Created {new_pjs} and {dest_plugin}")

    print("[Done] Launch the game and press F8 on the map or in battle!")
    return 0


def uninstall_js_target(target):
    web_root = target["web_root"]
    js_dir = find_ci_child(web_root, "js")
    removed_any = False

    if js_dir and os.path.isdir(js_dir):
        plugins_js = find_ci_child(js_dir, "plugins.js")
        if plugins_js and os.path.isfile(plugins_js):
            with open(plugins_js, "rb") as f:
                raw_text = f.read().decode("utf-8-sig")
            cleaned, changed = splice_plugins_js_remove(raw_text)
            if changed:
                with open(plugins_js, "wb") as f:
                    f.write(cleaned.encode("utf-8"))
                print(f"[Removed] Unregistered {JS_PLUGIN_NAME} from {plugins_js}")
                removed_any = True

        plugins_dir = find_ci_child(js_dir, "plugins")
        if plugins_dir and os.path.isdir(plugins_dir):
            pfile = find_ci_child(plugins_dir, JS_PLUGIN_NAME + ".js")
            if pfile and os.path.isfile(pfile):
                os.remove(pfile)
                print(f"[Removed] Deleted {pfile}")
                removed_any = True

        direct_js = find_ci_child(js_dir, "rpgm_cheat.js")
        if direct_js and os.path.isfile(direct_js):
            os.remove(direct_js)
            print(f"[Removed] Deleted {direct_js}")
            removed_any = True

        main_js = find_ci_child(js_dir, "main.js")
        if main_js and os.path.isfile(main_js):
            with open(main_js, "rb") as f:
                mt = f.read().decode("utf-8-sig")
            if "rpgm_cheat.js" in mt:
                mt = re.sub(r"\r?\n// RPGMCheat Loader\r?\n[^\r\n]*rpgm_cheat\.js[^\r\n]*\r?\n?", "\n", mt)
                with open(main_js, "wb") as f:
                    f.write(mt.encode("utf-8"))
                print(f"[Removed] Cleaned loader from {main_js}")
                removed_any = True

    html_path = target.get("html_path")
    if html_path and os.path.isfile(html_path):
        with open(html_path, "rb") as f:
            ht = f.read().decode("utf-8-sig")
        if "rpgm_cheat.js" in ht:
            ht = re.sub(r'\s*<script[^>]*rpgm_cheat\.js[^>]*></script>', "", ht, flags=re.IGNORECASE)
            with open(html_path, "wb") as f:
                f.write(ht.encode("utf-8"))
            print(f"[Removed] Removed script tag from {html_path}")
            removed_any = True

    if not removed_any:
        print(f"[Info] {JS_PLUGIN_NAME} was not installed in {web_root}.")
    return 0


# ============================================================================
# RGSS Ruby Injector & Archive Unpacker
# ============================================================================

def build_rgss_payload(cheat_bytes, standalone):
    text = cheat_bytes.decode("utf-8-sig")
    text = re.sub(r"\A#.*coding:.*\r?\n", "", text)

    if standalone:
        payload = (
            "# -*- coding: utf-8 -*-\n"
            "# Auto-generated by RPGMCheat inject.py (standalone)\n"
            "unless defined?(RPGMCheat)\n"
            + text
            + "\nend\n"
        )
    else:
        loader_head = (
            "# -*- coding: utf-8 -*-\n"
            "# Auto-generated by RPGMCheat inject.py (hybrid loader + fallback)\n"
            'if File.exist?("cheat.rb") && !defined?(RPGMCheat)\n'
            '  rpgm_cheat_raw = File.open("cheat.rb", "rb") { |f| f.read }\n'
            '  rpgm_cheat_bom = [0xEF, 0xBB, 0xBF].pack("C*")\n'
            "  if rpgm_cheat_raw.length >= 3 && rpgm_cheat_raw[0, 3] == rpgm_cheat_bom\n"
            "    rpgm_cheat_raw = rpgm_cheat_raw[3, rpgm_cheat_raw.length - 3]\n"
            "  end\n"
            "  if rpgm_cheat_raw.respond_to?(:force_encoding)\n"
            '    rpgm_cheat_raw.force_encoding("UTF-8")\n'
            "  end\n"
            '  eval(rpgm_cheat_raw, TOPLEVEL_BINDING, "cheat.rb")\n'
            "end\n\n"
            "unless defined?(RPGMCheat)\n"
        )
        payload = loader_head + text + "\nend\n"

    return payload.encode("utf-8")


def make_title_str(name_hint):
    raw = SECTION_TAG.encode("utf-8")
    if name_hint.lower().endswith(".rvdata2"):
        return RubyStr(raw, [(RubySym(b"E"), True)])
    return RubyStr(raw, [])


def entry_title_text(entry):
    if isinstance(entry, list) and len(entry) >= 3 and isinstance(entry[1], RubyStr):
        return entry[1].raw.decode("utf-8", errors="replace").strip()
    return ""


def find_main_index(scripts):
    for idx in range(len(scripts) - 1, -1, -1):
        entry = scripts[idx]
        if isinstance(entry, list) and len(entry) >= 3:
            if entry_title_text(entry).lower() == "main":
                return idx
            if isinstance(entry[2], RubyStr):
                try:
                    inflated = zlib.decompress(entry[2].raw).decode("utf-8", errors="replace")
                    if ("rgss_main" in inflated) or ("SceneManager.run" in inflated) or ("$scene.main" in inflated):
                        return idx
                except Exception:
                    pass
    return max(len(scripts) - 1, 0)


def inject_into_scripts_bytes(raw_scripts_bytes, name_hint, cheat_bytes, standalone):
    scripts = MarshalReader(raw_scripts_bytes).load()
    if not isinstance(scripts, list):
        raise ValueError(f"Invalid Marshal script table root in {name_hint}")

    payload = build_rgss_payload(cheat_bytes, standalone)
    compressed = RubyStr(zlib.compress(payload, 9), [])
    title_obj = make_title_str(name_hint)

    existing_idx = None
    for i, entry in enumerate(scripts):
        if entry_title_text(entry) == SECTION_TAG:
            existing_idx = i
            break

    if existing_idx is not None:
        scripts[existing_idx][1] = title_obj
        scripts[existing_idx][2] = compressed
        status_msg = f"updated at slot #{existing_idx}"
    else:
        insert_at = find_main_index(scripts)
        magic_id = random.randint(10_000_000, 99_999_999)
        scripts.insert(insert_at, [magic_id, title_obj, compressed])
        status_msg = f"inserted above Main at slot #{insert_at}"

    return MarshalWriter().dump(scripts), status_msg


def decrypt_rgss_archive_cmd(target):
    archive_path = target.get("archive_path")
    game_dir = target["game_dir"]
    if not archive_path or not os.path.isfile(archive_path):
        sys.stderr.write(f"[Error] No .rgss3a/.rgss2a/.rgssad archive found in: {game_dir}\n")
        return 1

    print(f"[Decryptor] Opening archive: {archive_path}")
    try:
        arc = RgssArchive(archive_path)
    except Exception as exc:
        sys.stderr.write(f"[Error] {exc}\n")
        return 1

    print(f"[Decryptor] Detected RGSSAD v{arc.version} ({len(arc.entries)} files). Extracting to: {game_dir}")
    arc.extract_all(game_dir)

    bak_archive = archive_path + ".bak"
    if os.path.exists(bak_archive):
        bak_archive = archive_path + ".unpacked_bak"
    os.replace(archive_path, bak_archive)

    meta_bak = archive_path + ".rpgmcheat_bak"
    if os.path.isfile(meta_bak):
        os.remove(meta_bak)

    print(f"[Decryptor] Renamed archive to {bak_archive} so the game loads unpacked files from disk.")
    print("[Done] Archive fully unpacked!")
    return 0


def install_rgss_target(target, cheat_rb_path, standalone):
    game_dir = target["game_dir"]
    archive_path = target.get("archive_path")
    scripts_path = target.get("scripts_path")

    with open(cheat_rb_path, "rb") as f:
        cheat_bytes = f.read()

    patched_archive = False

    # 1. If an encrypted archive (.rgss3a / .rgss2a / .rgssad) exists, patch Scripts inside it directly!
    if archive_path and os.path.isfile(archive_path):
        print(f"[Decryptor] Reading encrypted archive: {archive_path}")
        try:
            arc = RgssArchive(archive_path)
            s_entry = arc.find_scripts_entry(target.get("ini_scripts_rel"))
            if s_entry:
                raw_scripts = arc.read_entry_bytes(s_entry)
                if len(raw_scripts) < 2 or raw_scripts[0] != 0x04 or raw_scripts[1] != 0x08:
                    raise ValueError("Decrypted Scripts entry did not match Ruby Marshal 4.8 header.")
                new_scripts, status_msg = inject_into_scripts_bytes(
                    raw_scripts, s_entry["name"], cheat_bytes, standalone
                )
                arc.patch_scripts_entry(s_entry, new_scripts)
                print(f"[Installed] {SECTION_TAG} {status_msg} directly inside {os.path.basename(archive_path)} ({s_entry['name']})!")
                patched_archive = True
        except Exception as exc:
            if not scripts_path:
                sys.stderr.write(f"[Error] Could not patch {archive_path}: {exc}\n")
                return 1
            print(f"[Warning] Could not patch {os.path.basename(archive_path)}: {exc}")

    # 2. Also patch loose Data/Scripts.* on disk if present
    if scripts_path and os.path.isfile(scripts_path):
        bak_path = scripts_path + ".bak"
        if not os.path.exists(bak_path):
            shutil.copy2(scripts_path, bak_path)
            print(f"[Backup] Created backup: {bak_path}")

        with open(scripts_path, "rb") as f:
            raw_scripts = f.read()
        new_scripts, status_msg = inject_into_scripts_bytes(
            raw_scripts, scripts_path, cheat_bytes, standalone
        )
        with open(scripts_path, "wb") as f:
            f.write(new_scripts)
        print(f"[Installed] {SECTION_TAG} {status_msg} in {scripts_path}.")

    if not patched_archive and not (scripts_path and os.path.isfile(scripts_path)):
        sys.stderr.write(f"[Error] No Scripts entry found in {game_dir}.\n")
        return 1

    target_cheat = os.path.join(game_dir, "cheat.rb")
    same_file = os.path.abspath(target_cheat) == os.path.abspath(cheat_rb_path)
    if standalone:
        if os.path.isfile(target_cheat) and not same_file:
            os.remove(target_cheat)
        print("[Mode] Standalone: cheat menu embedded inside game scripts.")
    else:
        if not same_file:
            shutil.copy2(cheat_rb_path, target_cheat)
        print(f"[File] Copied {target_cheat} (edit settings anytime without re-injecting).")

    print("[Done] Launch the game and press F8 on the map or in battle!")
    return 0


def uninstall_rgss_target(target, own_cheat_path):
    game_dir = target["game_dir"]
    archive_path = target.get("archive_path")
    scripts_path = target.get("scripts_path")
    removed_any = False

    if archive_path and os.path.isfile(archive_path):
        if RgssArchive.revert_patch(archive_path):
            print(f"[Removed] Restored original unpatched archive: {archive_path}")
            removed_any = True
        else:
            try:
                arc = RgssArchive(archive_path)
                s_entry = arc.find_scripts_entry(target.get("ini_scripts_rel"))
                if s_entry:
                    raw_scripts = arc.read_entry_bytes(s_entry)
                    scripts = MarshalReader(raw_scripts).load()
                    filtered = [e for e in scripts if entry_title_text(e) != SECTION_TAG]
                    if len(filtered) < len(scripts):
                        arc.patch_scripts_entry(s_entry, MarshalWriter().dump(filtered))
                        print(f"[Removed] Removed {SECTION_TAG} from {archive_path}.")
                        removed_any = True
            except Exception:
                pass

    if scripts_path and os.path.isfile(scripts_path):
        with open(scripts_path, "rb") as f:
            scripts = MarshalReader(f.read()).load()
        filtered = [e for e in scripts if entry_title_text(e) != SECTION_TAG]
        if len(filtered) < len(scripts):
            with open(scripts_path, "wb") as f:
                f.write(MarshalWriter().dump(filtered))
            print(f"[Removed] {SECTION_TAG} removed from {scripts_path}.")
            removed_any = True

    target_cheat = os.path.join(game_dir, "cheat.rb")
    if os.path.isfile(target_cheat) and os.path.abspath(target_cheat) != os.path.abspath(own_cheat_path):
        os.remove(target_cheat)
        print(f"[Removed] Deleted {target_cheat}.")
        removed_any = True

    if not removed_any:
        print(f"[Info] {SECTION_TAG} was not installed in {game_dir}.")
    return 0


# ============================================================================
# CLI Entrypoint
# ============================================================================

def print_help():
    print(
        "Usage:\n"
        "  python3 inject.py [options] [path_to_game_folder]\n\n"
        "Supported engines & archives (auto-detected):\n"
        "  - RPG Maker MV / MZ   (www/js/plugins.js, js/plugins.js, index.html)\n"
        "  - RPG Maker XP/VX/VXA (Data/Scripts.*, *.rgss3a, *.rgss2a, *.rgssad)\n\n"
        "Options:\n"
        "  (default)          Installs cheat menu (automatically patches .rgss3a/.rgss2a/.rgssad!).\n"
        "  -d, --decrypt      Extracts all files from .rgss3a/.rgss2a/.rgssad to disk.\n"
        "  -s, --standalone   For RGSS: embeds cheat.rb inside game scripts only.\n"
        "  -r, --remove       Cleanly uninstalls cheat menu & restores original archive.\n"
        "  -h, --help         Show this help message."
    )


def main(argv):
    mode = "install"
    standalone = False
    target_arg = None

    for arg in argv:
        if arg in ("-h", "--help"):
            print_help()
            return 0
        elif arg in ("-r", "--remove", "--uninstall"):
            mode = "remove"
        elif arg in ("-d", "--decrypt", "--extract", "--unpack"):
            mode = "decrypt"
        elif arg in ("-s", "--standalone", "--embed"):
            standalone = True
        else:
            target_arg = arg

    script_dir = os.path.dirname(os.path.abspath(__file__))
    cheat_rb_path = os.path.join(script_dir, "cheat.rb")
    cheat_js_path = os.path.join(script_dir, "cheat.js")

    target = discover_target(target_arg)
    if not target:
        return 1

    if mode == "decrypt":
        if target["kind"] != "rgss":
            sys.stderr.write("[Info] RPG Maker MV/MZ projects do not use .rgss* archives (data/*.json & js/ are already unpacked).\n")
            return 0
        return decrypt_rgss_archive_cmd(target)

    if target["kind"] == "js":
        print(f"[Detected] RPG Maker {target['engine_hint']} project at: {target['web_root']}")
        if mode == "remove":
            return uninstall_js_target(target)
        if not os.path.isfile(cheat_js_path):
            sys.stderr.write(f"[Error] cheat.js not found next to inject.py: {cheat_js_path}\n")
            return 1
        return install_js_target(target, cheat_js_path)
    else:
        loc = target.get("archive_path") or target.get("scripts_path")
        print(f"[Detected] RPG Maker RGSS target: {loc}")
        if mode == "remove":
            return uninstall_rgss_target(target, cheat_rb_path)
        if not os.path.isfile(cheat_rb_path):
            sys.stderr.write(f"[Error] cheat.rb not found next to inject.py: {cheat_rb_path}\n")
            return 1
        return install_rgss_target(target, cheat_rb_path, standalone)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
