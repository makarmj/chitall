"""Static checks of the Xcode project that can run without macOS.

Usage: python -I tools/check_project.py

Checks:
  * project.pbxproj parses as an OpenStep property list, every referenced object id exists,
    every object has an `isa`, synchronized folders / Info.plist / local package exist on disk;
  * Info.plist and PrivacyInfo.xcprivacy are valid XML property lists with the expected keys;
  * the shared scheme and workspace are well-formed and point at real targets;
  * asset catalog JSON is valid and the app icon is a 1024x1024 PNG;
  * bundled FB2 files are well-formed XML.
It does not replace building in Xcode.
"""

import json
import pathlib
import plistlib
import re
import struct
import sys
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parent.parent
PROJECT = ROOT / "Chitall.xcodeproj"
errors: list[str] = []


def fail(message: str) -> None:
    errors.append(message)


# ---------------------------------------------------------------- OpenStep plist parser

class Parser:
    TOKEN = re.compile(r'\s*(?://[^\n]*\n|/\*.*?\*/)', re.S)

    def __init__(self, text: str):
        self.text = text
        self.pos = 0

    def skip(self):
        while True:
            match = self.TOKEN.match(self.text, self.pos)
            if not match or match.end() == self.pos:
                break
            self.pos = match.end()
        while self.pos < len(self.text) and self.text[self.pos].isspace():
            self.pos += 1
            match = self.TOKEN.match(self.text, self.pos)
            if match and match.end() != self.pos:
                self.pos = match.end()

    def peek(self) -> str:
        self.skip()
        return self.text[self.pos] if self.pos < len(self.text) else ""

    def expect(self, char: str):
        if self.peek() != char:
            raise ValueError(f"expected {char!r} at {self.location()}, found {self.text[self.pos:self.pos + 20]!r}")
        self.pos += 1

    def location(self) -> str:
        line = self.text.count("\n", 0, self.pos) + 1
        return f"line {line}"

    def value(self):
        char = self.peek()
        if char == "{":
            return self.dictionary()
        if char == "(":
            return self.array()
        if char == '"':
            return self.quoted()
        return self.bare()

    def dictionary(self):
        self.expect("{")
        result = {}
        while self.peek() != "}":
            key = self.value()
            self.expect("=")
            if key in result:
                raise ValueError(f"duplicate key {key!r} at {self.location()}")
            result[key] = self.value()
            self.expect(";")
        self.expect("}")
        return result

    def array(self):
        self.expect("(")
        result = []
        while self.peek() != ")":
            result.append(self.value())
            if self.peek() == ",":
                self.pos += 1
        self.expect(")")
        return result

    def quoted(self):
        self.expect('"')
        out = []
        while self.text[self.pos] != '"':
            if self.text[self.pos] == "\\":
                self.pos += 1
            out.append(self.text[self.pos])
            self.pos += 1
        self.pos += 1
        return "".join(out)

    def bare(self):
        match = re.compile(r"[A-Za-z0-9_$+/:.\-<>]+").match(self.text, self.pos)
        if not match:
            raise ValueError(f"unexpected token at {self.location()}: {self.text[self.pos:self.pos + 20]!r}")
        self.pos = match.end()
        return match.group(0)


def check_pbxproj():
    path = PROJECT / "project.pbxproj"
    text = path.read_text(encoding="utf-8")
    if not text.startswith("// !$*UTF8*$!"):
        fail("pbxproj: missing UTF8 header")
    try:
        root = Parser(text).value()
    except ValueError as error:
        fail(f"pbxproj: parse error: {error}")
        return {}
    objects = root.get("objects", {})
    if root.get("objectVersion") != "77":
        fail("pbxproj: objectVersion is not 77 (buildable folders need Xcode 16+)")
    if root.get("rootObject") not in objects:
        fail("pbxproj: rootObject missing")

    id_pattern = re.compile(r"^[0-9A-F]{24}$")
    for object_id, body in objects.items():
        if not id_pattern.match(object_id):
            fail(f"pbxproj: bad object id {object_id}")
        if "isa" not in body:
            fail(f"pbxproj: object {object_id} has no isa")

    def walk(value):
        if isinstance(value, dict):
            for item in value.values():
                yield from walk(item)
        elif isinstance(value, list):
            for item in value:
                yield from walk(item)
        elif isinstance(value, str) and id_pattern.match(value):
            yield value

    for object_id, body in objects.items():
        for reference in walk(body):
            if reference not in objects:
                fail(f"pbxproj: {object_id} ({body.get('isa')}) references missing object {reference}")

    project = objects.get(root.get("rootObject"), {})
    for target_id in project.get("targets", []):
        target = objects[target_id]
        for key in ("buildConfigurationList", "productReference"):
            if key not in target:
                fail(f"pbxproj: target {target.get('name')} lacks {key}")
        for group_id in target.get("fileSystemSynchronizedGroups", []):
            folder = ROOT / objects[group_id]["path"]
            if not folder.is_dir():
                fail(f"pbxproj: synchronized folder {folder} does not exist")
        configurations = objects[target["buildConfigurationList"]]["buildConfigurations"]
        names = sorted(objects[c]["name"] for c in configurations)
        if names != ["Debug", "Release"]:
            fail(f"pbxproj: target {target.get('name')} configurations {names}")
        for configuration_id in configurations:
            settings = objects[configuration_id]["buildSettings"]
            plist = settings.get("INFOPLIST_FILE")
            if plist and not (ROOT / plist).is_file():
                fail(f"pbxproj: INFOPLIST_FILE {plist} missing")
    for reference_id in project.get("packageReferences", []):
        reference = objects[reference_id]
        package = ROOT / reference["relativePath"] / "Package.swift"
        if not package.is_file():
            fail(f"pbxproj: local package {package} missing")
    for object_id, body in objects.items():
        if body.get("isa") == "XCSwiftPackageProductDependency" and "package" not in body:
            fail(f"pbxproj: product dependency {object_id} has no package reference")
    return objects


def check_plists():
    info = plistlib.loads((ROOT / "Config" / "Info.plist").read_bytes())
    declared = {entry["UTTypeIdentifier"] for entry in info.get("UTImportedTypeDeclarations", [])}
    handled = {t for entry in info.get("CFBundleDocumentTypes", []) for t in entry.get("LSItemContentTypes", [])}
    if "com.fbreader.book.fb2" not in declared:
        fail("Info.plist: FB2 type is not declared")
    if not handled <= declared | {"public.zip-archive"}:
        fail("Info.plist: document types reference undeclared UTIs")
    privacy = plistlib.loads((ROOT / "Chitall" / "Resources" / "PrivacyInfo.xcprivacy").read_bytes())
    if privacy.get("NSPrivacyTracking") is not False:
        fail("PrivacyInfo: tracking must be false")


def check_scheme(objects):
    scheme = PROJECT / "xcshareddata" / "xcschemes" / "Chitall.xcscheme"
    tree = ET.parse(scheme)
    for reference in tree.iter("BuildableReference"):
        container = reference.get("ReferencedContainer")
        identifier = reference.get("BlueprintIdentifier")
        if container == "container:Chitall.xcodeproj" and identifier not in objects:
            fail(f"scheme: unknown target id {identifier}")
        if container == "container:ChitallCore" and not (ROOT / "ChitallCore" / "Tests" / identifier).is_dir():
            fail(f"scheme: package test target {identifier} not found")
    ET.parse(PROJECT / "project.xcworkspace" / "contents.xcworkspacedata")


def check_assets():
    assets = ROOT / "Chitall" / "Resources" / "Assets.xcassets"
    for contents in assets.rglob("Contents.json"):
        try:
            json.loads(contents.read_text(encoding="utf-8"))
        except json.JSONDecodeError as error:
            fail(f"{contents}: {error}")
    icon = assets / "AppIcon.appiconset" / "AppIcon.png"
    data = icon.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        fail("AppIcon.png is not a PNG")
    width, height = struct.unpack(">II", data[16:24])
    if (width, height) != (1024, 1024):
        fail(f"AppIcon.png is {width}x{height}")


def check_books():
    for book in list((ROOT / "Chitall").rglob("*.fb2")) + list((ROOT / "ChitallCore" / "Tests").rglob("*.fb2")):
        try:
            ET.parse(book)
        except ET.ParseError as error:
            fail(f"{book}: {error}")


def main() -> int:
    objects = check_pbxproj()
    check_plists()
    check_scheme(objects)
    check_assets()
    check_books()
    if errors:
        print("FAILED")
        for error in errors:
            print(" -", error)
        return 1
    print(f"OK: pbxproj ({len(objects)} objects), plists, scheme, workspace, assets, FB2 resources")
    return 0


if __name__ == "__main__":
    sys.exit(main())
