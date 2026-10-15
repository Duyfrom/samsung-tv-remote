; Per-user installer: no admin rights, installs to %LOCALAPPDATA%\Programs\TV Remote.  Built by ./build.sh
Unicode true
SetCompressor /SOLID lzma
!define NAME "TV Remote"
!define VERSION "2.0.0"
!define UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\TVRemote"

Name "${NAME}"
OutFile "dist\TV-Remote-Setup-${VERSION}.exe"
InstallDir "$LOCALAPPDATA\Programs\${NAME}"
RequestExecutionLevel user
VIProductVersion "${VERSION}.0"
VIAddVersionKey "ProductName" "${NAME}"
VIAddVersionKey "FileDescription" "${NAME} installer"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "CompanyName" "Khuong Duy Pham"
VIAddVersionKey "LegalCopyright" "Copyright © 2026 Khuong Duy Pham"

!include "MUI2.nsh"
!define MUI_ICON "build\icon.ico"
!define MUI_UNICON "build\icon.ico"
!define MUI_FINISHPAGE_RUN "$INSTDIR\TV Remote.exe"
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

Section
  nsExec::Exec 'taskkill /IM "TV Remote.exe" /F' ; an upgrade replaces a running copy
  Sleep 300
  SetOutPath "$INSTDIR"
  File "dist\TV Remote.exe"
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  CreateShortcut "$SMPROGRAMS\${NAME}.lnk" "$INSTDIR\TV Remote.exe"
  CreateShortcut "$DESKTOP\${NAME}.lnk" "$INSTDIR\TV Remote.exe"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayName" "${NAME}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "Publisher" "Khuong Duy Pham"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayIcon" "$INSTDIR\TV Remote.exe"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoRepair" 1
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "EstimatedSize" 8000
SectionEnd

Section "Uninstall"
  nsExec::Exec 'taskkill /IM "TV Remote.exe" /F'
  Sleep 300
  Delete "$INSTDIR\TV Remote.exe"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
  Delete "$SMPROGRAMS\${NAME}.lnk"
  Delete "$DESKTOP\${NAME}.lnk"
  DeleteRegKey HKCU "${UNINSTALL_KEY}"
  DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "${NAME}"
  RMDir /r "$LOCALAPPDATA\${NAME}" ; WebView2 cache and unpacked UI; settings and shortcuts in %APPDATA% stay
SectionEnd
