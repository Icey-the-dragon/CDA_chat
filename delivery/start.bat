@echo off
setlocal EnableExtensions
set "VM=CDA-Kubeadm-VM"
set "OVA=%~dp0cda-kubeadm.ova"
set "VBOX=C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
if not exist "%VBOX%" set "VBOX=VBoxManage.exe"

call :choose_port || goto :fail

"%VBOX%" showvminfo "%VM%" >nul 2>nul
if errorlevel 1 (
  echo Importing %VM% ...
  "%VBOX%" import "%OVA%" --vsys 0 --vmname "%VM%" || goto :fail
)

set "RUNNING=0"
"%VBOX%" showvminfo "%VM%" --machinereadable 2>nul | findstr VMState= | findstr running >nul
if not errorlevel 1 set "RUNNING=1"

if "%RUNNING%"=="0" (
  "%VBOX%" modifyvm "%VM%" --natpf1 delete app >nul 2>nul
  "%VBOX%" modifyvm "%VM%" --natpf1 "app,tcp,127.0.0.1,%PORT%,,30080" >nul || goto :fail
  echo Starting VM ...
  "%VBOX%" startvm "%VM%" --type gui || goto :fail
)

echo Waiting for http://127.0.0.1:%PORT%/ ...
set /a N=0
:wait
powershell -NoProfile -Command "try { (Invoke-WebRequest -UseBasicParsing http://127.0.0.1:%PORT%/healthz -TimeoutSec 2).StatusCode } catch { exit 1 }" >nul 2>nul
if not errorlevel 1 goto :ready
set /a N+=1
if %N% GEQ 180 goto :timeout
powershell -NoProfile -Command "Start-Sleep -Milliseconds 1500" >nul 2>nul
goto :wait

:choose_port
if not "%APP_PORT%"=="" (
  set "PORT=%APP_PORT%"
  exit /b 0
)
for %%P in (8080 8081 8082 8083 8084) do (
  powershell -NoProfile -Command "try { $c=New-Object Net.Sockets.TcpClient; $c.Connect('127.0.0.1',%%P); $c.Close(); exit 1 } catch { exit 0 }" >nul 2>nul
  if not errorlevel 1 (
    set "PORT=%%P"
    exit /b 0
  )
)
echo ERROR: ports 8080-8084 are busy. Set APP_PORT to a free port. >&2
exit /b 1

:ready
start "" http://127.0.0.1:%PORT%/
echo READY - http://127.0.0.1:%PORT%/
exit /b 0

:timeout
echo ERROR: VM started but the app did not answer. >&2
exit /b 1

:fail
echo ERROR: could not start the VM. >&2
exit /b 1
