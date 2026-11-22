#!/bin/bash
# Runs a test script with output on the console: tests/run.sh Script.ahk [args]
cd "$(dirname "$0")"
MSYS_NO_PATHCONV=1 timeout 115 "/c/Program Files/AutoHotkey/v2/AutoHotkey.exe" /ErrorStdOut=UTF-8 "$@" 2>&1 | cat
