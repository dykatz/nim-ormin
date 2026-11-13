# Package

version       = "0.10.0"
author        = "Araq"
description = "Prepared SQL statement generator. A lightweight ORM."
license       = "MIT"
bin = @["tools/ormin_importer"]
skipDirs = @["examples"]
installExt = @["nim"]

# Dependencies
requires "nim >= 2.0.0"
# TEMPORARY: restore the upstream dependency before opening a PR.
requires "https://github.com/dykatz/nim-db_connector#mysql-support"

feature "examples":
  requires "websocket >= 0.2.2"
  requires "karax"
  requires "jester >= 0.6.0"

import std/os
when fileExists("config.nims"):
  include "config.nims"
