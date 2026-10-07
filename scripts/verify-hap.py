#!/usr/bin/env python3
"""Verify stripped HAP library against the source build and write portable build provenance."""
import datetime
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parent.parent


def allocated_sections(data):
    if data[:6] != b'\x7fELF\x02\x01':
        raise ValueError('Expected little-endian ELF64')
    header = struct.unpack_from('<16sHHIQQQIHHHHHH', data)
    offset, entry_size, count, strings = header[6], header[11], header[12], header[13]
    rows = [struct.unpack_from('<IIQQQQIIQQ', data, offset + i * entry_size) for i in range(count)]
    string_row = rows[strings]
    table = data[string_row[4]:string_row[4] + string_row[5]]
    sections = {}
    for row in rows:
        if row[2] & 2:
            name = table[row[0]:].split(b'\0', 1)[0].decode()
            checksum = hashlib.sha256(data[row[4]:row[4] + row[5]]).hexdigest() if row[1] != 8 else None
            sections[name] = (row[1], row[2], row[3], row[5], checksum)
    return sections


def main():
    hap = Path(sys.argv[1]).resolve()
    subprocess.run(['node', 'scripts/native-provenance.cjs', '--check', 'arm64-v8a'], cwd=ROOT, check=True)
    native = (ROOT / 'proxy_core/libs/arm64-v8a/libflclash.so').read_bytes()
    provenance = json.loads((ROOT / 'proxy_core/libs/arm64-v8a/libflclash.build.json').read_text())
    with zipfile.ZipFile(hap) as archive:
        names = [name for name in archive.namelist() if name.endswith('/libflclash.so')]
        if len(names) != 1:
            raise ValueError(f'Unexpected native library entries: {names}')
        packed = archive.read(names[0])
    source_sections, packed_sections = allocated_sections(native), allocated_sections(packed)
    if not source_sections or source_sections != packed_sections:
        raise ValueError('Packaged ELF differs from the verified native build')
    if provenance['contractHash'].encode() not in packed:
        raise ValueError('Packaged RPC contract mismatch')
    report = {
        'verifiedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'sourceCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        'sourceDirty': bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True).strip()),
        'native': provenance,
        'packagedNativeSHA256': hashlib.sha256(packed).hexdigest(),
        'identicalAllocatedELFSections': len(source_sections),
        'hapSHA256': hashlib.sha256(hap.read_bytes()).hexdigest(),
        'hapBytes': hap.stat().st_size,
    }
    output = hap.with_suffix('.build.json')
    output.write_text(json.dumps(report, indent=2) + '\n')
    print(f'Package verified; build record: {output}')


if __name__ == '__main__':
    main()
