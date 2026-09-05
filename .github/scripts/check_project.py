#!/usr/bin/env python3
"""Structural checks on Ganzfeld.xcodeproj that do not need a Mac.

A merge that corrupts project.pbxproj, drops the shared scheme, or leaves a
source file outside every target fails the macOS jobs several minutes in with
an opaque message. This catches those cases on a Linux runner in seconds.
"""

from __future__ import annotations

import pathlib
import re
import sys
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[2]
PROJECT = ROOT / "Ganzfeld.xcodeproj"
PBXPROJ = PROJECT / "project.pbxproj"
SCHEMES = PROJECT / "xcshareddata" / "xcschemes"

failures: list[str] = []


def fail(message: str) -> None:
    failures.append(message)
    print(f"::error::{message}")


class OpenStepParser:
    """Just enough of the old-style plist grammar to read a project.pbxproj."""

    TOKEN = re.compile(r"[A-Za-z0-9_./$:+@~-]+")

    def __init__(self, text: str) -> None:
        self.text = text
        self.pos = 0

    def parse(self):
        value = self.value()
        self.skip()
        if self.pos != len(self.text):
            raise ValueError(f"trailing content at offset {self.pos}")
        return value

    def skip(self) -> None:
        while self.pos < len(self.text):
            char = self.text[self.pos]
            if char in " \t\r\n":
                self.pos += 1
            elif self.text.startswith("//", self.pos):
                end = self.text.find("\n", self.pos)
                self.pos = len(self.text) if end < 0 else end
            elif self.text.startswith("/*", self.pos):
                end = self.text.find("*/", self.pos)
                if end < 0:
                    raise ValueError("unterminated comment")
                self.pos = end + 2
            else:
                return

    def value(self):
        self.skip()
        char = self.text[self.pos]
        if char == "{":
            return self.mapping()
        if char == "(":
            return self.array()
        if char == '"':
            return self.quoted()
        return self.bare()

    def mapping(self) -> dict:
        self.pos += 1
        result = {}
        while True:
            self.skip()
            if self.text[self.pos] == "}":
                self.pos += 1
                return result
            key = self.value()
            self.skip()
            self.expect("=")
            result[key] = self.value()
            self.skip()
            self.expect(";")

    def array(self) -> list:
        self.pos += 1
        result = []
        while True:
            self.skip()
            if self.text[self.pos] == ")":
                self.pos += 1
                return result
            result.append(self.value())
            self.skip()
            if self.text[self.pos] == ",":
                self.pos += 1

    def quoted(self) -> str:
        self.pos += 1
        out = []
        while True:
            char = self.text[self.pos]
            if char == "\\":
                out.append(self.text[self.pos:self.pos + 2])
                self.pos += 2
            elif char == '"':
                self.pos += 1
                return "".join(out)
            else:
                out.append(char)
                self.pos += 1

    def bare(self) -> str:
        match = self.TOKEN.match(self.text, self.pos)
        if not match:
            context = self.text[max(0, self.pos - 40):self.pos + 40]
            raise ValueError(f"bad token at offset {self.pos}: ...{context}...")
        self.pos = match.end()
        return match.group(0)

    def expect(self, char: str) -> None:
        if self.text[self.pos] != char:
            context = self.text[max(0, self.pos - 60):self.pos + 20]
            raise ValueError(f"expected {char!r} at offset {self.pos}: ...{context}...")
        self.pos += 1


ID = re.compile(r"[0-9A-F]{24}")


def load_project() -> dict | None:
    if not PBXPROJ.is_file():
        fail(f"{PBXPROJ.relative_to(ROOT)} is missing")
        return None
    text = PBXPROJ.read_text(encoding="utf-8").replace("// !$*UTF8*$!", "", 1)
    try:
        return OpenStepParser(text).parse()
    except ValueError as error:
        fail(f"project.pbxproj does not parse: {error}")
        return None


def check_references(root: dict) -> None:
    objects = root["objects"]
    known = set(objects)

    def walk(node, path: str) -> None:
        if isinstance(node, dict):
            for key, value in node.items():
                walk(value, f"{path}.{key}")
        elif isinstance(node, list):
            for item in node:
                walk(item, f"{path}[]")
        elif isinstance(node, str) and ID.fullmatch(node) and node not in known:
            fail(f"dangling object reference {node} at {path}")

    walk(objects, "objects")
    if root.get("rootObject") not in known:
        fail("rootObject does not point at a real object")


def check_targets(root: dict) -> dict[str, dict]:
    objects = root["objects"]
    project = objects[root["rootObject"]]
    targets = {objects[t]["name"]: objects[t] for t in project["targets"]}

    if "Ganzfeld" not in targets:
        fail("the app target `Ganzfeld` is missing")
    if "GanzfeldTests" not in targets:
        fail("the unit-test target `GanzfeldTests` is missing — CI would run no tests")
        return targets

    tests = targets["GanzfeldTests"]
    if tests["productType"] != "com.apple.product-type.bundle.unit-test":
        fail(f"GanzfeldTests has product type {tests['productType']}, not a unit-test bundle")

    dependencies = {
        objects[objects[dep]["target"]]["name"] for dep in tests.get("dependencies", [])
    }
    if "Ganzfeld" not in dependencies:
        fail("GanzfeldTests does not depend on Ganzfeld, so the test host would not be built")

    for name, target in targets.items():
        settings = [
            objects[config]["buildSettings"]
            for config in objects[target["buildConfigurationList"]]["buildConfigurations"]
        ]
        for setting in settings:
            if setting.get("SDKROOT") != "xros":
                fail(f"{name} does not build against the visionOS SDK (SDKROOT={setting.get('SDKROOT')})")
                break

    for name, target in targets.items():
        groups = target.get("fileSystemSynchronizedGroups", [])
        if not groups:
            fail(f"{name} has no source group, so it would build nothing")
        for group in groups:
            path = ROOT / objects[group]["path"]
            if not path.is_dir():
                fail(f"{name} references the missing source directory {objects[group]['path']}")
            elif not any(path.glob("*.swift")):
                fail(f"{name}'s source directory {path.name} contains no Swift files")

    return targets


def check_scheme(root: dict, targets: dict[str, dict]) -> None:
    scheme = SCHEMES / "Ganzfeld.xcscheme"
    if not scheme.is_file():
        fail(
            "Ganzfeld.xcscheme is not shared — `xcodebuild -scheme Ganzfeld` "
            "cannot see a scheme that lives in xcuserdata"
        )
        return

    try:
        tree = ET.parse(scheme)
    except ET.ParseError as error:
        fail(f"Ganzfeld.xcscheme is not valid XML: {error}")
        return

    objects = root["objects"]
    identifiers = {
        blueprint: name
        for name, target in targets.items()
        for blueprint in [next(k for k, v in objects.items() if v is target)]
    }

    referenced = set()
    for reference in tree.iter("BuildableReference"):
        blueprint = reference.get("BlueprintIdentifier", "")
        name = reference.get("BlueprintName", "")
        if blueprint not in identifiers:
            fail(f"scheme references unknown target {name!r} ({blueprint})")
        elif identifiers[blueprint] != name:
            fail(f"scheme calls {blueprint} {name!r}, but the project calls it {identifiers[blueprint]!r}")
        else:
            referenced.add(name)

    testables = [
        reference.get("BlueprintName")
        for testable in tree.iter("TestableReference")
        for reference in testable.iter("BuildableReference")
    ]
    if "GanzfeldTests" not in testables:
        fail("the shared scheme's test action does not run GanzfeldTests")
    for name in targets:
        if name not in referenced:
            fail(f"target {name} is not in the shared scheme, so CI would never build it")


def main() -> int:
    root = load_project()
    if root is not None:
        check_references(root)
        targets = check_targets(root)
        check_scheme(root, targets)

    if failures:
        print(f"\n{len(failures)} project problem(s) found.")
        return 1
    print("Project structure OK: app and test targets, shared scheme, visionOS SDK.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
