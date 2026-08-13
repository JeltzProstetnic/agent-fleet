@echo off
REM af — Windows bridge to WSL agent fleet launcher (short alias)
REM Starts WSL if needed and runs afleet with all arguments
wsl -e bash -lc "afleet %*"
