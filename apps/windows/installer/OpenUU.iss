#ifndef MyAppVersion
  #define MyAppVersion "0.7.4"
#endif

#ifndef PublishDir
  #define PublishDir "..\..\..\build\OpenUU-Windows"
#endif

#ifndef OutputDir
  #define OutputDir "..\..\..\build"
#endif

#ifndef OutputBaseFilename
  #define OutputBaseFilename "OpenUU-Windows-x64-Setup"
#endif

#define MyAppName "OpenUU"
#define MyAppPublisher "OpenUU"
#define MyAppURL "https://openuu.1kb.ren"
#define MyAppExeName "OpenUU.exe"

[Setup]
AppId={{7D5D28B8-88F0-4E19-9A62-6D18F8B41A2E}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} v{#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL=https://github.com/onekb/OpenUU/issues
AppUpdatesURL=https://github.com/onekb/OpenUU/releases/latest
DefaultDirName={autopf}\{#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseFilename}
SetupIconFile=..\OpenUUApp\Resources\AppIcon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
UninstallDisplayName={#MyAppName}
Compression=lzma2/fast
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
VersionInfoVersion={#MyAppVersion}.0
VersionInfoCompany={#MyAppPublisher}
VersionInfoDescription={#MyAppName} Windows 安装程序（控制端 & 被控端）
VersionInfoProductName={#MyAppName}

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Default.isl,ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#PublishDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Comment: "OpenUU - 免费开源远程控制与单应用无缝窗口工具"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon; Comment: "OpenUU - 免费开源远程控制与单应用无缝窗口工具"

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent shellexec

[Code]
const
  EVENT_MODIFY_STATE = $0002;

function OpenEventW(dwDesiredAccess: Cardinal; bInheritHandle: BOOL; lpName: string): THandle;
  external 'OpenEventW@kernel32.dll stdcall';
function SetEvent(hEvent: THandle): BOOL;
  external 'SetEvent@kernel32.dll stdcall';
function CloseHandle(hObject: THandle): BOOL;
  external 'CloseHandle@kernel32.dll stdcall';

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  EvHandle: THandle;
begin
  Result := '';
  EvHandle := OpenEventW(EVENT_MODIFY_STATE, False, 'Local\OpenUU.TakeoverExit.v1');
  if EvHandle <> 0 then
  begin
    SetEvent(EvHandle);
    CloseHandle(EvHandle);
    Sleep(900);
  end;
end;
