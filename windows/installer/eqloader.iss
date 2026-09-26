; Inno Setup script for the Windows installer (built by
; .github/workflows/build.yml for releases). Compile with, e.g.:
;
;   iscc /DAppVersion=1.3.0 /DAppTag=v1.3 /DArch=x64 ^
;        /DSourceDir=build\windows\x64\runner\Release ^
;        /DOutputDir=. /DOutputName=eqloader-v1.3-windows-x64-setup ^
;        windows\installer\eqloader.iss

#define AppName "Walkplay PEQ Loader"
#define AppExe "eqloader.exe"

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef AppTag
  #define AppTag AppVersion
#endif
#ifndef Arch
  #define Arch "x64"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\" + Arch + "\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "."
#endif
#ifndef OutputName
  #define OutputName "eqloader-setup"
#endif

[Setup]
; Never change the AppId: it's how Windows knows a new version is an upgrade.
AppId={{96B73A74-01E4-49C0-A3D6-5E508813FB5B}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppTag}
AppPublisher=devilAPI
AppPublisherURL=https://github.com/devilAPI/walkplay-eqloader
AppSupportURL=https://github.com/devilAPI/walkplay-eqloader/issues
AppUpdatesURL=https://github.com/devilAPI/walkplay-eqloader/releases
VersionInfoVersion={#AppVersion}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
; Lets the user choose "only for me" (no admin rights needed).
PrivilegesRequiredOverridesAllowed=dialog
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
SetupIconFile=..\runner\resources\app_icon.ico
OutputDir={#OutputDir}
OutputBaseFilename={#OutputName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
#if Arch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif
; Close a running copy before replacing its files.
CloseApplications=yes

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[INI]
; Marks this copy as installed (vs. the portable zip): the app can tell the
; two apart by this file next to eqloader.exe.
Filename: "{app}\install.ini"; Section: "eqloader"; Key: "package"; String: "inno"; Flags: uninsdeletesection

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: files; Name: "{app}\install.ini"
