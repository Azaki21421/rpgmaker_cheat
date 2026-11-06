@setlocal & set "INJECT_SELF=%~f0" & set "INJECT_DIR=%~dp0" & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$raw = [IO.File]::ReadAllText($env:INJECT_SELF, [Text.Encoding]::UTF8); $sep = [char]10 + '# --- PS_START ---'; $idx = $raw.IndexOf($sep); & ([ScriptBlock]::Create($raw.Substring($idx + 1))) @args" %* & exit /b %ERRORLEVEL%
# --- PS_START ---
# ============================================================================
# inject.bat — Universal Zero-Dependency Windows Installer & RGSS Decryptor
# Requires NEITHER Ruby NOR Python (uses built-in Windows PowerShell + .NET).
#
# Supported RPG Maker engines & encrypted archives:
#   - RPG Maker MV     (www\js\plugins.js, www\index.html, www\data\*.json) -> cheat.js
#   - RPG Maker MZ     (js\plugins.js, index.html, data\*.json)             -> cheat.js
#   - RPG Maker VX Ace (Data\Scripts.rvdata2 OR packed *.rgss3a archive!)   -> cheat.rb
#   - RPG Maker VX     (Data\Scripts.rvdata  OR packed *.rgss2a archive!)   -> cheat.rb
#   - RPG Maker XP     (Data\Scripts.rxdata  OR packed *.rgssad archive!)   -> cheat.rb
#
# Usage:
#   inject.bat "C:\Games\MyGame"               (Install — works directly on .rgss3a!)
#   inject.bat --decrypt "C:\Games\MyGame"     (Extract all files from .rgss3a/.rgss2a/.rgssad)
#   inject.bat --standalone "C:\Games\MyGame"  (Embed cheat.rb inside game scripts only)
#   inject.bat --remove "C:\Games\MyGame"      (Uninstall cheat & restore original archive)
# ============================================================================

$ErrorActionPreference = "Stop"

Add-Type -Language CSharp -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Text;
using System.Text.RegularExpressions;

public class RgssEntry {
    public string Name;
    public long Offset;
    public long Size;
    public uint Subkey;
    public long HeaderPos;
    public byte[] RawNameHeader;
    public uint SizeXorKey;
}

public class RgssArchive {
    public string Path;
    public long FileSize;
    public int Version;
    public uint MasterKey;
    public List<RgssEntry> Entries = new List<RgssEntry>();

    public RgssArchive(string path) {
        Path = path;
        FileInfo fi = new FileInfo(path);
        FileSize = fi.Length;
        ParseIndex();
    }

    public static void XorBuffer(byte[] buf, int len, ref uint key) {
        uint k = key;
        int i = 0;
        while (i + 4 <= len) {
            buf[i]     ^= (byte)(k & 0xFF);
            buf[i + 1] ^= (byte)((k >> 8) & 0xFF);
            buf[i + 2] ^= (byte)((k >> 16) & 0xFF);
            buf[i + 3] ^= (byte)((k >> 24) & 0xFF);
            k = unchecked(k * 7u + 3u);
            i += 4;
        }
        if (i < len) {
            int rem = len - i;
            for (int b = 0; b < rem; b++) {
                buf[i + b] ^= (byte)((k >> (8 * b)) & 0xFF);
            }
            k = unchecked(k * 7u + 3u);
        }
        key = k;
    }

    public static byte[] XorCopy(byte[] data, uint subkey) {
        byte[] copy = new byte[data.Length];
        Buffer.BlockCopy(data, 0, copy, 0, data.Length);
        uint k = subkey;
        XorBuffer(copy, copy.Length, ref k);
        return copy;
    }

    private static string DecodeName(byte[] raw) {
        try {
            UTF8Encoding strictUtf8 = new UTF8Encoding(false, true);
            return strictUtf8.GetString(raw);
        } catch {
            try {
                return Encoding.GetEncoding(932).GetString(raw);
            } catch {
                return Encoding.Default.GetString(raw);
            }
        }
    }

    private static string SanitizeRelPath(string name) {
        string norm = name.Replace('/', '\\').TrimStart('\\');
        norm = Regex.Replace(norm, @"^[A-Za-z]:\\+", "");
        string[] parts = norm.Split(new char[] { '\\' }, StringSplitOptions.RemoveEmptyEntries);
        List<string> clean = new List<string>();
        foreach (string p in parts) {
            if (p == ".") continue;
            if (p == "..") throw new InvalidDataException("Unsafe archive entry path rejected: " + name);
            clean.Add(p);
        }
        if (clean.Count == 0) throw new InvalidDataException("Empty archive entry path.");
        return String.Join(System.IO.Path.DirectorySeparatorChar.ToString(), clean.ToArray());
    }

    private void ParseIndex() {
        using (FileStream fs = new FileStream(Path, FileMode.Open, FileAccess.Read, FileShare.Read))
        using (BinaryReader br = new BinaryReader(fs)) {
            byte[] hdr = br.ReadBytes(8);
            if (hdr.Length < 8 || hdr[0] != 0x52 || hdr[1] != 0x47 || hdr[2] != 0x53 ||
                hdr[3] != 0x53 || hdr[4] != 0x41 || hdr[5] != 0x44 || hdr[6] != 0x00) {
                throw new InvalidDataException("Not a valid RGSSAD archive (header mismatch).");
            }
            Version = hdr[7];

            if (Version == 3) {
                uint seed = br.ReadUInt32();
                uint key = unchecked(seed * 9u + 3u);
                MasterKey = key;

                while (fs.Position + 4 <= FileSize) {
                    long entryPos = fs.Position;
                    uint off = br.ReadUInt32() ^ key;
                    if (off == 0) break;

                    uint sz = br.ReadUInt32() ^ key;
                    uint sk = br.ReadUInt32() ^ key;
                    uint nl = br.ReadUInt32() ^ key;

                    long loff = (long)off;
                    long lsz = (long)sz;
                    if (nl > 4096 || loff < 16 || loff + lsz > FileSize) {
                        throw new InvalidDataException("Archive uses non-standard custom key protection.");
                    }

                    byte[] encName = br.ReadBytes((int)nl);
                    byte[] decName = new byte[nl];
                    for (int i = 0; i < (int)nl; i++) {
                        decName[i] = (byte)(encName[i] ^ ((key >> (8 * (i & 3))) & 0xFF));
                    }

                    RgssEntry e = new RgssEntry();
                    e.Name = DecodeName(decName);
                    e.Offset = loff;
                    e.Size = lsz;
                    e.Subkey = sk;
                    e.HeaderPos = entryPos;
                    Entries.Add(e);
                }
            } else if (Version == 1 || Version == 2) {
                uint key = 0xDEADCAFEu;
                MasterKey = key;

                while (fs.Position < FileSize) {
                    long entryPos = fs.Position;
                    byte[] nlRaw = br.ReadBytes(4);
                    if (nlRaw.Length == 0) break;
                    if (nlRaw.Length < 4) throw new InvalidDataException("Truncated RGSSAD v1 header.");
                    uint nl = BitConverter.ToUInt32(nlRaw, 0) ^ key;
                    key = unchecked(key * 7u + 3u);

                    if (nl == 0 || nl > 4096 || fs.Position + nl + 4 > FileSize) {
                        throw new InvalidDataException("Archive uses non-standard custom key protection.");
                    }

                    byte[] encName = br.ReadBytes((int)nl);
                    byte[] decName = new byte[nl];
                    for (int i = 0; i < (int)nl; i++) {
                        decName[i] = (byte)(encName[i] ^ (key & 0xFF));
                        key = unchecked(key * 7u + 3u);
                    }

                    uint sizeXorKey = key;
                    uint sz = br.ReadUInt32() ^ key;
                    key = unchecked(key * 7u + 3u);

                    long dataOff = fs.Position;
                    long lsz = (long)sz;
                    if (dataOff + lsz > FileSize) {
                        throw new InvalidDataException("Truncated RGSSAD v1 entry payload.");
                    }

                    byte[] rawHdr = new byte[4 + encName.Length];
                    Buffer.BlockCopy(nlRaw, 0, rawHdr, 0, 4);
                    Buffer.BlockCopy(encName, 0, rawHdr, 4, encName.Length);

                    RgssEntry e = new RgssEntry();
                    e.Name = DecodeName(decName);
                    e.Offset = dataOff;
                    e.Size = lsz;
                    e.Subkey = key;
                    e.HeaderPos = entryPos;
                    e.RawNameHeader = rawHdr;
                    e.SizeXorKey = sizeXorKey;
                    Entries.Add(e);

                    fs.Seek(dataOff + lsz, SeekOrigin.Begin);
                }
            } else {
                throw new InvalidDataException("Unsupported RGSSAD version: " + Version);
            }
        }
    }

    public RgssEntry FindScriptsEntry(string customRel) {
        List<string> targets = new List<string>();
        if (!String.IsNullOrEmpty(customRel)) {
            targets.Add(customRel.Replace('/', '\\').ToLowerInvariant());
        }
        targets.Add("data\\scripts.rvdata2");
        targets.Add("data\\scripts.rvdata");
        targets.Add("data\\scripts.rxdata");
        targets.Add("scripts.rvdata2");
        targets.Add("scripts.rvdata");
        targets.Add("scripts.rxdata");

        Dictionary<string, RgssEntry> map = new Dictionary<string, RgssEntry>();
        foreach (RgssEntry e in Entries) {
            string k = e.Name.Replace('/', '\\').ToLowerInvariant();
            if (!map.ContainsKey(k)) map[k] = e;
        }
        foreach (string t in targets) {
            RgssEntry hit;
            if (map.TryGetValue(t, out hit)) return hit;
        }
        return null;
    }

    public byte[] ReadEntryBytes(RgssEntry entry) {
        byte[] buf = new byte[entry.Size];
        using (FileStream fs = new FileStream(Path, FileMode.Open, FileAccess.Read, FileShare.Read)) {
            fs.Seek(entry.Offset, SeekOrigin.Begin);
            int readTotal = 0;
            while (readTotal < buf.Length) {
                int r = fs.Read(buf, readTotal, buf.Length - readTotal);
                if (r <= 0) break;
                readTotal += r;
            }
        }
        uint k = entry.Subkey;
        XorBuffer(buf, buf.Length, ref k);
        return buf;
    }

    public void ExtractAll(string destDir) {
        byte[] buf = new byte[65536];
        int total = Entries.Count;
        using (FileStream fs = new FileStream(Path, FileMode.Open, FileAccess.Read, FileShare.Read)) {
            for (int idx = 0; idx < total; idx++) {
                RgssEntry e = Entries[idx];
                string rel = SanitizeRelPath(e.Name);
                string outPath = System.IO.Path.Combine(destDir, rel);
                string dir = System.IO.Path.GetDirectoryName(outPath);
                if (!String.IsNullOrEmpty(dir) && !Directory.Exists(dir)) {
                    Directory.CreateDirectory(dir);
                }

                fs.Seek(e.Offset, SeekOrigin.Begin);
                long rem = e.Size;
                uint k = e.Subkey;
                using (FileStream outFs = new FileStream(outPath, FileMode.Create, FileAccess.Write)) {
                    while (rem > 0) {
                        int take = (int)Math.Min(rem, (long)buf.Length);
                        int got = fs.Read(buf, 0, take);
                        if (got <= 0) break;
                        XorBuffer(buf, got, ref k);
                        outFs.Write(buf, 0, got);
                        rem -= got;
                    }
                }

                int num = idx + 1;
                if (num == 1 || num % 200 == 0 || num == total) {
                    Console.WriteLine(String.Format("[Decryptor] Extracted {0}/{1} files...", num, total));
                }
            }
        }
    }

    private static long ReadJsonLong(string json, string field) {
        Match m = Regex.Match(json, "\"" + field + "\"\\s*:\\s*(\\d+)");
        if (!m.Success) throw new InvalidDataException("Missing field in backup metadata: " + field);
        return Int64.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture);
    }

    public void PatchScriptsEntry(RgssEntry entry, byte[] newPlainBytes) {
        byte[] encPayload = XorCopy(newPlainBytes, entry.Subkey);
        long newSize = encPayload.LongLength;

        if (Version == 3) {
            string metaPath = Path + ".rpgmcheat_bak";
            long appendOffset;
            if (File.Exists(metaPath)) {
                string mtxt = File.ReadAllText(metaPath, Encoding.UTF8);
                appendOffset = ReadJsonLong(mtxt, "orig_archive_size");
            } else {
                appendOffset = FileSize;
                string mtxt = String.Format(
                    CultureInfo.InvariantCulture,
                    "{{\n  \"version\": 3,\n  \"orig_archive_size\": {0},\n  \"header_pos\": {1},\n  \"orig_offset\": {2},\n  \"orig_size\": {3}\n}}\n",
                    FileSize, entry.HeaderPos, entry.Offset, entry.Size
                );
                File.WriteAllText(metaPath, mtxt, new UTF8Encoding(false));
            }

            if (appendOffset + newSize > 0xFFFFFFFFL) {
                throw new InvalidDataException("Archive exceeds 4 GB RGSS3A offset limit.");
            }

            using (FileStream fs = new FileStream(Path, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
            using (BinaryWriter bw = new BinaryWriter(fs)) {
                fs.Seek(appendOffset, SeekOrigin.Begin);
                bw.Write(encPayload);
                fs.SetLength(appendOffset + newSize);

                fs.Seek(entry.HeaderPos, SeekOrigin.Begin);
                bw.Write((uint)appendOffset ^ MasterKey);
                bw.Write((uint)newSize ^ MasterKey);
                bw.Flush();
            }
            FileSize = appendOffset + newSize;
        } else {
            string bakPath = Path + ".bak";
            if (!File.Exists(bakPath)) {
                File.Copy(Path, bakPath);
                Console.WriteLine("[Backup] Created archive backup: " + bakPath);
            }

            string tmpPath = Path + ".tmp";
            byte[] copyBuf = new byte[65536];
            using (FileStream src = new FileStream(Path, FileMode.Open, FileAccess.Read, FileShare.Read))
            using (FileStream dst = new FileStream(tmpPath, FileMode.Create, FileAccess.Write))
            using (BinaryWriter bw = new BinaryWriter(dst)) {
                byte[] hdr8 = new byte[8];
                src.Read(hdr8, 0, 8);
                dst.Write(hdr8, 0, 8);

                foreach (RgssEntry e in Entries) {
                    if (Object.ReferenceEquals(e, entry)) {
                        dst.Write(e.RawNameHeader, 0, e.RawNameHeader.Length);
                        bw.Write((uint)newSize ^ e.SizeXorKey);
                        dst.Write(encPayload, 0, encPayload.Length);
                    } else {
                        src.Seek(e.HeaderPos, SeekOrigin.Begin);
                        long rem = (e.Offset - e.HeaderPos) + e.Size;
                        while (rem > 0) {
                            int take = (int)Math.Min(rem, (long)copyBuf.Length);
                            int got = src.Read(copyBuf, 0, take);
                            if (got <= 0) break;
                            dst.Write(copyBuf, 0, got);
                            rem -= got;
                        }
                    }
                }
            }
            File.Delete(Path);
            File.Move(tmpPath, Path);
            FileSize = new FileInfo(Path).Length;
        }
    }

    public static bool RevertPatch(string archivePath) {
        string metaPath = archivePath + ".rpgmcheat_bak";
        if (File.Exists(metaPath)) {
            string mtxt = File.ReadAllText(metaPath, Encoding.UTF8);
            long origLen = ReadJsonLong(mtxt, "orig_archive_size");
            long hdrPos  = ReadJsonLong(mtxt, "header_pos");
            long origOff = ReadJsonLong(mtxt, "orig_offset");
            long origSz  = ReadJsonLong(mtxt, "orig_size");

            using (FileStream fs = new FileStream(archivePath, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
            using (BinaryReader br = new BinaryReader(fs))
            using (BinaryWriter bw = new BinaryWriter(fs)) {
                fs.Seek(8, SeekOrigin.Begin);
                uint seed = br.ReadUInt32();
                uint key = unchecked(seed * 9u + 3u);

                fs.Seek(hdrPos, SeekOrigin.Begin);
                bw.Write((uint)origOff ^ key);
                bw.Write((uint)origSz ^ key);
                bw.Flush();
                fs.SetLength(origLen);
            }
            File.Delete(metaPath);
            return true;
        }

        string bakPath = archivePath + ".bak";
        if (File.Exists(bakPath)) {
            byte[] hdr = new byte[8];
            using (FileStream fs = new FileStream(archivePath, FileMode.Open, FileAccess.Read, FileShare.Read)) {
                fs.Read(hdr, 0, 8);
            }
            if (hdr[0] == 0x52 && hdr[7] <= 2) {
                File.Delete(archivePath);
                File.Move(bakPath, archivePath);
                return true;
            }
        }
        return false;
    }
}

public class RpgmCodec {
    public class RubySym {
        public byte[] Raw;
        public RubySym(byte[] r) { Raw = r; }
    }

    public class RubyIvar {
        public object Key;
        public object Val;
        public RubyIvar(object k, object v) { Key = k; Val = v; }
    }

    public class RubyBignum {
        public byte Sign;
        public byte[] Raw;
        public RubyBignum(byte s, byte[] r) { Sign = s; Raw = r; }
    }

    public class RubyStr {
        public byte[] Raw;
        public List<RubyIvar> Ivars = new List<RubyIvar>();
        public RubyStr(byte[] r) { Raw = r; }
        public RubyStr CloneStr() {
            RubyStr copy = new RubyStr(Raw);
            copy.Ivars.AddRange(Ivars);
            return copy;
        }
    }

    public static byte[] ZlibDecompress(byte[] data) {
        if (data == null || data.Length < 6) return new byte[0];
        using (MemoryStream src = new MemoryStream(data, 2, data.Length - 6))
        using (DeflateStream ds = new DeflateStream(src, CompressionMode.Decompress))
        using (MemoryStream dst = new MemoryStream()) {
            byte[] buf = new byte[4096];
            int r;
            while ((r = ds.Read(buf, 0, buf.Length)) > 0) {
                dst.Write(buf, 0, r);
            }
            return dst.ToArray();
        }
    }

    public static byte[] ZlibCompress(byte[] data) {
        using (MemoryStream dst = new MemoryStream()) {
            dst.WriteByte(0x78);
            dst.WriteByte(0x9C);
            using (DeflateStream ds = new DeflateStream(dst, CompressionMode.Compress, true)) {
                ds.Write(data, 0, data.Length);
            }
            uint s1 = 1, s2 = 0;
            for (int i = 0; i < data.Length; i++) {
                s1 = (s1 + data[i]) % 65521;
                s2 = (s2 + s1) % 65521;
            }
            uint adler = (s2 << 16) | s1;
            dst.WriteByte((byte)((adler >> 24) & 0xFF));
            dst.WriteByte((byte)((adler >> 16) & 0xFF));
            dst.WriteByte((byte)((adler >> 8) & 0xFF));
            dst.WriteByte((byte)(adler & 0xFF));
            return dst.ToArray();
        }
    }

    private class Reader {
        private byte[] d;
        private int pos = 0;
        private List<RubySym> syms = new List<RubySym>();
        private List<object> objs = new List<object>();

        public Reader(byte[] data) { d = data; }

        private byte ReadByte() {
            if (pos >= d.Length) throw new InvalidDataException("Unexpected EOF in Marshal data.");
            return d[pos++];
        }

        private byte[] ReadBytes(int n) {
            if (pos + n > d.Length) throw new InvalidDataException("Unexpected EOF reading Marshal slice.");
            byte[] res = new byte[n];
            Buffer.BlockCopy(d, pos, res, 0, n);
            pos += n;
            return res;
        }

        public int ReadLong() {
            byte b = ReadByte();
            sbyte c = unchecked((sbyte)b);
            if (c == 0) return 0;
            if (c > 0) {
                if (c > 4) return c - 5;
                int v = 0;
                for (int i = 0; i < c; i++) v |= (ReadByte() << (8 * i));
                return v;
            } else {
                if (c < -4) return c + 5;
                int cnt = -c;
                uint v = 0xFFFFFFFF;
                for (int i = 0; i < cnt; i++) {
                    v &= ~(0xFFu << (8 * i));
                    v |= ((uint)ReadByte() << (8 * i));
                }
                return unchecked((int)v);
            }
        }

        public object Load() {
            byte maj = ReadByte();
            byte min = ReadByte();
            if (maj != 4 || min != 8) throw new InvalidDataException("Unsupported Marshal version.");
            return ReadVal();
        }

        private object ReadVal() {
            byte tag = ReadByte();
            switch (tag) {
                case 0x30: return null;
                case 0x54: return true;
                case 0x46: return false;
                case 0x69: return (long)ReadLong();
                case 0x3A: {
                    int ln = ReadLong();
                    RubySym s = new RubySym(ReadBytes(ln));
                    syms.Add(s);
                    return s;
                }
                case 0x3B: {
                    int idx = ReadLong();
                    return syms[idx];
                }
                case 0x40: {
                    int idx = ReadLong();
                    object t = objs[idx];
                    if (t is RubyStr) return ((RubyStr)t).CloneStr();
                    return t;
                }
                case 0x6C: {
                    byte sign = ReadByte();
                    int words = ReadLong();
                    byte[] raw = ReadBytes(words * 2);
                    RubyBignum bn = new RubyBignum(sign, raw);
                    objs.Add(bn);
                    return bn;
                }
                case 0x49: {
                    object inner = ReadVal();
                    int cnt = ReadLong();
                    RubyStr rs = inner as RubyStr;
                    for (int i = 0; i < cnt; i++) {
                        object k = ReadVal();
                        object v = ReadVal();
                        if (rs != null) rs.Ivars.Add(new RubyIvar(k, v));
                    }
                    return inner;
                }
                case 0x22: {
                    int ln = ReadLong();
                    RubyStr s = new RubyStr(ReadBytes(ln));
                    objs.Add(s);
                    return s;
                }
                case 0x5B: {
                    int ln = ReadLong();
                    List<object> arr = new List<object>(ln);
                    objs.Add(arr);
                    for (int i = 0; i < ln; i++) arr.Add(ReadVal());
                    return arr;
                }
                default:
                    throw new InvalidDataException(String.Format("Unsupported Marshal tag: 0x{0:X2}", tag));
            }
        }
    }

    private class Writer {
        private MemoryStream buf = new MemoryStream();
        private Dictionary<string, int> syms = new Dictionary<string, int>();

        public Writer() {
            buf.WriteByte(0x04);
            buf.WriteByte(0x08);
        }

        private void WriteLong(int x) {
            if (x == 0) {
                buf.WriteByte(0x00);
            } else if (x > 0 && x < 123) {
                buf.WriteByte((byte)(x + 5));
            } else if (x > -124 && x < 0) {
                buf.WriteByte(unchecked((byte)(x - 5)));
            } else if (x >= 123) {
                if (x <= 0xFF) {
                    buf.WriteByte(1); buf.WriteByte((byte)x);
                } else if (x <= 0xFFFF) {
                    buf.WriteByte(2); buf.WriteByte((byte)(x & 0xFF)); buf.WriteByte((byte)((x >> 8) & 0xFF));
                } else if (x <= 0xFFFFFF) {
                    buf.WriteByte(3); buf.WriteByte((byte)(x & 0xFF)); buf.WriteByte((byte)((x >> 8) & 0xFF)); buf.WriteByte((byte)((x >> 16) & 0xFF));
                } else {
                    buf.WriteByte(4); buf.WriteByte((byte)(x & 0xFF)); buf.WriteByte((byte)((x >> 8) & 0xFF)); buf.WriteByte((byte)((x >> 16) & 0xFF)); buf.WriteByte((byte)((x >> 24) & 0xFF));
                }
            } else {
                uint u = unchecked((uint)x);
                if (x >= -0x100) {
                    buf.WriteByte(0xFF); buf.WriteByte((byte)(u & 0xFF));
                } else if (x >= -0x10000) {
                    buf.WriteByte(0xFE); buf.WriteByte((byte)(u & 0xFF)); buf.WriteByte((byte)((u >> 8) & 0xFF));
                } else if (x >= -0x1000000) {
                    buf.WriteByte(0xFD); buf.WriteByte((byte)(u & 0xFF)); buf.WriteByte((byte)((u >> 8) & 0xFF)); buf.WriteByte((byte)((u >> 16) & 0xFF));
                } else {
                    buf.WriteByte(0xFC); buf.WriteByte((byte)(u & 0xFF)); buf.WriteByte((byte)((u >> 8) & 0xFF)); buf.WriteByte((byte)((u >> 16) & 0xFF)); buf.WriteByte((byte)((u >> 24) & 0xFF));
                }
            }
        }

        private void WriteSym(byte[] raw) {
            string key = Convert.ToBase64String(raw);
            int idx;
            if (syms.TryGetValue(key, out idx)) {
                buf.WriteByte(0x3B);
                WriteLong(idx);
            } else {
                syms[key] = syms.Count;
                buf.WriteByte(0x3A);
                WriteLong(raw.Length);
                buf.Write(raw, 0, raw.Length);
            }
        }

        public void WriteVal(object val) {
            if (val == null) {
                buf.WriteByte(0x30);
            } else if (val is bool) {
                buf.WriteByte(((bool)val) ? (byte)0x54 : (byte)0x46);
            } else if (val is int || val is long) {
                long v = Convert.ToInt64(val);
                const long FMAX = (1L << 30) - 1;
                const long FMIN = -(1L << 30);
                if (v >= FMIN && v <= FMAX) {
                    buf.WriteByte(0x69);
                    WriteLong((int)v);
                } else {
                    buf.WriteByte(0x6C);
                    buf.WriteByte(v < 0 ? (byte)0x2D : (byte)0x2B);
                    ulong mag = (ulong)(v < 0 ? -v : v);
                    List<byte> bytes = new List<byte>();
                    while (mag > 0) { bytes.Add((byte)(mag & 0xFF)); mag >>= 8; }
                    if (bytes.Count == 0) bytes.Add(0);
                    if (bytes.Count % 2 == 1) bytes.Add(0);
                    WriteLong(bytes.Count / 2);
                    byte[] arr = bytes.ToArray();
                    buf.Write(arr, 0, arr.Length);
                }
            } else if (val is RubyBignum) {
                RubyBignum bn = (RubyBignum)val;
                buf.WriteByte(0x6C);
                buf.WriteByte(bn.Sign);
                WriteLong(bn.Raw.Length / 2);
                buf.Write(bn.Raw, 0, bn.Raw.Length);
            } else if (val is RubySym) {
                WriteSym(((RubySym)val).Raw);
            } else if (val is RubyStr) {
                RubyStr rs = (RubyStr)val;
                if (rs.Ivars.Count > 0) buf.WriteByte(0x49);
                buf.WriteByte(0x22);
                WriteLong(rs.Raw.Length);
                buf.Write(rs.Raw, 0, rs.Raw.Length);
                if (rs.Ivars.Count > 0) {
                    WriteLong(rs.Ivars.Count);
                    foreach (RubyIvar iv in rs.Ivars) {
                        WriteVal(iv.Key);
                        WriteVal(iv.Val);
                    }
                }
            } else if (val is List<object>) {
                List<object> list = (List<object>)val;
                buf.WriteByte(0x5B);
                WriteLong(list.Count);
                foreach (object item in list) WriteVal(item);
            } else {
                throw new InvalidDataException("Unsupported object type in Marshal writer.");
            }
        }

        public byte[] ToArray() { return buf.ToArray(); }
    }

    public static List<object> LoadScriptsBytes(byte[] raw) {
        Reader r = new Reader(raw);
        return (List<object>)r.Load();
    }

    public static byte[] DumpScriptsBytes(List<object> scripts) {
        Writer w = new Writer();
        w.WriteVal(scripts);
        return w.ToArray();
    }

    public static List<object> LoadScripts(string path) {
        return LoadScriptsBytes(File.ReadAllBytes(path));
    }

    public static void SaveScripts(string path, List<object> scripts) {
        File.WriteAllBytes(path, DumpScriptsBytes(scripts));
    }

    public static string GetTitle(object entryObj) {
        List<object> e = entryObj as List<object>;
        if (e == null || e.Count < 3) return "";
        RubyStr s = e[1] as RubyStr;
        if (s == null) return "";
        return Encoding.UTF8.GetString(s.Raw).Trim();
    }

    public static int FindMainIndex(List<object> scripts) {
        for (int i = scripts.Count - 1; i >= 0; i--) {
            List<object> e = scripts[i] as List<object>;
            if (e != null && e.Count >= 3) {
                if (GetTitle(e).Equals("main", StringComparison.OrdinalIgnoreCase)) return i;
                RubyStr codeStr = e[2] as RubyStr;
                if (codeStr != null) {
                    try {
                        string code = Encoding.UTF8.GetString(ZlibDecompress(codeStr.Raw));
                        if (code.Contains("rgss_main") || code.Contains("SceneManager.run") || code.Contains("$scene.main")) {
                            return i;
                        }
                    } catch {}
                }
            }
        }
        return Math.Max(scripts.Count - 1, 0);
    }

    public static List<object> MakeEntry(long magicId, string title, byte[] payloadUtf8, bool isRvdata2) {
        RubyStr titleObj = new RubyStr(Encoding.UTF8.GetBytes(title));
        if (isRvdata2) {
            titleObj.Ivars.Add(new RubyIvar(new RubySym(Encoding.ASCII.GetBytes("E")), true));
        }
        RubyStr dataObj = new RubyStr(ZlibCompress(payloadUtf8));
        List<object> entry = new List<object>(3);
        entry.Add(magicId);
        entry.Add(titleObj);
        entry.Add(dataObj);
        return entry;
    }
}
"@

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$SectionTag = "[CheatMenu]"
$JsPluginName = "RPGMCheat"
$JsPluginEntry = '{"name":"RPGMCheat","status":true,"description":"Universal Cheat Menu [F8]","parameters":{}}'
$HtmlScriptTag = '<script type="text/javascript" src="js/rpgm_cheat.js"></script>'

$ScriptFiles = @("Scripts.rvdata2", "Scripts.rvdata", "Scripts.rxdata")
$ArchiveExts = @(".rgss3a", ".rgss2a", ".rgssad")
$SubdirParents = @("www", "data", "js", "plugins", "audio", "img", "movies", "save", "locales", "swiftshader", "fonts", "system", "graphics")
$SkipScanDirs = @("img", "audio", "movies", "locales", "swiftshader", "save", "graphics", "fonts", "node_modules", ".git")

$Mode = "install"
$Standalone = $false
$TargetArg = $null
$InteractiveUsed = $false

foreach ($a in $args) {
    switch ($a) {
        "-h"           { $Mode = "help" }
        "--help"       { $Mode = "help" }
        "/?"           { $Mode = "help" }
        "-r"           { $Mode = "remove" }
        "--remove"     { $Mode = "remove" }
        "--uninstall"  { $Mode = "remove" }
        "-d"           { $Mode = "decrypt" }
        "--decrypt"    { $Mode = "decrypt" }
        "--extract"    { $Mode = "decrypt" }
        "--unpack"     { $Mode = "decrypt" }
        "-s"           { $Standalone = $true }
        "--standalone" { $Standalone = $true }
        "--embed"      { $Standalone = $true }
        default        { $TargetArg = $a }
    }
}

if ($Mode -eq "help") {
    Write-Host "Usage:"
    Write-Host "  inject.bat [options] [path_to_game_folder]"
    Write-Host ""
    Write-Host "Supported engines & encrypted archives (auto-detected):"
    Write-Host "  - RPG Maker MV / MZ   (www\js\plugins.js, js\plugins.js, index.html)"
    Write-Host "  - RPG Maker XP/VX/VXA (Data\Scripts.*, *.rgss3a, *.rgss2a, *.rgssad)"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  (default)          Installs cheat menu (automatically patches .rgss3a/.rgss2a/.rgssad!)."
    Write-Host "  -d, --decrypt      Extracts all files from .rgss3a/.rgss2a/.rgssad to disk."
    Write-Host "  -s, --standalone   For RGSS: embeds cheat.rb inside game scripts only."
    Write-Host "  -r, --remove       Cleanly uninstalls cheat menu & restores original archive."
    Write-Host "  -h, --help         Show this help message."
    exit 0
}

function Write-Utf8File([string]$Path, [string]$Text) {
    [IO.File]::WriteAllBytes($Path, $Utf8NoBom.GetBytes($Text))
}

function Get-IniScriptsRel([string]$Dir) {
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return $null }
    $IniFiles = @(Get-ChildItem -LiteralPath $Dir -Filter "*.ini" -File -ErrorAction SilentlyContinue)
    foreach ($ini in $IniFiles) {
        try {
            $txt = [IO.File]::ReadAllText($ini.FullName)
            $m = [regex]::Match($txt, '(?im)^\s*Scripts\s*=\s*(.+?)\s*$')
            if ($m.Success) {
                return $m.Groups[1].Value.Trim().Trim('"', "'")
            }
        } catch {}
    }
    return $null
}

function Find-RgssArchives([string]$Dir) {
    if (-not $Dir -or -not (Test-Path -LiteralPath $Dir -PathType Container)) { return @() }
    $res = New-Object System.Collections.Generic.List[string]
    foreach ($pref in @("Game.rgss3a", "Game.rgss2a", "Game.rgssad")) {
        $p = Join-Path $Dir $pref
        if (Test-Path -LiteralPath $p -PathType Leaf) { $res.Add($p) }
    }
    $allFiles = @(Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue)
    foreach ($f in $allFiles) {
        $ext = $f.Extension.ToLower()
        if (($ArchiveExts -contains $ext) -and (-not $res.Contains($f.FullName))) {
            $res.Add($f.FullName)
        }
    }
    return $res.ToArray()
}

function Find-RgssScripts([string]$Dir) {
    $iniRel = Get-IniScriptsRel $Dir
    if ($iniRel) {
        $cand = Join-Path $Dir $iniRel
        if (Test-Path -LiteralPath $cand -PathType Leaf) { return $cand }
    }
    foreach ($fn in $ScriptFiles) {
        foreach ($sub in @("Data", "")) {
            $cand = if ($sub) { Join-Path (Join-Path $Dir $sub) $fn } else { Join-Path $Dir $fn }
            if (Test-Path -LiteralPath $cand -PathType Leaf) { return $cand }
        }
    }
    return $null
}

function Test-MvMzWebRoot([string]$WebDir) {
    if (-not $WebDir -or -not (Test-Path -LiteralPath $WebDir -PathType Container)) { return $false }
    $jsDir = Join-Path $WebDir "js"
    if (Test-Path -LiteralPath $jsDir -PathType Container) {
        foreach ($mk in @("plugins.js", "rpg_core.js", "rmmz_core.js", "main.js")) {
            if (Test-Path -LiteralPath (Join-Path $jsDir $mk) -PathType Leaf) { return $true }
        }
    }
    $dataDir = Join-Path $WebDir "data"
    if (Test-Path -LiteralPath $dataDir -PathType Container) {
        foreach ($mk in @("System.json", "Actors.json", "Items.json", "MapInfos.json")) {
            if (Test-Path -LiteralPath (Join-Path $dataDir $mk) -PathType Leaf) { return $true }
        }
    }
    return $false
}

function Find-HtmlEntry([string]$GameRoot, [string]$WebRoot) {
    $idx = Join-Path $WebRoot "index.html"
    if (Test-Path -LiteralPath $idx -PathType Leaf) { return $idx }
    foreach ($base in @($GameRoot, $WebRoot)) {
        if (-not $base) { continue }
        $pkg = Join-Path $base "package.json"
        if (Test-Path -LiteralPath $pkg -PathType Leaf) {
            try {
                $raw = [IO.File]::ReadAllText($pkg, [Text.Encoding]::UTF8)
                $m = [regex]::Match($raw, '"main"\s*:\s*"([^"]+\.html?)"', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
                if ($m.Success) {
                    $cand = Join-Path $base ($m.Groups[1].Value.Replace('/', '\'))
                    if (Test-Path -LiteralPath $cand -PathType Leaf) { return $cand }
                }
            } catch {}
        }
    }
    return $null
}

function Probe-Directory([string]$CandDir) {
    if (-not $CandDir -or -not (Test-Path -LiteralPath $CandDir -PathType Container)) { return $null }

    # 1. RGSS archives (.rgss3a / .rgss2a / .rgssad) and/or loose Data\Scripts.*
    $arcs = @(Find-RgssArchives $CandDir)
    $rgss = Find-RgssScripts $CandDir
    if ($arcs.Count -gt 0 -or $rgss) {
        return @{
            Kind = "rgss"
            GameDir = $CandDir
            ArchivePath = if ($arcs.Count -gt 0) { $arcs[0] } else { $null }
            ScriptsPath = $rgss
            IniScriptsRel = (Get-IniScriptsRel $CandDir)
        }
    }

    # 2. RPG Maker MV (<GameDir>\www)
    $wwwDir = Join-Path $CandDir "www"
    if ((Test-Path -LiteralPath $wwwDir -PathType Container) -and (Test-MvMzWebRoot $wwwDir)) {
        return @{
            Kind = "js"
            EngineHint = "MV"
            GameDir = $CandDir
            WebRoot = $wwwDir
            HtmlPath = (Find-HtmlEntry $CandDir $wwwDir)
        }
    }

    # 3. Direct web root (RPG Maker MZ, web build, or user pointed directly to www\)
    if (Test-MvMzWebRoot $CandDir) {
        $isWww = ((Split-Path -Leaf $CandDir).ToLower() -eq "www")
        $parent = Split-Path -Parent $CandDir
        $gameRoot = if ($isWww -and $parent) { $parent } else { $CandDir }
        return @{
            Kind = "js"
            EngineHint = if ($isWww) { "MV" } else { "MV/MZ" }
            GameDir = $gameRoot
            WebRoot = $CandDir
            HtmlPath = (Find-HtmlEntry $gameRoot $CandDir)
        }
    }

    return $null
}

function Discover-FromPath([string]$InputPath, [bool]$ReportErrors) {
    $Expanded = [IO.Path]::GetFullPath($InputPath)

    if (Test-Path -LiteralPath $Expanded -PathType Leaf) {
        $ext = [IO.Path]::GetExtension($Expanded).ToLower()
        if (@(".rvdata2", ".rvdata", ".rxdata") -contains $ext) {
            $p = Split-Path -Parent $Expanded
            $r = if ((Split-Path -Leaf $p).ToLower() -eq "data") { Split-Path -Parent $p } else { $p }
            return @{ Kind = "rgss"; GameDir = $r; ArchivePath = $null; ScriptsPath = $Expanded; IniScriptsRel = $null }
        }
        if ($ArchiveExts -contains $ext) {
            $r = Split-Path -Parent $Expanded
            return @{ Kind = "rgss"; GameDir = $r; ArchivePath = $Expanded; ScriptsPath = (Find-RgssScripts $r); IniScriptsRel = (Get-IniScriptsRel $r) }
        }
        $StartDir = Split-Path -Parent $Expanded
    } elseif (Test-Path -LiteralPath $Expanded -PathType Container) {
        $StartDir = $Expanded
    } else {
        if ($ReportErrors) {
            Write-Host "[Error] Path not found: $Expanded" -ForegroundColor Red
        }
        return $null
    }

    $Candidates = New-Object System.Collections.Generic.List[string]
    $Candidates.Add($StartDir)
    $cur = $StartDir
    for ($step = 0; $step -lt 4; $step++) {
        $leaf = (Split-Path -Leaf $cur).ToLower()
        $par = Split-Path -Parent $cur
        if (-not $par -or $par -eq $cur) { break }
        if ($SubdirParents -contains $leaf) {
            if (-not $Candidates.Contains($par)) { $Candidates.Add($par) }
            $cur = $par
        } else {
            break
        }
    }

    foreach ($c in $Candidates) {
        $hit = Probe-Directory $c
        if ($hit) { return $hit }
    }

    if ($ReportErrors) {
        $Level1 = @(Get-ChildItem -LiteralPath $StartDir -Directory -ErrorAction SilentlyContinue | Where-Object { $SkipScanDirs -notcontains $_.Name.ToLower() -and -not $_.Name.StartsWith(".") })
        foreach ($d1 in $Level1) {
            $hit = Probe-Directory $d1.FullName
            if ($hit) { return $hit }
        }
        foreach ($d1 in $Level1) {
            $Level2 = @(Get-ChildItem -LiteralPath $d1.FullName -Directory -ErrorAction SilentlyContinue | Where-Object { $SkipScanDirs -notcontains $_.Name.ToLower() -and -not $_.Name.StartsWith(".") })
            foreach ($d2 in $Level2) {
                $hit = Probe-Directory $d2.FullName
                if ($hit) { return $hit }
            }
        }

        Write-Host "[Error] Could not find supported RPG Maker files in: $Expanded" -ForegroundColor Red
        Write-Host "        Checked for: MV/MZ (www\js\plugins.js, js\plugins.js, index.html, data\*.json)"
        Write-Host "                     and XP/VX/VXA (Data\Scripts.*, *.rgss3a/*.rgss2a/*.rgssad, Game.ini)."
    }
    return $null
}

$OwnDir = $env:INJECT_DIR.TrimEnd('\', '/')
$CheatRbPath = Join-Path $OwnDir "cheat.rb"
$CheatJsPath = Join-Path $OwnDir "cheat.js"

$Target = $null
if ([string]::IsNullOrWhiteSpace($TargetArg)) {
    $Target = Discover-FromPath (Get-Location).Path $false
    if (-not $Target) {
        $InteractiveUsed = $true
        $PromptMsg = if ($Mode -eq "decrypt") { "Enter path to the RPG Maker game folder (or .rgss* archive)" } else { "Enter path to the RPG Maker game folder" }
        $UserInput = Read-Host $PromptMsg
        $UserInput = $UserInput.Trim().Trim('"', "'")
        if ([string]::IsNullOrWhiteSpace($UserInput)) {
            Write-Host "[Error] No path provided." -ForegroundColor Red
            Read-Host "Press Enter to exit"
            exit 1
        }
        $Target = Discover-FromPath $UserInput $true
    }
} else {
    $Target = Discover-FromPath $TargetArg.Trim().Trim('"', "'") $true
}

if (-not $Target) {
    if ($InteractiveUsed) { Read-Host "Press Enter to exit" }
    exit 1
}

# ============================================================================
# Standalone Decrypt / Extract Mode (--decrypt)
# ============================================================================

if ($Mode -eq "decrypt") {
    if ($Target.Kind -ne "rgss") {
        Write-Host "[Info] RPG Maker MV/MZ projects do not use .rgss* archives (data\*.json and js\ are already unpacked)." -ForegroundColor Yellow
        if ($InteractiveUsed) { Read-Host "Press Enter to exit" }
        exit 0
    }
    $ArcPath = $Target.ArchivePath
    $GameDir = $Target.GameDir
    if (-not $ArcPath -or -not (Test-Path -LiteralPath $ArcPath -PathType Leaf)) {
        Write-Host "[Error] No .rgss3a/.rgss2a/.rgssad archive found in: $GameDir" -ForegroundColor Red
        if ($InteractiveUsed) { Read-Host "Press Enter to exit" }
        exit 1
    }
    try {
        Write-Host "[Decryptor] Opening archive: $ArcPath" -ForegroundColor Cyan
        $Arc = New-Object RgssArchive($ArcPath)
        Write-Host "[Decryptor] Detected RGSSAD v$($Arc.Version) ($($Arc.Entries.Count) files). Extracting to: $GameDir" -ForegroundColor Cyan
        $Arc.ExtractAll($GameDir)

        $BakArc = "$ArcPath.bak"
        if (Test-Path -LiteralPath $BakArc) { $BakArc = "$ArcPath.unpacked_bak" }
        Move-Item -LiteralPath $ArcPath -Destination $BakArc -Force
        if (Test-Path -LiteralPath "$ArcPath.rpgmcheat_bak") {
            Remove-Item -LiteralPath "$ArcPath.rpgmcheat_bak" -Force
        }
        Write-Host "[Decryptor] Renamed archive to $BakArc so the game loads unpacked files from disk." -ForegroundColor Green
        Write-Host "[Done] Archive fully unpacked!" -ForegroundColor Cyan
    } catch {
        Write-Host "[Error] $($_.Exception.Message)" -ForegroundColor Red
        if ($InteractiveUsed) { Read-Host "Press Enter to exit" }
        exit 1
    }
    if ($InteractiveUsed) { Read-Host "Press Enter to exit" }
    exit 0
}

# ============================================================================
# Execute Install / Uninstall for MV/MZ (JS) or XP/VX/VXA (RGSS + .rgss3a)
# ============================================================================

if ($Target.Kind -eq "js") {
    $WebRoot = $Target.WebRoot
    Write-Host "[Detected] RPG Maker $($Target.EngineHint) project at: $WebRoot" -ForegroundColor Cyan

    $JsDir = Join-Path $WebRoot "js"
    if ($Mode -eq "remove") {
        $RemovedAny = $false
        if (Test-Path -LiteralPath $JsDir -PathType Container) {
            $PluginsJs = Join-Path $JsDir "plugins.js"
            if (Test-Path -LiteralPath $PluginsJs -PathType Leaf) {
                $raw = [IO.File]::ReadAllText($PluginsJs, [Text.Encoding]::UTF8)
                if ($raw.Contains('"RPGMCheat"')) {
                    $c1 = [regex]::Replace($raw, ',\s*\{\s*"name"\s*:\s*"RPGMCheat"[^\r\n]*\}', '')
                    if ($c1 -eq $raw) {
                        $c1 = [regex]::Replace($raw, '\{\s*"name"\s*:\s*"RPGMCheat"[^\r\n]*\}\s*,\s*', '')
                    }
                    if ($c1 -eq $raw) {
                        $c1 = [regex]::Replace($raw, '\{\s*"name"\s*:\s*"RPGMCheat"[^\r\n]*\}\r?\n?', '')
                    }
                    Write-Utf8File $PluginsJs $c1
                    Write-Host "[Removed] Unregistered $JsPluginName from $PluginsJs" -ForegroundColor Green
                    $RemovedAny = $true
                }
            }
            $PluginFile = Join-Path (Join-Path $JsDir "plugins") "$JsPluginName.js"
            if (Test-Path -LiteralPath $PluginFile -PathType Leaf) {
                Remove-Item -LiteralPath $PluginFile -Force
                Write-Host "[Removed] Deleted $PluginFile" -ForegroundColor Green
                $RemovedAny = $true
            }
            $DirectJs = Join-Path $JsDir "rpgm_cheat.js"
            if (Test-Path -LiteralPath $DirectJs -PathType Leaf) {
                Remove-Item -LiteralPath $DirectJs -Force
                Write-Host "[Removed] Deleted $DirectJs" -ForegroundColor Green
                $RemovedAny = $true
            }
            $MainJs = Join-Path $JsDir "main.js"
            if (Test-Path -LiteralPath $MainJs -PathType Leaf) {
                $mt = [IO.File]::ReadAllText($MainJs, [Text.Encoding]::UTF8)
                if ($mt.Contains("rpgm_cheat.js")) {
                    $mt = [regex]::Replace($mt, '\r?\n// RPGMCheat Loader\r?\n[^\r\n]*rpgm_cheat\.js[^\r\n]*\r?\n?', "`n")
                    Write-Utf8File $MainJs $mt
                    Write-Host "[Removed] Cleaned loader from $MainJs" -ForegroundColor Green
                    $RemovedAny = $true
                }
            }
        }
        if ($Target.HtmlPath -and (Test-Path -LiteralPath $Target.HtmlPath -PathType Leaf)) {
            $ht = [IO.File]::ReadAllText($Target.HtmlPath, [Text.Encoding]::UTF8)
            if ($ht.Contains("rpgm_cheat.js")) {
                $ht = [regex]::Replace($ht, '(?i)\s*<script[^>]*rpgm_cheat\.js[^>]*></script>', '')
                Write-Utf8File $Target.HtmlPath $ht
                Write-Host "[Removed] Removed script tag from $($Target.HtmlPath)" -ForegroundColor Green
                $RemovedAny = $true
            }
        }
        if (-not $RemovedAny) {
            Write-Host "[Info] $JsPluginName was not installed in $WebRoot."
        }
    } else {
        if (-not (Test-Path -LiteralPath $CheatJsPath -PathType Leaf)) {
            Write-Host "[Error] cheat.js not found next to inject.bat: $CheatJsPath" -ForegroundColor Red
            if ($InteractiveUsed) { Read-Host "Press Enter to exit" }
            exit 1
        }
        if (-not (Test-Path -LiteralPath $JsDir -PathType Container)) {
            New-Item -ItemType Directory -Path $JsDir -Force | Out-Null
        }

        $PluginsJs = Join-Path $JsDir "plugins.js"
        $MainJs = Join-Path $JsDir "main.js"
        $UsedPluginsJs = $false

        if (Test-Path -LiteralPath $PluginsJs -PathType Leaf) {
            $raw = [IO.File]::ReadAllText($PluginsJs, [Text.Encoding]::UTF8)
            $Patched = $null
            $Verb = "Installed"

            if ([regex]::IsMatch($raw, '\{\s*"name"\s*:\s*"RPGMCheat"[^\r\n]*\}')) {
                $Patched = ([regex]'\{\s*"name"\s*:\s*"RPGMCheat"[^\r\n]*\}').Replace($raw, $JsPluginEntry, 1)
                $Verb = "Updated"
            } else {
                $mOpen = [regex]::Match($raw, '\$plugins\s*=\s*\[')
                $lastClose = $raw.LastIndexOf(']')
                if ($mOpen.Success -and $lastClose -ge ($mOpen.Index + $mOpen.Length - 1)) {
                    $openIdx = $raw.IndexOf('[', $mOpen.Index)
                    $inner = $raw.Substring($openIdx + 1, $lastClose - $openIdx - 1)
                    $trimmed = $inner.TrimEnd()
                    if ($trimmed.Length -eq 0) {
                        $Patched = $raw.Substring(0, $openIdx + 1) + "`n$JsPluginEntry`n" + $raw.Substring($lastClose)
                    } elseif ($trimmed.EndsWith(",")) {
                        $insPos = $openIdx + 1 + $trimmed.Length
                        $Patched = $raw.Substring(0, $insPos) + "`n$JsPluginEntry`n" + $raw.Substring($lastClose)
                    } else {
                        $insPos = $openIdx + 1 + $trimmed.Length
                        $Patched = $raw.Substring(0, $insPos) + ",`n$JsPluginEntry`n" + $raw.Substring($lastClose)
                    }
                }
            }

            if ($null -ne $Patched) {
                $PluginsDir = Join-Path $JsDir "plugins"
                if (-not (Test-Path -LiteralPath $PluginsDir -PathType Container)) {
                    New-Item -ItemType Directory -Path $PluginsDir -Force | Out-Null
                }
                $BakPath = "$PluginsJs.bak"
                if (-not (Test-Path -LiteralPath $BakPath -PathType Leaf)) {
                    Copy-Item -LiteralPath $PluginsJs -Destination $BakPath
                    Write-Host "[Backup] Created backup: $BakPath"
                }
                Write-Utf8File $PluginsJs $Patched
                $DestPlugin = Join-Path $PluginsDir "$JsPluginName.js"
                Copy-Item -LiteralPath $CheatJsPath -Destination $DestPlugin -Force
                Write-Host "[$Verb] Registered $JsPluginName in $PluginsJs" -ForegroundColor Green
                Write-Host "[File] Copied plugin to $DestPlugin"
                $UsedPluginsJs = $true
            }
        }

        if (-not $UsedPluginsJs) {
            $DestScript = Join-Path $JsDir "rpgm_cheat.js"
            Copy-Item -LiteralPath $CheatJsPath -Destination $DestScript -Force
            $HtmlPath = $Target.HtmlPath

            if ($HtmlPath -and (Test-Path -LiteralPath $HtmlPath -PathType Leaf)) {
                $ht = [IO.File]::ReadAllText($HtmlPath, [Text.Encoding]::UTF8)
                if (-not $ht.Contains("rpgm_cheat.js")) {
                    $BakHtml = "$HtmlPath.bak"
                    if (-not (Test-Path -LiteralPath $BakHtml -PathType Leaf)) {
                        Copy-Item -LiteralPath $HtmlPath -Destination $BakHtml
                        Write-Host "[Backup] Created backup: $BakHtml"
                    }
                    if ([regex]::IsMatch($ht, '(?i)</body\s*>')) {
                        $ht = ([regex]'(?i)(</body\s*>)').Replace($ht, "$HtmlScriptTag`n`$1", 1)
                    } else {
                        $ht = $ht.TrimEnd() + "`n$HtmlScriptTag`n"
                    }
                    Write-Utf8File $HtmlPath $ht
                    Write-Host "[Installed] Injected script tag into $HtmlPath" -ForegroundColor Green
                } else {
                    Write-Host "[Updated] Refreshed $DestScript (already linked in $HtmlPath)" -ForegroundColor Green
                }
            } elseif (Test-Path -LiteralPath $MainJs -PathType Leaf) {
                $mt = [IO.File]::ReadAllText($MainJs, [Text.Encoding]::UTF8)
                if (-not $mt.Contains("rpgm_cheat.js")) {
                    $BakMain = "$MainJs.bak"
                    if (-not (Test-Path -LiteralPath $BakMain -PathType Leaf)) {
                        Copy-Item -LiteralPath $MainJs -Destination $BakMain
                        Write-Host "[Backup] Created backup: $BakMain"
                    }
                    $Hook = "`n// RPGMCheat Loader`n(function(){var s=document.createElement(`"script`");s.src=`"js/rpgm_cheat.js`";document.body.appendChild(s);})();`n"
                    Write-Utf8File $MainJs ($mt + $Hook)
                    Write-Host "[Installed] Appended loader to $MainJs" -ForegroundColor Green
                }
            } else {
                $PluginsDir = Join-Path $JsDir "plugins"
                New-Item -ItemType Directory -Path $PluginsDir -Force | Out-Null
                $DestPlugin = Join-Path $PluginsDir "$JsPluginName.js"
                Copy-Item -LiteralPath $CheatJsPath -Destination $DestPlugin -Force
                Write-Utf8File $PluginsJs "// Generated by RPG Maker.`nvar `$plugins =`n[`n$JsPluginEntry`n];`n"
                Write-Host "[Installed] Created $PluginsJs and $DestPlugin" -ForegroundColor Green
            }
        }

        Write-Host "[Done] Launch the game and press F8 on the map or in battle!" -ForegroundColor Cyan
    }
} else {
    $GameDir = $Target.GameDir
    $ArchivePath = $Target.ArchivePath
    $ScriptsPath = $Target.ScriptsPath
    $DispLoc = if ($ArchivePath) { $ArchivePath } else { $ScriptsPath }
    Write-Host "[Detected] RPG Maker RGSS target: $DispLoc" -ForegroundColor Cyan

    function Inject-IntoScriptsBytes([byte[]]$RawBytes, [string]$NameHint, [byte[]]$PayloadUtf8) {
        $Scripts = [RpgmCodec]::LoadScriptsBytes($RawBytes)
        $IsRvdata2 = $NameHint.ToLower().EndsWith(".rvdata2")
        $MagicId = [long](Get-Random -Minimum 10000000 -Maximum 99999999)
        $NewEntry = [RpgmCodec]::MakeEntry($MagicId, $SectionTag, $PayloadUtf8, $IsRvdata2)

        $ExistingIdx = -1
        for ($i = 0; $i -lt $Scripts.Count; $i++) {
            if ([RpgmCodec]::GetTitle($Scripts[$i]) -eq $SectionTag) {
                $ExistingIdx = $i
                break
            }
        }

        if ($ExistingIdx -ge 0) {
            $Scripts[$ExistingIdx] = $NewEntry
            $msg = "updated at slot #$ExistingIdx"
        } else {
            $InsertAt = [RpgmCodec]::FindMainIndex($Scripts)
            $Scripts.Insert($InsertAt, $NewEntry)
            $msg = "inserted above Main at slot #$InsertAt"
        }
        return @{ Bytes = ([RpgmCodec]::DumpScriptsBytes($Scripts)); Msg = $msg }
    }

    if ($Mode -eq "remove") {
        $RemovedAny = $false
        if ($ArchivePath -and (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
            if ([RgssArchive]::RevertPatch($ArchivePath)) {
                Write-Host "[Removed] Restored original unpatched archive: $ArchivePath" -ForegroundColor Green
                $RemovedAny = $true
            } else {
                try {
                    $Arc = New-Object RgssArchive($ArchivePath)
                    $SEntry = $Arc.FindScriptsEntry($Target.IniScriptsRel)
                    if ($SEntry) {
                        $Scripts = [RpgmCodec]::LoadScriptsBytes($Arc.ReadEntryBytes($SEntry))
                        $Before = $Scripts.Count
                        for ($i = $Scripts.Count - 1; $i -ge 0; $i--) {
                            if ([RpgmCodec]::GetTitle($Scripts[$i]) -eq $SectionTag) { $Scripts.RemoveAt($i) }
                        }
                        if ($Scripts.Count -lt $Before) {
                            $Arc.PatchScriptsEntry($SEntry, [RpgmCodec]::DumpScriptsBytes($Scripts))
                            Write-Host "[Removed] Removed $SectionTag from $ArchivePath." -ForegroundColor Green
                            $RemovedAny = $true
                        }
                    }
                } catch {}
            }
        }
        if ($ScriptsPath -and (Test-Path -LiteralPath $ScriptsPath -PathType Leaf)) {
            $Scripts = [RpgmCodec]::LoadScripts($ScriptsPath)
            $Before = $Scripts.Count
            for ($i = $Scripts.Count - 1; $i -ge 0; $i--) {
                if ([RpgmCodec]::GetTitle($Scripts[$i]) -eq $SectionTag) {
                    $Scripts.RemoveAt($i)
                }
            }
            if ($Scripts.Count -lt $Before) {
                [RpgmCodec]::SaveScripts($ScriptsPath, $Scripts)
                Write-Host "[Removed] $SectionTag removed from $ScriptsPath." -ForegroundColor Green
                $RemovedAny = $true
            }
        }
        $TargetCheat = Join-Path $GameDir "cheat.rb"
        if ((Test-Path -LiteralPath $TargetCheat -PathType Leaf) -and ([IO.Path]::GetFullPath($TargetCheat) -ne [IO.Path]::GetFullPath($CheatRbPath))) {
            Remove-Item -LiteralPath $TargetCheat -Force
            Write-Host "[Removed] Deleted $TargetCheat." -ForegroundColor Green
            $RemovedAny = $true
        }
        if (-not $RemovedAny) {
            Write-Host "[Info] $SectionTag was not installed in $GameDir."
        }
    } else {
        if (-not (Test-Path -LiteralPath $CheatRbPath -PathType Leaf)) {
            Write-Host "[Error] cheat.rb not found next to inject.bat: $CheatRbPath" -ForegroundColor Red
            if ($InteractiveUsed) { Read-Host "Press Enter to exit" }
            exit 1
        }

        $CheatText = [IO.File]::ReadAllText($CheatRbPath, [Text.Encoding]::UTF8)
        $CheatText = $CheatText -replace "\A#.*coding:.*\r?\n", ""

        if ($Standalone) {
            $Payload = "# -*- coding: utf-8 -*-`n# Auto-generated by RPGMCheat inject.bat (standalone)`nunless defined?(RPGMCheat)`n$CheatText`nend`n"
        } else {
            $Loader = @'
# -*- coding: utf-8 -*-
# Auto-generated by RPGMCheat inject.bat (hybrid loader + fallback)
if File.exist?("cheat.rb") && !defined?(RPGMCheat)
  rpgm_cheat_raw = File.open("cheat.rb", "rb") { |f| f.read }
  rpgm_cheat_bom = [0xEF, 0xBB, 0xBF].pack("C*")
  if rpgm_cheat_raw.length >= 3 && rpgm_cheat_raw[0, 3] == rpgm_cheat_bom
    rpgm_cheat_raw = rpgm_cheat_raw[3, rpgm_cheat_raw.length - 3]
  end
  if rpgm_cheat_raw.respond_to?(:force_encoding)
    rpgm_cheat_raw.force_encoding("UTF-8")
  end
  eval(rpgm_cheat_raw, TOPLEVEL_BINDING, "cheat.rb")
end

unless defined?(RPGMCheat)
'@
            $Payload = "$Loader`n$CheatText`nend`n"
        }
        $PayloadBytes = $Utf8NoBom.GetBytes($Payload)
        $PatchedArc = $false

        if ($ArchivePath -and (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
            Write-Host "[Decryptor] Reading encrypted archive: $ArchivePath" -ForegroundColor Cyan
            try {
                $Arc = New-Object RgssArchive($ArchivePath)
                $SEntry = $Arc.FindScriptsEntry($Target.IniScriptsRel)
                if ($SEntry) {
                    $RawScripts = $Arc.ReadEntryBytes($SEntry)
                    if ($RawScripts.Length -lt 2 -or $RawScripts[0] -ne 4 -or $RawScripts[1] -ne 8) {
                        throw "Decrypted Scripts entry did not match Ruby Marshal 4.8 header."
                    }
                    $Res = Inject-IntoScriptsBytes $RawScripts $SEntry.Name $PayloadBytes
                    $Arc.PatchScriptsEntry($SEntry, $Res.Bytes)
                    Write-Host "[Installed] $SectionTag $($Res.Msg) directly inside $(Split-Path -Leaf $ArchivePath) ($($SEntry.Name))!" -ForegroundColor Green
                    $PatchedArc = $true
                }
            } catch {
                if (-not $ScriptsPath) {
                    Write-Host "[Error] Could not patch $($ArchivePath): $($_.Exception.Message)" -ForegroundColor Red
                    if ($InteractiveUsed) { Read-Host "Press Enter to exit" }
                    exit 1
                }
                Write-Host "[Warning] Could not patch $(Split-Path -Leaf $ArchivePath): $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }

        if ($ScriptsPath -and (Test-Path -LiteralPath $ScriptsPath -PathType Leaf)) {
            $BakPath = "$ScriptsPath.bak"
            if (-not (Test-Path -LiteralPath $BakPath -PathType Leaf)) {
                Copy-Item -LiteralPath $ScriptsPath -Destination $BakPath
                Write-Host "[Backup] Created backup: $BakPath"
            }
            $RawLoose = [IO.File]::ReadAllBytes($ScriptsPath)
            $ResLoose = Inject-IntoScriptsBytes $RawLoose $ScriptsPath $PayloadBytes
            [IO.File]::WriteAllBytes($ScriptsPath, $ResLoose.Bytes)
            Write-Host "[Installed] $SectionTag $($ResLoose.Msg) in $ScriptsPath." -ForegroundColor Green
        }

        if (-not $PatchedArc -and -not ($ScriptsPath -and (Test-Path -LiteralPath $ScriptsPath -PathType Leaf))) {
            Write-Host "[Error] No Scripts entry found in $GameDir." -ForegroundColor Red
            if ($InteractiveUsed) { Read-Host "Press Enter to exit" }
            exit 1
        }

        $TargetCheat = Join-Path $GameDir "cheat.rb"
        $SameFile = ([IO.Path]::GetFullPath($TargetCheat) -eq [IO.Path]::GetFullPath($CheatRbPath))
        if ($Standalone) {
            if ((Test-Path -LiteralPath $TargetCheat -PathType Leaf) -and (-not $SameFile)) {
                Remove-Item -LiteralPath $TargetCheat -Force
            }
            Write-Host "[Mode] Standalone: cheat menu embedded inside game scripts."
        } else {
            if (-not $SameFile) {
                Copy-Item -LiteralPath $CheatRbPath -Destination $TargetCheat -Force
            }
            Write-Host "[File] Copied $TargetCheat (edit settings anytime without re-injecting)."
        }

        Write-Host "[Done] Launch the game and press F8 on the map or in battle!" -ForegroundColor Cyan
    }
}

if ($InteractiveUsed) {
    Read-Host "Press Enter to exit"
}
exit 0
