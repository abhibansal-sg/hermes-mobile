"""hermes-mobile plugin — fork-free git branch lookup.

Moved verbatim from ``tui_gateway/server.py`` (ABH-88 de-patch, W1). The
gateway's ``session.create`` handler calls this through a tiny shim that
falls back to the stock subprocess lookup when the plugin isn't loaded.
"""

from __future__ import annotations

import os


def git_branch_fast(cwd: str) -> str:
    """Resolve the current branch WITHOUT forking git.

    ``session.create`` is on the latency-critical path that gates the chat
    composer (the iOS ChatFlow UI test taps "New session" and waits for the
    composer with a 20s budget). The subprocess-based ``_git_branch_for_cwd``
    forks up to two ``git`` children with 1.5s timeouts each — cheap when idle
    but a real fork-storm cost under concurrent test load against a large-RSS
    process. The branch name is cosmetic metadata (the iOS client does not even
    decode it; the desktop re-receives it via the deferred ``session.info``
    event), so read it directly from ``.git/HEAD`` here. Best-effort: any miss
    returns "" and the full git lookup still runs off-path in ``_session_info``.
    """
    try:
        git_dir = os.path.join(cwd, ".git")
        # Support worktrees / submodules where .git is a file pointing elsewhere.
        if os.path.isfile(git_dir):
            try:
                with open(git_dir, "r", encoding="utf-8") as fh:
                    line = fh.readline().strip()
                if line.startswith("gitdir:"):
                    git_dir = os.path.join(cwd, line[len("gitdir:"):].strip())
            except Exception:
                return ""
        head_path = os.path.join(git_dir, "HEAD")
        with open(head_path, "r", encoding="utf-8") as fh:
            head = fh.readline().strip()
        if head.startswith("ref:"):
            ref = head[4:].strip()
            return ref.rsplit("/", 1)[-1] if "/" in ref else ref
        # Detached HEAD — surface the short hash, matching git's fallback.
        return head[:7]
    except Exception:
        return ""
