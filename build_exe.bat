@echo off
REM Builds mogwatch_viewer.py into a standalone Windows .exe using PyInstaller.
REM Run this from the same folder as mogwatch_viewer.py and mogwatch.ico.

echo ==================================================
echo MogWatch .exe builder
echo ==================================================
echo.

set PYCMD=py
py --version >nul 2>&1
if errorlevel 1 (
    set PYCMD=python
)

%PYCMD% --version >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Python was not found.
    echo.
    echo Install Python from https://www.python.org/downloads/
    echo During install, make sure to check "Add Python to PATH".
    echo Then close this window and run build_exe.bat again.
    echo.
    pause
    exit /b 1
)
echo [OK] Python found via "%PYCMD%":
%PYCMD% --version
echo.
echo [DIAGNOSTIC] Exact python.exe being used:
%PYCMD% -c "import sys; print(sys.executable)"
echo.

if not exist "mogwatch_viewer.py" (
    echo [ERROR] mogwatch_viewer.py was not found in this folder.
    echo Make sure build_exe.bat, mogwatch_viewer.py, and mogwatch.ico
    echo are all in the SAME folder, then try again.
    echo.
    pause
    exit /b 1
)
if not exist "mogwatch.ico" (
    echo [WARNING] mogwatch.ico was not found in this folder.
    echo The build will continue, but the .exe won't have the moogle icon.
    echo.
)

%PYCMD% -m PyInstaller --version >nul 2>&1
if errorlevel 1 (
    echo [INFO] PyInstaller not found via "%PYCMD%" -- installing it now along with Pillow...
    %PYCMD% -m pip install pyinstaller pillow
    if errorlevel 1 (
        echo.
        echo [ERROR] pip install failed. Scroll up to see why -- common causes:
        echo   - No internet connection
        echo   - pip itself needs updating: %PYCMD% -m pip install --upgrade pip
        echo.
        pause
        exit /b 1
    )
    %PYCMD% -m PyInstaller --version >nul 2>&1
    if errorlevel 1 (
        echo.
        echo [ERROR] pip reported success, but %PYCMD% still can't find PyInstaller.
        echo.
        echo [DIAGNOSTIC] Where pip actually installed it:
        %PYCMD% -m pip show pyinstaller
        echo.
        echo [DIAGNOSTIC] Where %PYCMD% actually looks for packages:
        %PYCMD% -c "import sys; [print(p) for p in sys.path]"
        echo.
        echo [DIAGNOSTIC] Checking if antivirus quarantined the installed files:
        %PYCMD% -c "import PyInstaller" 2>&1
        echo.
        echo Compare the "Location:" line above against the paths listed
        echo right after it. If they don't match, that confirms multiple
        echo Python installs are involved. If the Location path DOES appear
        echo in the list but PyInstaller still won't import, this is very
        echo likely Windows Defender ^(or another antivirus^) quarantining
        echo PyInstaller's files right after install -- check your antivirus's
        echo quarantine/history log for anything related to "pyinstaller".
        echo.
        pause
        exit /b 1
    )
) else (
    echo [OK] PyInstaller is already installed.
)
echo.

echo Building MogWatch.exe, this can take a minute or two...
echo.
if exist "mogwatch.ico" (
    %PYCMD% -m PyInstaller --onefile --windowed --name MogWatch --icon=mogwatch.ico --add-data "mogwatch.ico;." mogwatch_viewer.py
) else (
    %PYCMD% -m PyInstaller --onefile --windowed --name MogWatch mogwatch_viewer.py
)

if errorlevel 1 (
    echo.
    echo [ERROR] The build failed. Scroll up in this window to see PyInstaller's
    echo actual error message -- that will say exactly what went wrong.
    echo.
    pause
    exit /b 1
)

echo.
echo ==================================================
if exist "dist\MogWatch.exe" (
    echo SUCCESS: dist\MogWatch.exe was created.
    echo Copy MogWatch.exe wherever you like -- it looks for its "Maps"
    echo folder and settings files right next to itself.
) else (
    echo [ERROR] PyInstaller finished without an error, but dist\MogWatch.exe
    echo doesn't exist. Scroll up to check the build log for clues.
)
echo ==================================================
echo.
pause
