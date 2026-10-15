; Per-user installer: no admin rights, installs to %LOCALAPPDATA%\Programs\TV Remote.  Built by ./build.sh
Unicode true
SetCompressor /SOLID lzma
!define NAME "TV Remote"
!define VERSION "2.0.1"
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

!macro RemoveChromiumProfile
  RMDir /r "$APPDATA\${NAME}\Cache"
  RMDir /r "$APPDATA\${NAME}\Code Cache"
  RMDir /r "$APPDATA\${NAME}\GPUCache"
  RMDir /r "$APPDATA\${NAME}\DawnGraphiteCache"
  RMDir /r "$APPDATA\${NAME}\DawnWebGPUCache"
  RMDir /r "$APPDATA\${NAME}\Local Storage"
  RMDir /r "$APPDATA\${NAME}\Session Storage"
  RMDir /r "$APPDATA\${NAME}\Shared Dictionary"
  RMDir /r "$APPDATA\${NAME}\blob_storage"
  RMDir /r "$APPDATA\${NAME}\Network"
  RMDir /r "$APPDATA\${NAME}\Crashpad"
  Delete "$APPDATA\${NAME}\Preferences"
  Delete "$APPDATA\${NAME}\Local State"
!macroend
!define MUI_ICON "build\icon.ico"
!define MUI_UNICON "build\icon.ico"
!define MUI_FINISHPAGE_RUN "$INSTDIR\TV Remote.exe"
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

; v1 (Electron) installed into this same folder as "TV Remote 1.0.0": drop its uninstall entry so Apps & features
; shows one TV Remote (and the old uninstaller can't delete the new exe).
Function RemoveV1Entry
  StrCpy $0 0
  loop:
    EnumRegKey $1 HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall" $0
    StrCmp $1 "" done
    StrCmp $1 "TVRemote" next
    ReadRegStr $2 HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\$1" "DisplayName"
    ReadRegStr $3 HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\$1" "Publisher"
    StrCpy $2 $2 9
    StrCmp "$2|$3" "TV Remote|Khuong Duy Pham" 0 next
    DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\$1"
    Goto loop ; the next key now has this index
  next:
    IntOp $0 $0 + 1
    Goto loop
  done:
FunctionEnd

Section
  nsExec::Exec 'taskkill /IM "TV Remote.exe" /F' ; an upgrade replaces a running copy (v1 used the same exe name)
  Sleep 500
  ; v1's Electron runtime (~370 MB) and uninstaller; this app is the single exe
  RMDir /r "$INSTDIR\resources"
  RMDir /r "$INSTDIR\locales"
  Delete "$INSTDIR\*.pak"
  Delete "$INSTDIR\*.dll"
  Delete "$INSTDIR\*.bin"
  Delete "$INSTDIR\*.dat"
  Delete "$INSTDIR\LICENSE*"
  Delete "$INSTDIR\vk_swiftshader_icd.json"
  Delete "$INSTDIR\Uninstall TV Remote.exe"
  Call RemoveV1Entry
  ; v1 kept a Chromium profile next to settings.json/shortcuts.json (those stay)
  !insertmacro RemoveChromiumProfile
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
