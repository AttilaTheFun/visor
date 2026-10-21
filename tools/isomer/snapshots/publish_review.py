#!/usr/bin/env python3
"""Puts a run (snapshots, or the UI tests' manifests) in the review store on
the review server's Mac, which the server (`reviews-server`, the review
tooling's) reads: a version is reviewed and signed off in the Reviews app.

  tools/isomer/snapshots/publish_review.py <run dir> [--lab user@host]   (else $REVIEW_SERVER_HOST)

Each of the run's targets with a manifest.json goes to that Mac's store,
~/ReleaseReview/runs/visor-isomer/<version>-<build>/<target>/ (the version
from the manifest: "0.35 (18)" -> 0.35-18). Blue's targets only: the iOS
target here captures red Visor, the reference blue is held to, and red's
runs are visor's to publish. A reference the manifest names by
an absolute path (on this Mac) is copied into the run first, so the run
stands alone there. Nothing to rebuild: the server reads the store.
"""
import argparse, json, os, re, shutil, subprocess, sys, tempfile


def stage(target_dir, out):
    """A copy of one target's run with its references inside it."""
    shutil.copytree(target_dir, out)
    path = os.path.join(out, "manifest.json")
    with open(path) as f:
        manifest = json.load(f)
    for item in manifest.get("items", []):
        reference = item.get("reference")
        if reference and os.path.isabs(reference) and os.path.exists(reference):
            os.makedirs(os.path.join(out, "reference"), exist_ok=True)
            shutil.copy(reference, os.path.join(out, "reference", f'{item["name"]}.png'))
            item["reference"] = f'reference/{item["name"]}.png'
    with open(path, "w") as f:
        json.dump(manifest, f, indent=1)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("run_dir")
    parser.add_argument("--lab", default=os.environ.get("REVIEW_SERVER_HOST", ""))
    args = parser.parse_args()
    if not args.lab:
        sys.exit("publish_review.py: give --lab user@host or set REVIEW_SERVER_HOST")
    published = 0
    with tempfile.TemporaryDirectory() as tmp:
        for target in sorted(os.listdir(args.run_dir)):
            source = os.path.join(args.run_dir, target)
            if not os.path.exists(os.path.join(source, "manifest.json")):
                continue
            manifest = stage(source, os.path.join(tmp, target))
            if manifest.get("app") != "Visor Isomer":
                print(f"skipped {target} ({manifest.get('app')}: not blue's)")
                continue
            numbers = re.findall(r"\d+(?:\.\d+)*", manifest.get("version", ""))
            version = "-".join(numbers) or "unknown"
            remote = f"ReleaseReview/runs/visor-isomer/{version}/{target}/"
            subprocess.run(["ssh", args.lab, "mkdir", "-p", remote], check=True)
            subprocess.run(["rsync", "-a", "--delete", os.path.join(tmp, target) + "/", f"{args.lab}:{remote}"], check=True)
            print(f"published {target} -> {remote}")
            published += 1
    return 0 if published else 1


if __name__ == "__main__":
    sys.exit(main())
