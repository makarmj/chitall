"""Derives binary test fixtures from the hand-written UTF-8 sample.

Usage: python -I tools/make_fixtures.py

Writes next to sample-utf8.fb2:
  sample-cp1251.fb2         same book, declared and encoded as windows-1251
  sample-stored.fb2.zip     the UTF-8 sample in a ZIP without compression
  sample-deflated.fb2.zip   the UTF-8 sample in a ZIP with DEFLATE
  no-fb2.zip                a ZIP with only a text file
"""

import pathlib
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "ChitallCore" / "Tests" / "ChitallCoreTests" / "Fixtures"


def write_zip(path: pathlib.Path, entries: dict[str, bytes], method: int) -> None:
    # Fixed timestamps keep the fixtures byte-for-byte reproducible.
    with zipfile.ZipFile(path, "w", compression=method) as archive:
        for name, data in entries.items():
            info = zipfile.ZipInfo(name, date_time=(2026, 10, 11, 12, 0, 0))
            info.compress_type = method
            archive.writestr(info, data)


def main() -> None:
    utf8 = (FIXTURES / "sample-utf8.fb2").read_bytes()
    text = utf8.decode("utf-8")

    cp1251 = text.replace('encoding="UTF-8"', 'encoding="windows-1251"', 1).encode("cp1251")
    (FIXTURES / "sample-cp1251.fb2").write_bytes(cp1251)

    write_zip(FIXTURES / "sample-stored.fb2.zip", {"sample.fb2": utf8}, zipfile.ZIP_STORED)
    write_zip(FIXTURES / "sample-deflated.fb2.zip", {"book/sample.fb2": utf8}, zipfile.ZIP_DEFLATED)
    write_zip(FIXTURES / "no-fb2.zip", {"readme.txt": "нет книги".encode("utf-8")}, zipfile.ZIP_STORED)

    for name in ["sample-cp1251.fb2", "sample-stored.fb2.zip", "sample-deflated.fb2.zip", "no-fb2.zip"]:
        print(name, (FIXTURES / name).stat().st_size, "bytes")


if __name__ == "__main__":
    main()
