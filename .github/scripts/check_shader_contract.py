#!/usr/bin/env python3
"""Check the hand-maintained contract between Shaders.metal and the Swift code.

Nothing in the build enforces these: the uniform buffer is memcpy'd into the
fragment shader, and the both-eyes sentinel is duplicated on both sides. A
mismatch produces wrong colours or a wrongly treated eye rather than a compile
error, so it is checked here instead.
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
METAL = ROOT / "Ganzfeld" / "Shaders.metal"
APP_MODEL = ROOT / "Ganzfeld" / "AppModel.swift"
RENDERER = ROOT / "Ganzfeld" / "Renderer.swift"

# Metal scalar/vector types and the Swift types that lay out identically.
TYPE_MAP = {
    "float4": "SIMD4<Float>",
    "float3": "SIMD3<Float>",
    "float2": "SIMD2<Float>",
    "float": "Float",
    "uint": "UInt32",
    "int": "Int32",
}

failures: list[str] = []


def fail(message: str) -> None:
    failures.append(message)
    print(f"::error::{message}")


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    return re.sub(r"//[^\n]*", "", text)


def read(path: pathlib.Path) -> str:
    if not path.is_file():
        fail(f"expected {path.relative_to(ROOT)} to exist")
        return ""
    return path.read_text(encoding="utf-8")


def metal_struct(text: str, name: str) -> list[tuple[str, str]] | None:
    match = re.search(rf"struct\s+{name}\s*\{{(.*?)\}}\s*;", strip_comments(text), re.DOTALL)
    if not match:
        fail(f"could not find `struct {name}` in Shaders.metal")
        return None
    fields = []
    for line in match.group(1).split(";"):
        line = line.strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) != 2:
            fail(f"unparsed field in Metal `struct {name}`: {line!r}")
            return None
        fields.append((parts[0], parts[1]))
    return fields


def swift_struct(text: str, name: str) -> list[tuple[str, str]] | None:
    match = re.search(rf"struct\s+{name}\s*\{{(.*?)\n\}}", strip_comments(text), re.DOTALL)
    if not match:
        fail(f"could not find `struct {name}` in Renderer.swift")
        return None
    fields = []
    for line in match.group(1).splitlines():
        line = line.strip()
        if not line.startswith("var "):
            continue
        member = re.match(r"var\s+(\w+)\s*:\s*([^=]+?)\s*(?:=.*)?$", line)
        if not member:
            fail(f"unparsed field in Swift `struct {name}`: {line!r}")
            return None
        fields.append((member.group(2), member.group(1)))
    return fields


def check_uniform_layout() -> None:
    metal = metal_struct(read(METAL), "Uniforms")
    swift = swift_struct(read(RENDERER), "ShaderUniforms")
    if metal is None or swift is None:
        return

    if len(metal) != len(swift):
        fail(
            f"Uniforms has {len(metal)} fields in Metal but ShaderUniforms has "
            f"{len(swift)} in Swift — the fragment shader would read past the "
            "end of the buffer or misread it"
        )
        return

    for index, ((mtype, mname), (stype, sname)) in enumerate(zip(metal, swift)):
        if mname != sname:
            fail(f"field {index}: Metal calls it `{mname}`, Swift calls it `{sname}`")
        expected = TYPE_MAP.get(mtype)
        if expected is None:
            fail(f"field {index} `{mname}`: unknown Metal type `{mtype}`; teach this script about it")
        elif expected != stype:
            fail(
                f"field {index} `{mname}`: Metal `{mtype}` needs Swift `{expected}`, "
                f"found `{stype}`"
            )
    if not failures:
        print(f"uniform layout OK ({len(metal)} fields)")


def check_both_eyes_sentinel() -> None:
    metal_text = strip_comments(read(METAL))
    swift_text = strip_comments(read(APP_MODEL))

    metal_match = re.search(r"constant\s+uint\s+kBothEyes\s*=\s*(\d+)\s*;", metal_text)
    swift_match = re.search(r"bothEyesTarget\s*:\s*UInt32\s*=\s*(\d+)", swift_text)

    if not metal_match:
        fail("could not find `constant uint kBothEyes` in Shaders.metal")
    if not swift_match:
        fail("could not find `bothEyesTarget: UInt32` in AppModel.swift")
    if metal_match and swift_match:
        if metal_match.group(1) != swift_match.group(1):
            fail(
                f"both-eyes sentinel disagrees: Metal says {metal_match.group(1)}, "
                f"Swift says {swift_match.group(1)}"
            )
        else:
            print(f"both-eyes sentinel OK (= {metal_match.group(1)})")


def check_entry_points() -> None:
    metal_text = strip_comments(read(METAL))
    renderer_text = strip_comments(read(RENDERER))

    referenced = set(re.findall(r'makeFunction\(name:\s*"(\w+)"\)', renderer_text))
    if not referenced:
        fail("Renderer.swift references no shader functions at all")
        return
    for name in sorted(referenced):
        if not re.search(rf"\b(vertex|fragment|kernel)\b[^\n]*\b{name}\s*\(", metal_text):
            fail(f"Renderer.swift asks for shader function `{name}`, which Shaders.metal does not define")
        else:
            print(f"entry point OK ({name})")


def main() -> int:
    check_uniform_layout()
    check_both_eyes_sentinel()
    check_entry_points()
    if failures:
        print(f"\n{len(failures)} contract problem(s) found.")
        return 1
    print("\nShader contract intact.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
