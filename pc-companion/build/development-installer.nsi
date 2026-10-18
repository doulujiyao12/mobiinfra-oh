; Cross-built, unsigned evaluation installer. Production Windows builds use the
; builder's standard installer and signed uninstaller on the native Windows CI.
!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "x64.nsh"
Name "ClawMate Codex (Development)"
RequestExecutionLevel user
InstallDir "$LOCALAPPDATA\Programs\ClawMate Codex Dev"
!define MUI_ABORTWARNING
!define MUI_WELCOMEPAGE_TEXT "Install the self-contained ClawMate Codex PC application.$\r$\n$\r$\nThis evaluation build is unsigned. Close the PC service before upgrading."
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_INSTFILES
!define MUI_FINISHPAGE_RUN "$INSTDIR\clawmate-codex-desktop.exe"
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"
!insertmacro MUI_LANGUAGE "SimpChinese"
Function .onInit
  ${IfNot} ${RunningX64}
    MessageBox MB_OK|MB_ICONSTOP "This application requires 64-bit Windows."
    Abort
  ${EndIf}
FunctionEnd
Section "Install"
  SetShellVarContext current
  InitPluginsDir
  SetOutPath "$INSTDIR"
  SetCompress off
  !ifdef APP_64
    File /oname=$PLUGINSDIR\application.7z "${APP_64}"
  !else
    !ifdef APP_ARM64
      File /oname=$PLUGINSDIR\application.7z "${APP_ARM64}"
    !else
      !error "Expected a native 64-bit application package"
    !endif
  !endif
  ClearErrors
  Nsis7z::Extract "$PLUGINSDIR\application.7z"
  IfFileExists "$INSTDIR\clawmate-codex-desktop.exe" extracted
    MessageBox MB_OK|MB_ICONSTOP "Application extraction failed."
    Abort
  extracted:
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  CreateShortcut "$DESKTOP\ClawMate Codex Dev.lnk" "$INSTDIR\clawmate-codex-desktop.exe"
  CreateShortcut "$SMPROGRAMS\ClawMate Codex Dev.lnk" "$INSTDIR\clawmate-codex-desktop.exe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ClawMateCodexDev" "DisplayName" "ClawMate Codex (Development)"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ClawMateCodexDev" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ClawMateCodexDev" "UninstallString" '$\"$INSTDIR\Uninstall.exe$\"'
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ClawMateCodexDev" "InstallLocation" "$INSTDIR"
SectionEnd
Section "Uninstall"
  SetShellVarContext current
  Delete "$DESKTOP\ClawMate Codex Dev.lnk"
  Delete "$SMPROGRAMS\ClawMate Codex Dev.lnk"
  ; Keep account, projects, device configuration and task history outside the app.
  IfFileExists "$INSTDIR\resources\app.asar" 0 done
    RMDir /r "$INSTDIR"
  done:
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ClawMateCodexDev"
SectionEnd
