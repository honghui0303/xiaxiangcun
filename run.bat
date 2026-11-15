@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo Starting xianxia-yard...
start "" pythonw "tools\pin_bottom.py"
