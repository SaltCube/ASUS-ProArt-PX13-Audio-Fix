powershell "(Get-BitLockerVolume C:).ProtectionStatus" >log.txt
for /f "tokens=*" %%a in (log.txt) do (
  if "%%a" == "On" (exit /b 1) else (exit /b 0)
)