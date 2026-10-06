@echo off
cd /d "%~dp0"

echo ========================================================
echo Nippon ColorLab AI - Backend Startup
echo ========================================================

IF NOT EXIST "venv\Scripts\activate.bat" (
    echo [INFO] No virtual environment found. Creating one automatically...
    
    REM We specifically try to use Python 3.11 or 3.12 which have stable GPU wheels
    echo [INFO] Looking for Python 3.11...
    py -3.11 -m venv venv 2>nul
    
    IF NOT EXIST "venv\Scripts\activate.bat" (
        echo [INFO] Python 3.11 not found. Looking for Python 3.12...
        py -3.12 -m venv venv 2>nul
    )
    
    IF NOT EXIST "venv\Scripts\activate.bat" (
        echo [INFO] Creating environment with default Python...
        python -m venv venv
    )
    
    echo [INFO] Virtual environment created successfully!
)

echo [INFO] Activating virtual environment...
call venv\Scripts\activate.bat

echo [INFO] Upgrading pip...
python -m pip install --upgrade pip >nul 2>&1

echo [INFO] Installing/Verifying requirements (this automatically installs the GPU version of PyTorch)...
pip install -r requirements.txt

echo [INFO] Starting the server...
python main.py

pause
