#!/usr/bin/env python3
"""
gpb_fields.py — iOS Mach-O バイナリから ObjC protobuf (GPBMessage) の
                フィールド番号表を抽出する。

── 何ができるか ────────────────────────────────────────────────
Google の iOS アプリ (YouTube / YouTube Music など) は InnerTube の
protobuf を ObjC の GPBMessage として実装しており、`__DATA/__data` に
`GPBMessageFieldDescription` 構造体の配列を持っている。この構造体には
**フィールド名の文字列ポインタとフィールド番号が並んで** 入っているので、
バイナリから直接「どのフィールドが何番か」を復元できる。

    $ python3 gpb_fields.py YouTube visitorData
    → visitorData を含む descriptor 配列を丸ごと出力

`.proto` が手元に無くても、`X-Goog-Visitor-Id` や `rolloutToken` のような
フィールドの番号を確定できる。

── 使えない相手 ────────────────────────────────────────────────
`video_streaming::*` (SABR/UMP の ClientAbrState / BufferedRange /
StreamerContext / MediaHeader など) は C++ の **protobuf-lite** で
コンパイルされており、フィールド名がバイナリに残っていない。
このスクリプトでは取れないので、OSS の定義か実応答からの逆算に頼る。

── 使い方 ──────────────────────────────────────────────────────
    # フィールド名から、それを含むメッセージの全フィールドを出す
    python3 gpb_fields.py <binary> <fieldName> [fieldName ...]

    # 既知の番号で検算しながら実行する (推奨)
    python3 gpb_fields.py <binary> visitorData --verify clientName=16

    # 単に文字列を探す (どんなフィールド名があるか見たいとき)
    python3 gpb_fields.py <binary> --grep client

    # JSON で出す
    python3 gpb_fields.py <binary> visitorData --json

── 構造体レイアウト (32 バイト / arm64) ────────────────────────
    +0   const char *name          chained fixup ポインタ
                                   低 36bit = (vmaddr - 0x100000000)
    +8   dataTypeSpecific
    +16  uint32 number             ★ フィールド番号
    +20  uint32 hasIndex
    +24  uint32 offset
    +28  uint16 flags
    +30  uint8  dataType

!! 注意 !!
`number` を +0 と読み違えると全体が 1 レコードずれ、すべての番号が
1 小さく出る。**必ず --verify で既知の番号を検算すること。**
既定では clientName=16 / clientVersion=17 を自動検算する。
"""

import argparse
import json
import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
LC_SEGMENT_64 = 0x19
RECORD_SIZE = 32
NAME_OFF = 0
NUMBER_OFF = 16
HAS_INDEX_OFF = 20
OFFSET_OFF = 24
FLAGS_OFF = 28
DATA_TYPE_OFF = 30

# chained fixup (DYLD_CHAINED_PTR_64) の target は下位 36bit
TARGET_MASK = 0xFFFFFFFFF

# GPBDataType (protobuf ObjC ランタイム)
DATA_TYPES = {
    0: "bool", 1: "fixed32", 2: "sfixed32", 3: "float",
    4: "fixed64", 5: "sfixed64", 6: "double", 7: "int32",
    8: "int64", 9: "sint32", 10: "sint64", 11: "uint32",
    12: "uint64", 13: "bytes", 14: "string", 15: "message",
    16: "group", 17: "enum",
}

# 既定の検算対象。InnerTube の ClientInfo で確定している値。
DEFAULT_VERIFY = {"clientName": 16, "clientVersion": 17}


class MachO:
    """arm64 Mach-O から __cstring と __data を読むだけの最小パーサ。"""

    def __init__(self, path):
        self.path = path
        self.fh = open(path, "rb")
        head = self.fh.read(64 * 1024)
        magic = struct.unpack("<I", head[:4])[0]
        if magic != MH_MAGIC_64:
            raise SystemExit(
                f"{path}: arm64 の単一アーキテクチャ Mach-O ではありません "
                f"(magic=0x{magic:08x})。\n"
                "  FAT バイナリなら lipo -thin arm64 で切り出してください。"
            )
        ncmds = struct.unpack("<I", head[16:20])[0]
        self.base = None
        self.sections = {}
        off = 32
        for _ in range(ncmds):
            cmd, cmdsize = struct.unpack("<II", head[off:off + 8])
            if cmd == LC_SEGMENT_64:
                segname = head[off + 8:off + 24].rstrip(b"\0").decode()
                vmaddr = struct.unpack("<Q", head[off + 24:off + 32])[0]
                if segname == "__TEXT":
                    self.base = vmaddr
                nsects = struct.unpack("<I", head[off + 64:off + 68])[0]
                so = off + 72
                for _ in range(nsects):
                    sect = head[so:so + 16].rstrip(b"\0").decode()
                    addr, size = struct.unpack("<QQ", head[so + 32:so + 48])
                    foff = struct.unpack("<I", head[so + 48:so + 52])[0]
                    self.sections.setdefault(
                        (segname, sect), (addr, size, foff))
                    so += 80
            off += cmdsize
        if self.base is None:
            raise SystemExit(f"{path}: __TEXT セグメントが見つかりません")

        self.cstr_addr, cstr_size, cstr_foff = self._need("__TEXT", "__cstring")
        self.fh.seek(cstr_foff)
        self.cstr = self.fh.read(cstr_size)

        # descriptor 配列が置かれうるセクション
        self.data_regions = []
        for key in (("__DATA", "__data"),
                    ("__DATA", "__objc_const"),
                    ("__DATA_CONST", "__const"),
                    ("__DATA_DIRTY", "__data")):
            if key in self.sections:
                addr, size, foff = self.sections[key]
                self.fh.seek(foff)
                self.data_regions.append((addr, size, self.fh.read(size)))
        if not self.data_regions:
            raise SystemExit(f"{path}: 走査できるデータセクションがありません")

    def _need(self, seg, sect):
        if (seg, sect) not in self.sections:
            raise SystemExit(f"{self.path}: {seg},{sect} が見つかりません")
        return self.sections[(seg, sect)]

    # ---- 文字列 ----

    def string_at(self, vmaddr):
        """VM アドレスの C 文字列を返す。__cstring の外なら None。"""
        lo = self.cstr_addr
        if not (lo <= vmaddr < lo + len(self.cstr)):
            return None
        off = vmaddr - lo
        end = self.cstr.find(b"\0", off)
        if end < 0:
            return None
        try:
            text = self.cstr[off:end].decode("utf-8")
        except UnicodeDecodeError:
            return None
        return text or None

    def find_strings(self, names):
        """名前 → VM アドレス。同名が複数あれば最初のものを採る。"""
        wanted = {n.encode() for n in names}
        out = {}
        i = 0
        while wanted and i < len(self.cstr):
            j = self.cstr.find(b"\0", i)
            if j < 0:
                break
            s = self.cstr[i:j]
            if s in wanted:
                out[s.decode()] = self.cstr_addr + i
                wanted.discard(s)
            i = j + 1
        return out

    def grep_strings(self, needle, limit=200):
        """部分一致で識別子っぽい文字列を拾う (フィールド名探し用)。"""
        pat = needle.lower().encode()
        out = []
        i = 0
        while i < len(self.cstr) and len(out) < limit:
            j = self.cstr.find(b"\0", i)
            if j < 0:
                break
            s = self.cstr[i:j]
            if 2 < len(s) < 64 and pat in s.lower():
                try:
                    t = s.decode("ascii")
                    if t.replace("_", "").isalnum():
                        out.append(t)
                except UnicodeDecodeError:
                    pass
            i = j + 1
        return sorted(set(out))

    # ---- descriptor ----

    def pointers_to(self, vmaddr):
        """指定 VM アドレスを指すポインタの VM アドレスを列挙する。"""
        target = (vmaddr - self.base) & TARGET_MASK
        hits = []
        for addr, size, buf in self.data_regions:
            start = 0
            n = len(buf) - 8
            while start < n:
                val = int.from_bytes(buf[start:start + 8], "little")
                if (val & TARGET_MASK) == target:
                    hits.append(addr + start)
                start += 8
        return hits

    def _read(self, vmaddr, length):
        for addr, size, buf in self.data_regions:
            if addr <= vmaddr < addr + size:
                off = vmaddr - addr
                return buf[off:off + length]
        return None

    def record_at(self, vmaddr):
        """descriptor 1 件を読む。name が解決できなければ None。"""
        raw = self._read(vmaddr, RECORD_SIZE)
        if raw is None or len(raw) < RECORD_SIZE:
            return None
        ptr = int.from_bytes(raw[NAME_OFF:NAME_OFF + 8], "little")
        name = self.string_at((ptr & TARGET_MASK) + self.base)
        if name is None:
            return None
        number, has_index, offset = struct.unpack(
            "<III", raw[NUMBER_OFF:NUMBER_OFF + 12])
        flags = struct.unpack("<H", raw[FLAGS_OFF:FLAGS_OFF + 2])[0]
        data_type = raw[DATA_TYPE_OFF]
        if number == 0 or number > 100_000:
            return None
        return {
            "addr": vmaddr,
            "name": name,
            "number": number,
            "hasIndex": has_index,
            "offset": offset,
            "flags": flags,
            "dataType": DATA_TYPES.get(data_type, f"dt{data_type}"),
        }

    def array_containing(self, vmaddr):
        """
        指定アドレスを含む descriptor 配列を、番号の単調増加が
        途切れるところまで前後に広げて返す。
        """
        here = self.record_at(vmaddr)
        if here is None:
            return []
        rows = [here]

        cur = vmaddr
        while True:
            prev = self.record_at(cur - RECORD_SIZE)
            if prev is None or prev["number"] >= rows[0]["number"]:
                break
            rows.insert(0, prev)
            cur -= RECORD_SIZE

        cur = vmaddr
        while True:
            nxt = self.record_at(cur + RECORD_SIZE)
            if nxt is None or nxt["number"] <= rows[-1]["number"]:
                break
            rows.append(nxt)
            cur += RECORD_SIZE
        return rows


def verify(rows, expectations):
    """既知の番号と突き合わせて、レコード境界のずれを検出する。"""
    by_name = {r["name"]: r["number"] for r in rows}
    problems = []
    checked = 0
    for name, expected in expectations.items():
        if name in by_name:
            checked += 1
            if by_name[name] != expected:
                problems.append(
                    f"{name} は {expected} のはずが {by_name[name]} と読めた")
    return checked, problems


def main():
    ap = argparse.ArgumentParser(
        description="iOS Mach-O から ObjC protobuf のフィールド番号表を抽出する",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="例:\n"
               "  python3 gpb_fields.py YouTube visitorData\n"
               "  python3 gpb_fields.py YouTube --grep potoken\n"
               "  python3 gpb_fields.py YouTubeMusic visitorData --json\n")
    ap.add_argument("binary", help="Mach-O 実行ファイル (Payload/*.app/<名前>)")
    ap.add_argument("fields", nargs="*", help="番号を知りたいフィールド名")
    ap.add_argument("--grep", metavar="TEXT",
                    help="フィールド名を部分一致で探すだけ")
    ap.add_argument("--verify", action="append", default=[], metavar="NAME=NUM",
                    help="既知の番号で検算する (既定: clientName=16,clientVersion=17)")
    ap.add_argument("--json", action="store_true", help="JSON で出力")
    ap.add_argument("--all-hits", action="store_true",
                    help="同名フィールドが複数あるとき、全ての配列を出す")
    args = ap.parse_args()

    macho = MachO(args.binary)

    if args.grep:
        found = macho.grep_strings(args.grep)
        if args.json:
            print(json.dumps(found, ensure_ascii=False, indent=2))
        else:
            print(f"'{args.grep}' を含む識別子: {len(found)} 件")
            for name in found:
                print(f"  {name}")
        return

    if not args.fields:
        ap.error("フィールド名を 1 つ以上指定するか --grep を使ってください")

    expectations = dict(DEFAULT_VERIFY)
    for item in args.verify:
        if "=" not in item:
            ap.error(f"--verify は NAME=NUMBER の形式です: {item}")
        name, num = item.split("=", 1)
        expectations[name.strip()] = int(num)

    addrs = macho.find_strings(args.fields)
    missing = [f for f in args.fields if f not in addrs]
    for name in missing:
        print(f"[!] 文字列 '{name}' がバイナリに見つかりません", file=sys.stderr)

    results = []
    seen_arrays = set()

    for name in args.fields:
        if name not in addrs:
            continue
        pointers = macho.pointers_to(addrs[name])
        if not pointers:
            print(f"[!] '{name}' を指す descriptor ポインタがありません "
                  f"(protobuf-lite かもしれません)", file=sys.stderr)
            continue
        for ptr in pointers:
            rows = macho.array_containing(ptr)
            if len(rows) < 2:
                continue
            key = rows[0]["addr"]
            if key in seen_arrays:
                continue
            seen_arrays.add(key)
            checked, problems = verify(rows, expectations)
            results.append({
                "trigger": name,
                "arrayStart": f"0x{rows[0]['addr']:x}",
                "arrayEnd": f"0x{rows[-1]['addr']:x}",
                "fieldCount": len(rows),
                "verified": checked,
                "problems": problems,
                "fields": [
                    {"number": r["number"], "name": r["name"],
                     "type": r["dataType"]}
                    for r in rows
                ],
            })
            if not args.all_hits:
                break

    if args.json:
        print(json.dumps(results, ensure_ascii=False, indent=2))
        return

    if not results:
        print("該当する descriptor 配列が見つかりませんでした。")
        return

    for res in results:
        print("=" * 64)
        print(f"'{res['trigger']}' を含む descriptor 配列")
        print(f"  {res['arrayStart']} 〜 {res['arrayEnd']}  "
              f"({res['fieldCount']} フィールド)")
        if res["problems"]:
            print()
            print("  !! 検算に失敗しました — レコード境界がずれています !!")
            for p in res["problems"]:
                print(f"     {p}")
            print("     出力された番号は信用しないでください。")
        elif res["verified"]:
            print(f"  検算 OK ({res['verified']} 件の既知フィールドと一致)")
        else:
            print("  (検算に使える既知フィールドがこの配列にありません。"
                  "--verify で指定してください)")
        print()
        highlight = set(res["trigger"].lower() for _ in [0])
        for f in res["fields"]:
            star = " ★" if f["name"].lower() in highlight else ""
            print(f"  {f['number']:>5} = {f['name']:<36} ({f['type']}){star}")
        print()


if __name__ == "__main__":
    main()
