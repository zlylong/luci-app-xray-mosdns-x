#!/usr/bin/env python3
"""What the package build's JS minifier (jsmin) gets wrong, in the pages.

jsmin takes a / for the start of a regular expression only after one of
( , = : [ ! & | ? + - ~ * / { } ; and for a division everywhere else, a
keyword like `return` included. A regex there is then read as code: a quote
in it starts a "string", a // further on becomes a "comment", and the rest
of the line is cut away. The source still parses; the minified page does
not, and LuCI shows "missing ) after argument list".

usage: tests/jslint.py [<repo>]
"""
import os
import re
import sys

repo = sys.argv[1] if len(sys.argv) > 1 else "."
# a keyword, then (after blanks) a / that does not start a comment
AFTER_KEYWORD = re.compile(r"\b(return|typeof|case|throw|delete|void|in|of|instanceof|new|else|do|yield|await)\s*/(?![/*])")

failed = []
for root, _, files in os.walk(os.path.join(repo, "htdocs")):
    for name in sorted(files):
        if not name.endswith(".js"):
            continue
        path = os.path.join(root, name)
        in_block = False
        for no, line in enumerate(open(path, encoding="utf-8"), 1):
            text = line
            # block comments are dropped by the minifier as well
            if in_block:
                if "*/" not in text:
                    continue
                text = text.split("*/", 1)[1]
                in_block = False
            while "/*" in text:
                head, _, rest = text.partition("/*")
                if "*/" in rest:
                    text = head + rest.split("*/", 1)[1]
                else:
                    text, in_block = head, True
            if text.lstrip().startswith("//"):
                continue
            if AFTER_KEYWORD.search(text):
                failed.append(f"{os.path.relpath(path, repo)}:{no}: a regex right after a keyword "
                              f"(jsmin reads it as a division; put it after ( or =): {line.strip()[:100]}")

if failed:
    print("\n".join(failed))
    sys.exit(1)
print("jslint: no regex after a keyword")
