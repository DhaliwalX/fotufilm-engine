#!/usr/bin/env python3
"""Optional CC0 camera regression inputs; only ignored build output receives image bytes.

These four entries are tagged CC0 in https://raw.pixls.us/json/getrepository.php.
No photograph, EXIF record, or generated preview is committed to the engine.
"""
import hashlib
from pathlib import Path
import sys
from urllib.parse import quote
from urllib.request import urlopen

CAMERAS = [
    ("1964", "Fujifilm - FinePix S3Pro - 3:2.RAF", "038e5a13a22513f53d143e328a66e2de8071809565db696ecac84b4364fcb75b"),
    ("2249", "Nikon - D700 - 14bit 14bit compressed (Lossless) (3:2).NEF", "00c3314f2ccf92aff17644943e6149e8793b517c24bb2c38a15ec41f3af109cb"),
    ("2421", "Fujifilm - X-T1 - 14bit 14bit uncompressed (3:2).RAF", "e994a1fd6e87e392432fe146a35b0b88584dc2bd50bee2c8c7e886ac2b59fcde"),
    ("4671", "Canon - EOS RP - 3:2.CR3", "4a859ab137f792aedaf3416b0aad1497ebaab02052a49453902e226699154aa7"),
]

output = Path(sys.argv[1])
output.mkdir(parents=True, exist_ok=True)
for identifier, name, checksum in CAMERAS:
    path = output / identifier
    if not path.exists():
        url = "https://raw.pixls.us/getfile.php/" + identifier + "/nice/" + quote(name)
        with urlopen(url, timeout=60) as response:
            data = response.read(40 * 1024 * 1024)
        if hashlib.sha256(data).hexdigest() != checksum:
            raise SystemExit(f"Download checksum mismatch for {identifier}")
        path.write_bytes(data)
    if hashlib.sha256(path.read_bytes()).hexdigest() != checksum:
        raise SystemExit(f"Cached checksum mismatch for {identifier}")
    print(f"Verified CC0 camera fixture {identifier}: {name}", flush=True)
