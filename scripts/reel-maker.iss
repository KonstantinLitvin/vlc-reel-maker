; Script generated for ReelMaker VLC Media Player Extension
; Requires Inno Setup 6.0+

#define MyAppName "ReelMaker"
#define MyAppVersion "1.2"
#define MyAppPublisher "Konstantin Litvin"
#define MyAppURL "https://github.com/KonstantinLitvin/vlc-reel-maker"
#define MyAppExeName "reel-maker.lua"

[Setup]
AppId={{9F931441-9894-469E-B79E-473DC4EF7D5B}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={userappdata}\vlc\lua\extensions
DefaultGroupName={#MyAppName}
DisableDirPage=no
DisableProgramGroupPage=yes
OutputBaseFilename=ReelMaker-Setup-v{#MyAppVersion}
OutputDir=..\dist
SetupIconFile=..\assets\logo.ico
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[Messages]
english.BeveledLabel=ReelMaker VLC Extension
russian.BeveledLabel=Расширение ReelMaker для VLC

[CustomMessages]
english.TaskFFmpeg=Download and set up FFmpeg for direct lossless video cutting
russian.TaskFFmpeg=Скачать и настроить FFmpeg для прямой нарезки видео без перекодирования
english.StatusRestartVLC=Please restart VLC Media Player and open View -> ReelMaker.
russian.StatusRestartVLC=Перезапустите VLC Media Player и откройте Вид -> ReelMaker.

[Tasks]
Name: "setupffmpeg"; Description: "{cm:TaskFFmpeg}"; GroupDescription: "Tools / Инструменты:"; Flags: checkedonce

[Files]
; English Bundle (language-specific bundle with fallback to default bundle)
#if FileExists("..\dist\reel-maker-en.lua")
Source: "..\dist\reel-maker-en.lua"; DestDir: "{app}"; DestName: "reel-maker.lua"; Languages: english; Flags: ignoreversion
#elif FileExists("..\dist\reel-maker.lua")
Source: "..\dist\reel-maker.lua"; DestDir: "{app}"; DestName: "reel-maker.lua"; Languages: english; Flags: ignoreversion
#endif

; Russian Bundle (language-specific bundle with fallback to default bundle)
#if FileExists("..\dist\reel-maker-ru.lua")
Source: "..\dist\reel-maker-ru.lua"; DestDir: "{app}"; DestName: "reel-maker.lua"; Languages: russian; Flags: ignoreversion
#elif FileExists("..\dist\reel-maker.lua")
Source: "..\dist\reel-maker.lua"; DestDir: "{app}"; DestName: "reel-maker.lua"; Languages: russian; Flags: ignoreversion
#endif

; App Icon
Source: "..\assets\logo.ico"; DestDir: "{app}"; Flags: ignoreversion
; FFmpeg installer batch script and PowerShell helper (for task)
Source: "install-ffmpeg-windows.bat"; DestDir: "{tmp}"; Flags: deleteafterinstall
Source: "download-ffmpeg.ps1"; DestDir: "{tmp}"; Flags: deleteafterinstall

[InstallDelete]
; Clean up legacy extension name
Type: files; Name: "{app}\scene-marker.lua"

[Run]
Filename: "{cmd}"; Parameters: "/c ""{tmp}\install-ffmpeg-windows.bat"" --silent"; Tasks: setupffmpeg; StatusMsg: "Configuring FFmpeg..."; Flags: runhidden waituntilterminated

[UninstallDelete]
Type: files; Name: "{app}\reel-maker.lua"
Type: files; Name: "{app}\logo.ico"
