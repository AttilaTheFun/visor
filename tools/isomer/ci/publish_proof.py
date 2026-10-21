#!/usr/bin/env python3
"""publish_proof.py: the local CI's runs, as proof of the commit they ran
on, sent to the review server.

Since 2026-10-19 CI runs the fast tests and builds; the screens and the
UI tests are proof an agent makes on its own Mac and publishes to the
review server, tagged with the commit. Reviews then shows a "Proof" row on
a pull request's head and on a release's commit.

    tools/isomer/ci/publish_proof.py [--commit SHA] [--pull-request N] [--branch B] <run dir>...

Each run dir is what the local CI keeps: a snapshots.py run (one folder per
target) or the UI tests' --review folder. Every target folder with a
manifest.json goes, staged as review-<target> with its references inside,
through the review tooling's publish-proof (`//reviews/harnesses:publish_proof`,
in the checkout at $REVIEWS_CHECKOUT, ~/Developer/reviews by default).
Blue's runs only: red's local pictures (app "Visor") are red's to publish.

The commit is the manifests' own unless given (the local CI writes the
commit it tested). The review server's code comes from its Mac over SSH
into the tool's environment: never onto a command line, never printed.
"""
import argparse, json, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "snapshots"))
from publish_review import stage  # noqa: E402

REVIEWS = os.path.expanduser(os.environ.get("REVIEWS_CHECKOUT", "~/Developer/reviews"))
# The review server's Mac, as `ssh` reaches it (user@host).
LAB = os.environ.get("REVIEW_SERVER_HOST", "")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("runs", nargs="+")
    parser.add_argument("--commit")
    parser.add_argument("--pull-request")
    parser.add_argument("--branch")
    args = parser.parse_args()

    with tempfile.TemporaryDirectory(prefix="visor-isomer-proof-") as stage_dir:
        commits = set()
        for run in args.runs:
            for target in sorted(os.listdir(run)):
                source = os.path.join(run, target)
                if not os.path.exists(os.path.join(source, "manifest.json")):
                    continue
                manifest = stage(source, os.path.join(stage_dir, "review-" + target))
                if manifest.get("app") != "Visor Isomer":
                    print(f"skipped {target} ({manifest.get('app')}: not blue's)")
                    subprocess.run(["rm", "-rf", os.path.join(stage_dir, "review-" + target)], check=True)
                    continue
                commits.add(manifest.get("commit", ""))
                print(f"staged {target} ({manifest.get('kind')}, {manifest.get('version')}, {manifest.get('commit', '')[:8]})")
        if not any(name.startswith("review-") for name in os.listdir(stage_dir)):
            sys.exit("publish_proof.py: no blue runs to send")
        commit = args.commit
        if not commit:
            if len(commits) != 1 or not next(iter(commits)):
                sys.exit(f"publish_proof.py: the runs name {len(commits)} commits; give --commit")
            commit = next(iter(commits))

        if not LAB:
            sys.exit("publish_proof.py: set REVIEW_SERVER_HOST to the review server's Mac (user@host)")
        code = subprocess.run(["ssh", "-o", "BatchMode=yes", LAB, "~/.local/bin/reviews-server code"],
                              capture_output=True, text=True)
        lines = code.stdout.strip().splitlines()
        if code.returncode != 0 or not lines:
            sys.exit("publish_proof.py: no review server code from " + LAB)
        env = dict(os.environ, REVIEW_SERVER_CODE=lines[0].strip())

        command = ["bazel", "run", "-c", "opt", "//reviews/harnesses:publish_proof", "--",
                   "runs", stage_dir, "--commit", commit]
        if args.pull_request: command += ["--pull-request", args.pull_request]
        if args.branch: command += ["--branch", args.branch]
        done = subprocess.run(command, cwd=REVIEWS, env=env)
        sys.exit(done.returncode)


if __name__ == "__main__":
    main()
