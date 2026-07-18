#!/usr/bin/env python3
"""One-off prod backfill for listing titles.

Phase 1 (homes): give a `title` to the eight listings whose hosts own two homes.
Without it both of a host's listings fall back to "<hostName>'s place" and read
identically in the request sheet and the chat banner.

Phase 2 (stayRequests): copy that title onto the `listingTitle` snapshot of every
existing request against those listings, so requests opened before the fix name
their home too instead of falling back to "your place".

Uses the Firestore REST API over stdlib urllib rather than firebase-admin: the
copy in functions/ is v10 (gaxios 4 -> node-fetch v2), which fails on Node 24
with "Invalid response body ... Premature close" while minting a token.

Deliberately NOT `seed_test_data.js --prod`: that rotates every cast account's
password and rewrites friend edges, conversations, and reviews as well.

Every write is a PATCH carrying updateMask.fieldPaths for the single field being
set, so nothing else on the document is touched. A PATCH would *create* a missing
document, so phase 1 reads all eight ids first and aborts before writing if any is
absent; phase 2 only ever touches documents it just read back from the server.

Usage (dry run prints what would change and writes nothing):
    ./backfill_listing_titles.py
    ./backfill_listing_titles.py --commit
"""

import json
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

PROJECT = "freebnb-6814a"
BASE = f"https://firestore.googleapis.com/v1/projects/{PROJECT}/databases/(default)/documents"

# Must stay in step with scripts/seed_test_data.js. Every listing carries a title
# now, not just the doubled-up hosts: the app requires one on create, and a
# listing without one is a shape the app can no longer produce.
TITLES = {
    "seed-home-spongebob-1": "The Waikiki Pineapple",
    "seed-home-spongebob-2": "The Keys Pineapple",
    "seed-home-sandy-1": "The Space Center Room",
    "seed-home-sandy-2": "The Oak Tree Hideout",
    "seed-home-squidward-1": "The Clarinet Suite",
    "seed-home-squidward-2": "The Easel Loft",
    "seed-home-krabs-1": "The Room Above the Restaurant",
    "seed-home-krabs-2": "The Ocean Drive Condo",
    "seed-home-pearl-1": "The Hollywood Loft",
    "seed-home-larry-1": "The Mission Beach Crash Pad",
    "seed-home-puff-1": "The Harborside Room",
    "seed-home-plankton-1": "The Peninsula Studio",
    "seed-home-karen-1": "The Downtown Unit",
    "seed-home-neptune-1": "The Newport Suite",
    "seed-home-mermaidman-1": "The Conch Fortress",
}

COMMIT = "--commit" in sys.argv[1:]


def token():
    return subprocess.run(
        ["gcloud", "auth", "print-access-token"],
        capture_output=True, text=True, check=True,
    ).stdout.strip()


TOKEN = token()


def call(method, path, params=None, body=None):
    url = f"{BASE}/{path}"
    if params:
        url += "?" + urllib.parse.urlencode(params, doseq=True)
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {TOKEN}")
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as resp:
            return json.load(resp), None
    except urllib.error.HTTPError as err:
        detail = json.load(err).get("error", {}).get("message", str(err))
        return None, detail


def sval(doc, field):
    return doc.get("fields", {}).get(field, {}).get("stringValue")


def patch(path, field, value):
    doc, err = call("PATCH", path,
                    params={"updateMask.fieldPaths": field},
                    body={"fields": {field: {"stringValue": value}}})
    return err


def plan_homes():
    """Reads all eight listings. Returns (todo, missing)."""
    todo, missing = [], []
    for listing_id, want in TITLES.items():
        doc, err = call("GET", f"homes/{listing_id}")
        if err:
            missing.append(listing_id)
            print(f"  {listing_id}  MISSING ({err})")
            continue
        current = sval(doc, "title")
        host = sval(doc, "hostName") or "?"
        if current == want:
            print(f"  {listing_id}  [{host}]  already set")
        else:
            print(f"  {listing_id}  [{host}]  {current or '(none)'} -> \"{want}\"")
            todo.append((listing_id, want))
    return todo, missing


def plan_requests():
    """Reads every stay request and picks the ones pointing at a titled listing."""
    todo = []
    page = None
    scanned = 0
    while True:
        params = {"pageSize": 300}
        if page:
            params["pageToken"] = page
        result, err = call("GET", "stayRequests", params=params)
        if err:
            print(f"  could not list stayRequests: {err}")
            return None
        for doc in result.get("documents", []):
            scanned += 1
            listing_id = sval(doc, "listingID")
            want = TITLES.get(listing_id)
            if not want:
                continue
            name = doc["name"].split("/documents/")[1]
            request_id = name.split("/")[-1]
            current = sval(doc, "listingTitle")
            if current == want:
                print(f"  {request_id}  already set")
            else:
                status = sval(doc, "status") or "?"
                print(f"  {request_id}  [{status}]  {current or '(none)'} -> \"{want}\"")
                todo.append((name, want))
        page = result.get("nextPageToken")
        if not page:
            break
    print(f"  (scanned {scanned} stay requests)")
    return todo


def main():
    print(f"Target: PRODUCTION ({PROJECT})")
    print("Mode: COMMIT (will write)" if COMMIT else "Mode: dry run (no writes)")

    print("\nPhase 1 - listings:")
    home_todo, missing = plan_homes()
    if missing:
        print("\nAborting: at least one listing does not exist in prod. Nothing written.")
        sys.exit(1)

    print("\nPhase 2 - stay request snapshots:")
    request_todo = plan_requests()
    if request_todo is None:
        sys.exit(1)

    total = len(home_todo) + len(request_todo)
    print(f"\n{len(home_todo)} listing(s) and {len(request_todo)} request(s) to change.")
    if total == 0:
        print("Nothing to do.")
        return
    if not COMMIT:
        print("Re-run with --commit to write.")
        return

    print("\nWriting:")
    written = 0
    for listing_id, want in home_todo:
        err = patch(f"homes/{listing_id}", "title", want)
        if err:
            print(f"  {listing_id}  FAILED: {err}")
            sys.exit(1)
        written += 1
        print(f"  {listing_id}  title = \"{want}\"")
    for name, want in request_todo:
        err = patch(name, "listingTitle", want)
        if err:
            print(f"  {name}  FAILED: {err}")
            sys.exit(1)
        written += 1
        print(f"  {name.split('/')[-1]}  listingTitle = \"{want}\"")

    print(f"\nUpdated {written} document(s).")


if __name__ == "__main__":
    main()
