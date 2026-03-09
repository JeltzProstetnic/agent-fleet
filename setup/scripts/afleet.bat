@echo off
REM afleet — Windows bridge to WSL agent fleet launcher
REM Starts WSL if needed and runs afleet with all arguments
wsl -e bash -lc "afleet %*"
