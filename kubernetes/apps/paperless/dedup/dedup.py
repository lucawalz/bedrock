import base64
import datetime
import json
import os
import re
import textwrap
import urllib.error
import urllib.request

import yaml
from django.db.models import Count, Q
from documents.models import Correspondent
from rapidfuzz import fuzz

KNOWN_PATH = "/etc/paperless-taxonomy/taxonomy.yaml"
API = "https://api.github.com/repos/lucawalz/bedrock-secrets"
TAXONOMY_FILE = "clusters/home/apps/paperless-taxonomy.yaml"
TAXONOMY_KEY = "taxonomy.yaml"
BRANCH_PREFIX = "paperless/dedup-"
TITLE = "feat(paperless): merge duplicate correspondents proposed by the weekly job"
TIMEOUT_SECONDS = 30
PULLS_PAGE = 100
LEGAL_SUFFIXES = {"gmbh", "ag", "kg", "mbh", "se", "ev", "ltd", "inc"}
UNCLEAR_RATIO = 85
DUMP_WIDTH = 4096
PROPOSED = re.compile(r"<!-- paperless-dedup: (.*?) -->")
BLOCK = re.compile(rf"^ *{re.escape(TAXONOMY_KEY)}: \|\n( +)", re.MULTILINE)


class IndentedDumper(yaml.SafeDumper):
    def increase_indent(self, flow=False, indentless=False):
        return super().increase_indent(flow, False)


def dump(data):
    return yaml.dump(data, Dumper=IndentedDumper, allow_unicode=True, sort_keys=False, width=DUMP_WIDTH)


def normalise(name):
    return [token for token in re.sub(r"[^\w\s]", "", name.casefold()).split() if token not in LEGAL_SUFFIXES]


def reason(first, second):
    if not first or not second:
        return None
    shorter, longer = sorted((first, second), key=len)
    if longer[: len(shorter)] == shorter:
        return "obvious"
    # plain ratio rates a shared first token followed by different places far below the threshold
    if first[0] == second[0] and fuzz.partial_ratio(" ".join(first), " ".join(second)) >= UNCLEAR_RATIO:
        return "unclear"
    return None


def find_pairs(names, known):
    names = list(dict.fromkeys(names))
    tokens = {name: normalise(name) for name in names}
    pairs = []
    for index, keep in enumerate(names):
        for duplicate in names[index + 1 :]:
            if keep in known or duplicate in known:
                continue
            if found := reason(tokens[keep], tokens[duplicate]):
                pairs.append((keep, duplicate, found))
    return pairs


def document_counts():
    rows = (
        Correspondent.objects.values("name")
        .annotate(documents=Count("documents", filter=Q(documents__deleted_at__isnull=True)))
        .order_by("-documents", "name")
    )
    return {row["name"]: row["documents"] for row in rows}


def known_aliases(taxonomy):
    return {alias: entry["name"] for entry in taxonomy["correspondents"] for alias in entry.get("aliases", [])}


def github(method, path, token, body=None):
    request = urllib.request.Request(
        API + path,
        method=method,
        data=None if body is None else json.dumps(body).encode(),
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "User-Agent": "paperless-dedup",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
            data = response.read()
            return json.loads(data) if data else None
    except urllib.error.HTTPError as error:
        raise RuntimeError(f"GitHub {method} {API}{path} answered {error.code}") from None


def add_aliases(taxonomy, pairs):
    entries = {entry["name"]: entry for entry in taxonomy["correspondents"]}
    aliases = set(known_aliases(taxonomy))
    applied = []
    for keep, duplicate, found in pairs:
        if duplicate in entries and keep not in entries:
            keep, duplicate = duplicate, keep
        if keep in aliases or duplicate in aliases or duplicate in entries:
            continue
        if keep not in entries:
            entries[keep] = {"name": keep}
            taxonomy["correspondents"].append(entries[keep])
        entries[keep].setdefault("aliases", []).append(duplicate)
        aliases.add(duplicate)
        applied.append((keep, duplicate, found))
    return applied


def update_file(text, pairs):
    inner = yaml.safe_load(text)["data"][TAXONOMY_KEY]
    taxonomy = yaml.safe_load(inner)
    if dump(taxonomy) != inner:
        raise ValueError(f"{TAXONOMY_KEY} in {TAXONOMY_FILE} is not in the dumped YAML form; keep that block as this job writes it")
    match = BLOCK.search(text)
    if not match or not text.startswith(textwrap.indent(inner, match.group(1)), match.start(1)):
        raise ValueError(f"{TAXONOMY_KEY} in {TAXONOMY_FILE} is not a literal block")
    start, indent = match.start(1), match.group(1)
    applied = add_aliases(taxonomy, pairs)
    updated = text[:start] + textwrap.indent(dump(taxonomy), indent) + text[start + len(textwrap.indent(inner, indent)) :]
    expected = yaml.safe_load(text)
    expected["data"][TAXONOMY_KEY] = dump(taxonomy)
    if yaml.safe_load(updated) != expected:
        raise ValueError(f"updating {TAXONOMY_FILE} would change more than {TAXONOMY_KEY}")
    return updated, applied


def cell(name):
    return name.replace("|", "\\|")


def describe(pairs, counts):
    rows = "\n".join(
        f"| {cell(keep)} | {counts.get(keep, 0)} | {cell(duplicate)} | {counts.get(duplicate, 0)} | {found} |"
        for keep, duplicate, found in pairs
    )
    proposed = json.dumps([[keep, duplicate] for keep, duplicate, _ in pairs]).replace(">", "\\u003e")
    return (
        "Merging adds each duplicate as an alias of the kept name, so the taxonomy sync moves its documents "
        "and deletes it. Check every pair and remove its alias from the file if the names are different "
        "correspondents. Obvious means the names are equal after normalising, or one name extends the other; "
        "unclear means they share a first word and are similar. Closing this pull request rejects every pair "
        "in it for good; to keep only some pairs, delete the other aliases from the branch and merge.\n\n"
        "| Keep | Documents | Duplicate | Documents | Reason |\n|---|---|---|---|---|\n"
        f"{rows}\n\n<!-- paperless-dedup: {proposed} -->\n"
    )


def proposed_before(pulls):
    seen = set()
    for pull in pulls:
        if not pull["head"]["ref"].startswith(BRANCH_PREFIX):
            continue
        for block in PROPOSED.findall(pull.get("body") or ""):
            try:
                listed = json.loads(block)
            except json.JSONDecodeError:
                continue
            if isinstance(listed, list):
                seen |= {frozenset(pair) for pair in listed if isinstance(pair, list) and all(isinstance(name, str) for name in pair)}
    return seen


def open_pr(pairs, token):
    if not pairs:
        return None
    if not token:
        raise ValueError("a GitHub token is required")
    # reads only the newest PULLS_PAGE pulls per state; past that the Link header needs following
    pulls = github("GET", f"/pulls?state=open&per_page={PULLS_PAGE}", token)
    if any(pull["head"]["ref"].startswith(BRANCH_PREFIX) for pull in pulls):
        return None
    rejected = proposed_before(github("GET", f"/pulls?state=closed&per_page={PULLS_PAGE}", token))
    pairs = [pair for pair in pairs if frozenset(pair[:2]) not in rejected]
    if not pairs:
        return None
    base = github("GET", "", token)["default_branch"]
    head = github("GET", f"/git/ref/heads/{base}", token)["object"]["sha"]
    current = github("GET", f"/contents/{TAXONOMY_FILE}?ref={head}", token)
    updated, applied = update_file(base64.b64decode(current["content"]).decode(), pairs)
    if not applied:
        return None
    branch = BRANCH_PREFIX + datetime.date.today().isoformat()
    github("POST", "/git/refs", token, {"ref": f"refs/heads/{branch}", "sha": head})
    content = base64.b64encode(updated.encode()).decode()
    try:
        github("PUT", f"/contents/{TAXONOMY_FILE}", token, {"message": TITLE, "content": content, "sha": current["sha"], "branch": branch})
        body = describe(applied, document_counts())
        return github("POST", "/pulls", token, {"title": TITLE, "head": branch, "base": base, "body": body})["html_url"]
    except Exception:
        github("DELETE", f"/git/refs/heads/{branch}", token)
        raise


if __name__ == "__main__":
    with open(KNOWN_PATH) as handle:
        known = known_aliases(yaml.safe_load(handle))
    pairs = find_pairs(list(document_counts()), known)
    url = open_pr(pairs, os.environ.get("GITHUB_TOKEN", "").strip())
    print(f"paperless dedup: {len(pairs)} pairs, pull request {url or 'not opened'}")
