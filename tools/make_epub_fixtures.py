"""Builds the EPUB test books and raw DEFLATE streams for ChitallCore tests.

Usage: python -I tools/make_epub_fixtures.py

All text is written for the tests (no third-party books). Writes into
ChitallCore/Tests/ChitallCoreTests/Fixtures:
  sample-epub3.epub          EPUB 3: nav, cover-image, refines, noteref + footnote aside, endnotes
  sample-epub2.epub          EPUB 2: NCX, <meta name="cover">, XHTML 1.1 with &nbsp; and friends,
                             Calibre-style notes with backlinks, a file name with a space
  sample-epub3-stored.epub   the EPUB 3 sample repacked without compression (same text)
  sample-epub3-edited.epub   the EPUB 3 sample with a paragraph inserted at the start of ch. 1
  drm.epub                   content encrypted (encryption.xml, AES): must be refused
  obfuscated-fonts.epub      only fonts obfuscated (not DRM): must import
  broken-xhtml.epub          a chapter that is not well-formed XML
  no-container.epub          mimetype but no META-INF/container.xml
  inflate/*.deflate          sample-utf8.fb2 as stored, fixed-Huffman and dynamic-Huffman DEFLATE
"""

import pathlib
import random
import struct
import zipfile
import zlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "ChitallCore" / "Tests" / "ChitallCoreTests" / "Fixtures"
STAMP = (2026, 10, 21, 12, 0, 0)

CONTAINER = """<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="{opf}" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
"""


def png(width: int, height: int, rgb: tuple[int, int, int]) -> bytes:
    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    rows = b"".join(b"\x00" + bytes(rgb) * width for _ in range(height))
    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b"")


def xhtml(title: str, body: str, epub3: bool = True) -> str:
    if epub3:
        head = ('<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE html>\n'
                '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="ru" xml:lang="ru">\n')
    else:
        head = ('<?xml version="1.0" encoding="utf-8"?>\n'
                '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">\n'
                '<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="ru">\n')
    return (head + f"<head>\n<title>{title}</title>\n"
            '<link rel="stylesheet" type="text/css" href="../style.css"/>\n</head>\n'
            f"<body{body}</body>\n</html>\n")


EPUB3_OPF = """<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid" xml:lang="ru">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">urn:uuid:5b1f0c8e-0000-4000-8000-chitall00003</dc:identifier>
    <dc:identifier>urn:isbn:9780000000002</dc:identifier>
    <dc:title id="t2">Пробная книга для Chitall</dc:title>
    <meta refines="#t2" property="title-type">subtitle</meta>
    <dc:title id="t1">Соляная переправа</dc:title>
    <meta refines="#t1" property="title-type">main</meta>
    <dc:creator id="a1">Анна Тестова</dc:creator>
    <meta refines="#a1" property="role" scheme="marc:relators">aut</meta>
    <dc:creator id="a2">Пётр Пробный</dc:creator>
    <meta refines="#a2" property="role" scheme="marc:relators">trl</meta>
    <dc:language>ru</dc:language>
    <dc:publisher>Chitall</dc:publisher>
    <dc:date>2026-10-21</dc:date>
    <dc:subject>История</dc:subject>
    <dc:description>&lt;p&gt;Короткая книга для проверки EPUB.&lt;/p&gt;&lt;p&gt;Текст написан для тестов &amp;amp; только для них.&lt;/p&gt;</dc:description>
    <meta property="belongs-to-collection" id="c1">Пробные книги</meta>
    <meta refines="#c1" property="group-position">2</meta>
    <meta property="dcterms:modified">2026-10-21T00:00:00Z</meta>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="css" href="style.css" media-type="text/css"/>
    <item id="cover" href="Images/cover.png" media-type="image/png" properties="cover-image"/>
    <item id="map" href="Images/map.png" media-type="image/png"/>
    <item id="cover-page" href="Text/cover.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch1" href="Text/ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch2" href="Text/ch2.xhtml" media-type="application/xhtml+xml"/>
    <item id="notes" href="Text/notes.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="cover-page" linear="no"/>
    <itemref idref="ch1"/>
    <itemref idref="ch2"/>
    <itemref idref="notes"/>
  </spine>
</package>
"""

EPUB3_NAV = xhtml("Содержание", """>
<nav epub:type="toc" id="toc">
  <h1>Содержание</h1>
  <ol>
    <li><a href="Text/ch1.xhtml">Глава первая. Переправа</a></li>
    <li><a href="Text/ch2.xhtml">Глава вторая. Торг</a>
      <ol>
        <li><a href="Text/ch2.xhtml#market">На площади</a></li>
        <li><a href="Text/ch2.xhtml#evening">Вечер</a></li>
      </ol>
    </li>
    <li><a href="Text/notes.xhtml">Примечания</a></li>
  </ol>
</nav>
<nav epub:type="landmarks" hidden="">
  <ol><li><a epub:type="bodymatter" href="Text/ch1.xhtml">Начало</a></li></ol>
</nav>
""").replace('href="../style.css"', 'href="style.css"')

EPUB3_COVER = xhtml("Обложка", """>
<section epub:type="cover"><img src="../Images/cover.png" alt="Обложка"/></section>
""")

EPUB3_CH1_PARAGRAPHS = """<p>Паром отошёл от берега, когда <em>солнце</em> уже стояло над <strong>соляными</strong> амбарами.<a epub:type="noteref" href="#fn1" id="r1">1</a></p>
<p>Лодочник Ефим молчал и смотрел на&#160;воду.</p>"""

EPUB3_CH1 = xhtml("Глава первая", f""">
<section epub:type="chapter" id="ch1">
<h1>Глава первая<br/>
  Переправа</h1>
{EPUB3_CH1_PARAGRAPHS}
<blockquote class="epigraph"><p>Кто везёт соль, тот везёт серебро.</p></blockquote>
<div class="poem"><p>Ой, река моя широкая,<br/>
  переправа далёкая.</p></div>
<p>Дальше — в <a href="ch2.xhtml#market">торговый ряд</a>.</p>
<aside epub:type="footnote" id="fn1"><p>Амбары стояли у самой пристани.</p></aside>
</section>
""")

EPUB3_CH2 = xhtml("Глава вторая", """>
<h2>Глава вторая. Торг</h2>
<p>Утром обоз вошёл в город.</p>
<section id="market"><h3>На площади</h3>
<p>Купцы спорили о цене<a epub:type="noteref" href="notes.xhtml#en1" id="r2">2</a>, а писарь записывал каждое слово.</p>
<figure><img src="../Images/map.png" alt="Карта"/><figcaption>Карта торговой площади</figcaption></figure>
<p>&#160;</p>
</section>
<section id="evening"><h3>Вечер</h3>
<p>Вечером Ефим пересчитал выручку.</p>
Свободный текст без абзаца.
<p>Конец главы.</p>
</section>
""")

EPUB3_NOTES = xhtml("Примечания", """ epub:type="backmatter">
<section epub:type="endnotes" id="notes">
<h2>Примечания</h2>
<ol>
<li epub:type="endnote" id="en1"><p>Цена соли менялась каждую неделю. <a href="ch2.xhtml#r2" epub:type="backlink">↩</a></p></li>
</ol>
</section>
""")

EPUB2_OPF = """<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="BookId">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
    <dc:title>Зимний обоз</dc:title>
    <dc:creator opf:role="aut" opf:file-as="Тестова, Анна">Анна Тестова</dc:creator>
    <dc:creator opf:role="ill">Иван Рисующий</dc:creator>
    <dc:language>ru</dc:language>
    <dc:identifier id="BookId" opf:scheme="ISBN">9780000000019</dc:identifier>
    <dc:description>Вторая пробная книга.</dc:description>
    <meta name="cover" content="cover-img"/>
    <meta name="calibre:series" content="Пробные книги"/>
    <meta name="calibre:series_index" content="3.0"/>
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="part1" href="Text/part%201.html" media-type="application/xhtml+xml"/>
    <item id="notes" href="Text/notes.html" media-type="application/xhtml+xml"/>
    <item id="cover-img" href="Images/winter.png" media-type="image/png"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="part1"/>
    <itemref idref="notes"/>
  </spine>
  <guide><reference type="text" title="Начало" href="Text/part%201.html"/></guide>
</package>
"""

EPUB2_NCX = """<?xml version="1.0" encoding="utf-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="9780000000019"/></head>
  <docTitle><text>Зимний обоз</text></docTitle>
  <navMap>
    <navPoint id="np1" playOrder="1">
      <navLabel><text>Часть первая</text></navLabel>
      <content src="Text/part%201.html"/>
      <navPoint id="np2" playOrder="2">
        <navLabel><text>Обоз в пути</text></navLabel>
        <content src="Text/part%201.html#road"/>
      </navPoint>
    </navPoint>
    <navPoint id="np3" playOrder="3">
      <navLabel><text>Примечания</text></navLabel>
      <content src="Text/notes.html"/>
    </navPoint>
  </navMap>
</ncx>
"""

EPUB2_PART1 = xhtml("Часть первая", """>
<div class="chapter">
<h1 class="title">Часть первая</h1>
<div class="p">Мороз стоял такой, что&nbsp;полозья пели.</div>
<p>&laquo;Доедем ли?&raquo; &mdash; спросил мальчик.<sup><a id="r1" href="notes.html#n1">[1]</a></sup></p>
<p class="empty">&nbsp;</p>
<h2 id="road">Обоз в пути</h2>
<p><span style="font-style: italic">Дорога шла лесом</span>, и <b>волки</b> выли&hellip;</p>
Текст прямо в разделе.
<p>Ночевали в&nbsp;деревне <a href="http://example.com/">у старосты</a>.<a class="footnote-link" href="notes.html#n2" id="r2">2</a></p>
</div>
""", epub3=False)

EPUB2_NOTES = xhtml("Примечания", """>
<h1>Примечания</h1>
<p id="n1"><a href="part%201.html#r1">[1]</a> Обоз шёл&nbsp;три дня.</p>
<p><a id="n2" href="part%201.html#r2">2</a> Староста брал за ночлег соль.</p>
""", epub3=False)

ENCRYPTION = """<?xml version="1.0" encoding="UTF-8"?>
<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
  <enc:EncryptedData>
    <enc:EncryptionMethod Algorithm="{algorithm}"/>
    <enc:CipherData><enc:CipherReference URI="{uri}"/></enc:CipherData>
  </enc:EncryptedData>
</encryption>
"""


def write_epub(path: pathlib.Path, entries: dict[str, bytes], method: int = zipfile.ZIP_DEFLATED) -> None:
    # Fixed timestamps keep the fixtures byte-for-byte reproducible; `mimetype` comes first, stored.
    with zipfile.ZipFile(path, "w") as archive:
        info = zipfile.ZipInfo("mimetype", date_time=STAMP)
        info.compress_type = zipfile.ZIP_STORED
        archive.writestr(info, b"application/epub+zip")
        for name, data in entries.items():
            info = zipfile.ZipInfo(name, date_time=STAMP)
            info.compress_type = method
            archive.writestr(info, data)


def epub3_entries(ch1: str = EPUB3_CH1) -> dict[str, bytes]:
    return {
        "META-INF/container.xml": CONTAINER.format(opf="OEBPS/content.opf").encode(),
        "OEBPS/content.opf": EPUB3_OPF.encode(),
        "OEBPS/nav.xhtml": EPUB3_NAV.encode(),
        "OEBPS/style.css": b"p { text-indent: 1.5em; }\n",
        "OEBPS/Images/cover.png": png(4, 6, (180, 140, 90)),
        "OEBPS/Images/map.png": png(6, 4, (90, 120, 160)),
        "OEBPS/Text/cover.xhtml": EPUB3_COVER.encode(),
        "OEBPS/Text/ch1.xhtml": ch1.encode(),
        "OEBPS/Text/ch2.xhtml": EPUB3_CH2.encode(),
        "OEBPS/Text/notes.xhtml": EPUB3_NOTES.encode(),
    }


def main() -> None:
    write_epub(FIXTURES / "sample-epub3.epub", epub3_entries())
    write_epub(FIXTURES / "sample-epub3-stored.epub", epub3_entries(), zipfile.ZIP_STORED)
    edited = EPUB3_CH1.replace(EPUB3_CH1_PARAGRAPHS, "<p>Новый первый абзац, дописанный при правке.</p>\n" + EPUB3_CH1_PARAGRAPHS)
    write_epub(FIXTURES / "sample-epub3-edited.epub", epub3_entries(edited))

    write_epub(FIXTURES / "sample-epub2.epub", {
        "META-INF/container.xml": CONTAINER.format(opf="content.opf").encode(),
        "content.opf": EPUB2_OPF.encode(),
        "toc.ncx": EPUB2_NCX.encode(),
        "style.css": b"div.p { text-indent: 1em; }\n",
        "Images/winter.png": png(4, 6, (220, 230, 240)),
        "Text/part 1.html": EPUB2_PART1.encode(),
        "Text/notes.html": EPUB2_NOTES.encode(),
    })

    noise = random.Random(7)
    drm = epub3_entries()
    drm["OEBPS/Text/ch1.xhtml"] = bytes(noise.randrange(256) for _ in range(512))
    drm["META-INF/encryption.xml"] = ENCRYPTION.format(
        algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc", uri="OEBPS/Text/ch1.xhtml").encode()
    write_epub(FIXTURES / "drm.epub", drm)

    fonts = epub3_entries()
    fonts["OEBPS/Fonts/serif.otf"] = bytes(noise.randrange(256) for _ in range(256))
    fonts["META-INF/encryption.xml"] = ENCRYPTION.format(
        algorithm="http://www.idpf.org/2008/embedding", uri="OEBPS/Fonts/serif.otf").encode()
    write_epub(FIXTURES / "obfuscated-fonts.epub", fonts)

    broken = epub3_entries()
    broken["OEBPS/Text/ch2.xhtml"] = EPUB3_CH2.replace("<p>Конец главы.</p>", "<p>Конец главы.").encode()
    write_epub(FIXTURES / "broken-xhtml.epub", broken)

    no_container = epub3_entries()
    del no_container["META-INF/container.xml"]
    write_epub(FIXTURES / "no-container.epub", no_container)

    plain = (FIXTURES / "sample-utf8.fb2").read_bytes()
    inflate = FIXTURES / "inflate"
    inflate.mkdir(exist_ok=True)
    for name, level, strategy in [("stored", 0, zlib.Z_DEFAULT_STRATEGY), ("fixed", 9, zlib.Z_FIXED), ("dynamic", 9, zlib.Z_DEFAULT_STRATEGY)]:
        compressor = zlib.compressobj(level, zlib.DEFLATED, -15, 9, strategy)
        (inflate / f"{name}.deflate").write_bytes(compressor.compress(plain) + compressor.flush())

    for path in sorted(FIXTURES.glob("*.epub")) + sorted(inflate.glob("*.deflate")):
        print(path.relative_to(FIXTURES), path.stat().st_size, "bytes")


if __name__ == "__main__":
    main()
