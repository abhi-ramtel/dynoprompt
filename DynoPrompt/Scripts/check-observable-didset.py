#!/usr/bin/env python3
"""Fail if an @Observable class assigns a property inside its own didSet.

@Observable rewrites stored properties into computed accessors, which removes
the compiler's guarantee that assigning within didSet does not re-enter. The
assignment goes back through the setter and recurses until the stack dies.
This crashed DynoPrompt on opening Settings; clamp in a computed setter with a
private backing store instead.
"""
import re
import sys
from pathlib import Path

roots = [Path("DynoPrompt/DynoPrompt"), Path("DynoPrompt/DynoPromptCore"),
         Path("DynoPrompt/DynoPromptiOS"), Path("DynoPrompt/WhisperService")]
problems = []

for root in roots:
    if not root.exists():
        continue
    for path in root.rglob("*.swift"):
        text = path.read_text(encoding="utf-8", errors="replace")
        if "@Observable" not in text:
            continue
        for match in re.finditer(r"var\s+(\w+)\s*:[^{\n]+\{\s*\n\s*didSet\s*\{(.*?)\n\s{4}\}",
                                 text, re.S):
            name, body = match.group(1), match.group(2)
            if re.search(rf"(?<![\w.]){re.escape(name)}\s*=(?!=)", body):
                line = text[:match.start()].count("\n") + 1
                problems.append(f"{path}:{line}: '{name}' assigns itself inside its own didSet")

if problems:
    print("Recursive didSet in an @Observable type:", file=sys.stderr)
    for problem in problems:
        print("  " + problem, file=sys.stderr)
    sys.exit(1)

print("No self-assigning didSet in @Observable types.")
