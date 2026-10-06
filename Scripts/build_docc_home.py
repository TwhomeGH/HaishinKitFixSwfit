"""產生有版本證據的 DocC 首頁；只使用標準函式庫，可在 Windows 驗證。"""
import argparse
from datetime import datetime, timezone
import html
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
MODULES = {
    "HaishinKit": "haishinkit",
    "RTMPHaishinKit": "rtmphaishinkit",
    "SRTHaishinKit": "srthaishinkit",
    "RTCHaishinKit": "rtchaishinkit",
    "MoQTHaishinKit": "moqthaishinkit",
}


def git(*args):
    result = subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True,
                            text=True, encoding="utf-8", check=True)
    return result.stdout.strip()


def metadata():
    """HEAD 是實際 checkout；不把 workflow ref 或套件版本號當成原始碼版本。"""
    revision = git("rev-parse", "HEAD")
    repository = os.environ.get("GITHUB_REPOSITORY", "TwhomeGH/HaishinKitFixSwfit")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Invalid repository name")
    run = os.environ.get("GITHUB_RUN_ID", "")
    return dict(revision=revision, repository=repository,
                ref=os.environ.get("GITHUB_REF_NAME") or git("branch", "--show-current") or "detached HEAD",
                tags=git("tag", "--points-at", "HEAD").splitlines(),
                dirty=bool(git("status", "--porcelain", "--untracked-files=no")),
                builtAt=datetime.now(timezone.utc).isoformat(timespec="seconds"),
                runURL=f"https://github.com/{repository}/actions/runs/{run}" if run.isdigit() else None)


def render(info):
    """所有 checkout／CI 文字均跳脫後放入 HTML；無動態 JavaScript 依賴。"""
    repo = "https://github.com/" + info["repository"]
    tokens = dict(REPO_URL=repo, COMMIT_URL=repo + "/commit/" + info["revision"],
                  REVISION=info["revision"], REF=info["ref"], TAG=", ".join(info["tags"]) or "此 commit 無標籤",
                  STATE="含未提交原始碼變更" if info["dirty"] else "原始碼乾淨",
                  BUILT_AT=info["builtAt"])
    text = Path(__file__).with_name("docc_home.html").read_text(encoding="utf-8")
    for key, value in tokens.items():
        text = text.replace("@@" + key + "@@", html.escape(value, quote=True))
    run = info.get("runURL")
    run_link = '<a href="' + html.escape(run, quote=True) + '">建置紀錄 ↗</a>' if run else ""
    return text.replace("@@RUN_LINK@@", run_link)


def build(site, info):
    """先核對每個模組的入口與 DocC 資料，再覆寫首頁，避免發布缺失模組的連結。"""
    for module, slug in MODULES.items():
        if not (site / module / "index.html").is_file() or not (site / module / "data/documentation" / (slug + ".json")).is_file():
            raise ValueError("DocC 模組輸出缺失：" + module)
    (site / "index.html").write_text(render(info), encoding="utf-8")
    (site / "build-info.json").write_text(json.dumps(info, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (site / "revision.txt").write_text(info["revision"] + "\n", encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--site", type=Path, required=True)
    args = parser.parse_args()
    build(args.site, metadata())
