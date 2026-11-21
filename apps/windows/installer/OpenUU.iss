#ifndef MyAppVersion
  #define MyAppVersion "0.6.1"
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
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
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
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
