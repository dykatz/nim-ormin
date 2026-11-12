"""Run MySQL tests with credentials from the environment or a local dotenv file.

Never logs credentials. MYSQL_DATABASE must be the disposable ormin_test database.
"""
import os
from pathlib import Path
import shlex
import subprocess
import sys


def main():
    env = os.environ.copy()
    path = Path(env.get("ORMIN_MYSQL_ENV", ".ormin-test.env"))
    if path.is_file():
        for line in path.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("export "):
                line = line[7:]
            key, sep, raw = line.partition("=")
            key = key.strip()
            if sep and key.startswith("MYSQL_"):
                parts = shlex.split(raw, comments=True)
                if len(parts) > 1:
                    raise ValueError("Quote environment values containing spaces")
                env.setdefault(key, parts[0] if parts else "")
    if env.get("MYSQL_DATABASE") != "ormin_test":
        raise ValueError("Tests require the disposable MYSQL_DATABASE=ormin_test")
    for test in ("tmysql", "tmysql_import"):
        subprocess.run(["nim", "c", "-r", "-d:mysql", *sys.argv[1:], f"tests/{test}.nim"],
                       env=env, check=True)


if __name__ == "__main__":
    main()
