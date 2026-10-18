"""Regenerate src/datatypes/w3c_cases.mbt from the W3C XML Schema test suite.

The full NIST datatypes contribution is 3953 schemas and 19217 instances.
Downloading all of it is pointless for a datatype validator and committing it
would bloat the repository, so this takes one representative test group per
(kind, type, facet) combination, plus one valid and one invalid instance where
the suite provides both.

Nothing derived from the suite is committed except the generated MoonBit file,
which embeds schema and instance text. See NOTICE: those literals stay under the
W3C Document Licence and are not covered by Apache-2.0.

Usage:
    python scripts/gen_w3c.py            # full 510 combinations
    LIMIT_GROUPS=20 python scripts/gen_w3c.py

Authentication: reads GH_TOKEN, or falls back to `gh auth token`. The API is
used instead of git because the suite is fetched file by file.
"""
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "src", "datatypes", "w3c_cases.mbt")
CACHE = os.path.join(ROOT, "testdata", "w3c-cache")
TESTSET_PATH = os.path.join(CACHE, "NISTXMLSchemaDatatypes.testSet")

OWNER_REPO = "w3c/xsdtests"
TESTSET_REMOTE = "nistMeta/NISTXMLSchemaDatatypes.testSet"
LIMIT_GROUPS = int(os.environ.get("LIMIT_GROUPS", "0")) or 10**9


def token():
    t = os.environ.get("GH_TOKEN", "").strip()
    if t:
        return t
    try:
        return subprocess.run(
            ["gh", "auth", "token"], capture_output=True, text=True
        ).stdout.strip()
    except Exception:
        return ""


TOKEN = token()
if not TOKEN:
    print("no token: set GH_TOKEN or log in with gh")
    sys.exit(2)

os.makedirs(CACHE, exist_ok=True)


def fetch(path):
    """Download a repository file through the contents API, with caching."""
    local = os.path.join(CACHE, path.replace("/", "_"))
    if os.path.exists(local):
        with open(local, "rb") as f:
            return f.read()
    url = "https://api.github.com/repos/%s/contents/%s" % (OWNER_REPO, path)
    for attempt in range(5):
        req = urllib.request.Request(url)
        req.add_header("Authorization", "Bearer " + TOKEN)
        req.add_header("Accept", "application/vnd.github.raw")
        try:
            with urllib.request.urlopen(req, timeout=40) as resp:
                data = resp.read()
            with open(local, "wb") as f:
                f.write(data)
            return data
        except urllib.error.HTTPError as e:
            if e.code in (403, 429, 500, 502, 503, 504) and attempt < 4:
                time.sleep(3 + attempt * 3)
                continue
            raise
        except Exception:
            if attempt < 4:
                time.sleep(3 + attempt * 3)
                continue
            raise


def normalize(group_name):
    parts = group_name.split("-")
    while parts and parts[-1].isdigit():
        parts.pop()
    return "-".join(parts)


def case_tag(name):
    """Group tag of a test name: the part before the trailing serial numbers.

    `NISTSchema-SV-IV-atomic-QName-length-1` and
    `NISTXML-SV-IV-atomic-QName-length-2-1` should share the same tag. A few
    NIST groups mix schemas and instances from different serials (the QName
    length-1 group ships length-2 instances), so the tag is used to drop those
    rather than report them as validator failures.
    """
    m = re.match(r"NIST(?:Schema|XML)-SV-IV-(.+?)-(\d+)(?:-\d+)?$", name)
    if not m:
        return None
    return (m.group(1), m.group(2))


def file_serial(path):
    """Serial number embedded in a suite file name, or None.

    `...-length-2.xsd` and `...-length-2-3.xml` both belong to serial 2. A few
    groups pair a schema from one serial with instances from another; those are
    dropped so the number reported here measures this validator, not the data.
    """
    base = path.split("/")[-1]
    m = re.search(r"-(\d+)\.xsd$", base)
    if m:
        return m.group(1)
    m = re.search(r"-(\d+)-\d+\.xml$", base)
    if m:
        return m.group(1)
    return None


def parse_testset(text):
    """Yields (group_name, schema_href, [(instance_href, validity)]).

    The validity sits on `<expected validity="..."/>` inside the enclosing
    `<instanceTest>`, not on the `<instanceDocument>` element itself.
    """
    for m in re.finditer(r'<testGroup name="([^"]+)">(.*?)</testGroup>', text, re.S):
        name, body = m.group(1), m.group(2)
        schema_el = re.search(r'<schemaTest name="([^"]+)">', body)
        schema = re.search(r'<schemaDocument xlink:href="([^"]+)"', body)
        if not schema or not schema_el:
            continue
        want = case_tag(schema_el.group(1))
        instances = []
        for im in re.finditer(r'<instanceTest name="([^"]*)">(.*?)</instanceTest>', body, re.S):
            block = im.group(2)
            got = case_tag(im.group(1))
            if want is None or got != want:
                continue
            href = re.search(r'<instanceDocument xlink:href="([^"]+)"', block)
            validity = re.search(r'<expected validity="(\w+)"', block)
            if not href:
                continue
            instances.append(
                (href.group(1), validity is not None and validity.group(1) == "valid")
            )
        yield name, schema.group(1), instances

def repo_path(href):
    return href.replace("../", "")


def root_content(xml_bytes):
    """Returns (element name, character content) of the element under test.

    NIST wrappers the value in an `out` element (W3C bug 9922, 2010), so the
    value under test is the first child of the root rather than the root itself.
    Older instances put it directly in the root; both shapes are handled.
    """
    try:
        import xml.etree.ElementTree as ET

        root = ET.fromstring(xml_bytes)
        local = lambda tag: tag.split("}")[-1] if "}" in tag else tag.split(":")[-1]
        for child in list(root):
            if isinstance(child.tag, str):
                return local(child.tag), (child.text or "")
        return local(root.tag), (root.text or "")
    except Exception:
        pass
    text = xml_bytes.decode("utf-8", "replace")
    text = re.sub(r"<\?.*?\?>", "", text, flags=re.S)
    text = re.sub(r"<!--.*?-->", "", text, flags=re.S)
    m = re.search(r"<([A-Za-z_][\w.\-:]*)(?:\s[^>]*)?>(.*)</\1\s*>", text, re.S)
    if not m:
        return None, None
    body = re.sub(r"<[^>]+>", "", m.group(2))
    body = (
        body.replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", '"')
        .replace("&apos;", "'")
        .replace("&amp;", "&")
    )
    return m.group(1).split(":")[-1], body.strip("\n").strip("\r")


def esc(s):
    return (
        s.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\r", "")
        .replace("\t", "\\t")
    )


def main():
    if os.path.exists(TESTSET_PATH):
        with open(TESTSET_PATH, encoding="utf-8") as f:
            text = f.read()
    else:
        text = fetch(TESTSET_REMOTE).decode("utf-8", "replace")
        with open(TESTSET_PATH, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)

    seen = {}
    for name, href, instances in parse_testset(text):
        key = normalize(name)
        if key not in seen:
            seen[key] = (name, href, instances)
    keys = sorted(seen)
    print("unique combinations:", len(keys))
    chosen = keys[:LIMIT_GROUPS]

    wanted = []
    plan = []
    for key in chosen:
        name, href, instances = seen[key]
        valid = [i for i in instances if i[1]]
        invalid = [i for i in instances if not i[1]]
        picks = (valid[:1] + invalid[:1]) if valid and invalid else instances[:2]
        plan.append((key, href, picks))
        wanted.append(repo_path(href))
        for inst_href, _ in picks:
            wanted.append(repo_path(inst_href))
    unique = sorted(set(wanted))
    print("files to fetch:", len(unique))
    done = 0
    with ThreadPoolExecutor(max_workers=6) as ex:
        futures = {ex.submit(fetch, p): p for p in unique}
        for fut in futures:
            try:
                fut.result()
                done += 1
                if done % 200 == 0:
                    print("  fetched", done, "/", len(unique))
            except Exception as e:
                print("  fetch failed:", futures[fut], str(e)[:80])

    cases = []
    failures = []
    for key, href, picks in plan:
        try:
            schema_bytes = fetch(repo_path(href))
        except Exception as e:
            failures.append((key, "schema", str(e)[:80]))
            continue
        want_serial = file_serial(href)
        for inst_href, expected in picks:
            got_serial = file_serial(inst_href)
            if want_serial is not None and got_serial is not None and want_serial != got_serial:
                failures.append((key, "serial-mismatch", inst_href.split("/")[-1]))
                continue
            try:
                inst_bytes = fetch(repo_path(inst_href))
            except Exception as e:
                failures.append((key, "instance", str(e)[:80]))
                continue
            element, value = root_content(inst_bytes)
            if element is None or value is None:
                failures.append((key, "parse", "no root element"))
                continue
            cases.append(
                (schema_bytes.decode("utf-8", "replace"), element, value, expected, key)
            )

    print("cases:", len(cases), "failures:", len(failures))
    if failures[:5]:
        print("sample failures:", failures[:5])

    lines = [
        "// Generated by scripts/gen_w3c.py from the W3C XML Schema test suite",
        "// (NIST datatypes contribution). Do not edit by hand.",
        "//",
        "// The schema and instance text below is W3C copyrighted material, made",
        "// available under the W3C Document Notice and License. It is NOT covered",
        "// by this project's Apache-2.0 licence. See NOTICE.",
        "//",
        "// Each case is (schema document, element name, element content, expected valid).",
        "",
        "///|",
        "pub let w3c_cases : Array[(String, String, String, Bool)] = [",
    ]
    for schema, element, value, expected, _key in cases:
        lines.append(
            '  ("%s", "%s", "%s", %s),'
            % (esc(schema), esc(element), esc(value), "true" if expected else "false")
        )
    lines.append("]")
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    print("written", OUT, os.path.getsize(OUT), "bytes")


if __name__ == "__main__":
    main()
