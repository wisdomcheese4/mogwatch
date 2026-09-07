@echo off
REM Builds mogwatch_viewer.py into a standalone Windows .exe using PyInstaller.
REM Run this from the same folder as mogwatch_viewer.py and mogwatch.ico.
REM
REM First time only:
REM   pip install pyinstaller pillow
REM
REM Then just run this script whenever you want to rebuild the .exe.

pyinstaller --onefile --windowed --name MogWatch --icon=mogwatch.ico mogwatch_viewer.py

echo.
echo Done. The .exe is in the "dist" folder: dist\MogWatch.exe
echo Copy MogWatch.exe wherever you like -- it looks for its "Maps" folder
echo and settings files (mogwatch_maps.json etc) right next to itself.
