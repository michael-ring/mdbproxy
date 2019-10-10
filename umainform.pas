unit UMainForm;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, ExtCtrls,
  EditBtn, ComCtrls, UMdbgProxy,rsp;

  { TForm1 }
type
  TForm1 = class(TForm)
    ButtonConnect: TButton;
    ComboBox1: TComboBox;
    ComboBox2: TComboBox;
    ComboBox3: TComboBox;
    Label1: TLabel;
    Label2: TLabel;
    Label3: TLabel;
    Memo1: TMemo;
    Panel1: TPanel;
    procedure ButtonConnectClick(Sender: TObject);
    procedure ComboBox1Change(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
  private
    FMDbgProxy : TMdbgProxy;
    FMplabXVersion : String;
    FDeviceSupportFile : String;
    FMdbgExecutable : String;
    FMPLabXDir : String;
    FConfigFile : String;
    FTCPPort : word;
    //FNetworkThread : TGdbRspServer;
    FNetworkThread : TMdbgNetworkThread;
    procedure WriteIni(Section,Key,Value : String);
    function ReadIni(Section,Key,DefaultValue : String):String;
  public
  end;

var
  Form1: TForm1;

implementation
uses
  FileUtil,DbugIntf,IniFiles;

{$R *.lfm}

{ TForm1 }


procedure Log(const LogText: string);
begin
  SendDebug(FormatDateTime('YYYY-MM-DD hh:nn:ss.zzz ', Now) + LogText);
end;

function PrepareConfigDir : string;
begin
  if not DirectoryExists(GetAppConfigDir(false)) then
  begin
    ForceDirectories(GetAppConfigDir(false));
  end;
  Result := GetAppConfigDir(false);
end;

function DetectMplabXDir : string;
var
  mdbInstances : TStringList;
  BaseDir,Instance : string;

begin
  Result := '';
  {$IFDEF WINDOWS}
  basedir := 'C:\Program Files (x86)\Microchip\MPLABX\';
  {$ELSE}
  basedir := '/Applications/microchip/mplabx/';
  {$ENDIF}

  {$IFDEF WINDOWS}
  mdbInstances := FindAllFiles(basedir,'mdb.bat',true);
  {$ELSE}
  mdbInstances := FindAllFiles(basedir,'mdb.sh',true);
  {$ENDIF}

  if mdbInstances.Count > 0 then
  begin
    for Instance in mdbInstances do
      Log('Found MPLabX Instance: '+ExtractFileDir(ExtractFileDir(ExtractFileDir(Instance))));
    mdbInstances.Sort;
    Result := ExtractFileDir(ExtractFileDir(ExtractFileDir(mdbInstances[mdbInstances.Count-1])))+DirectorySeparator;
  end;
  FreeAndNil(mdbInstances);
end;

function DetectMdbPath(MPLabXPath : String) : string;
var
  mdbInstances : TStringList;
begin
  Result := '';
  {$IFDEF WINDOWS}
  mdbInstances := FindAllFiles(MPLabXPath,'mdb.bat',true);
  {$ELSE}
  mdbInstances := FindAllFiles(MPLabXPath,'mdb.sh',true);
  {$ENDIF}
  if mdbInstances.Count > 0 then
  begin
    mdbInstances.Sort;
    Result := mdbInstances[mdbInstances.Count-1];
    Log('Found mdb script: '+Result);
  end;
  FreeAndNil(mdbInstances);
end;

function extractMPlabXVersion(MPLabXPath : String) : String;
begin
  {$IFDEF WINDOWS}
  Result := MPLabXPath.Remove(0,MPLabXPath.IndexOf('\MPLABX\v')+8);
  Result := Result.Remove(Result.IndexOf('\'));
  {$ELSE}
  Result := MPLabXPath.Remove(0,MPLabXPath.IndexOf('/mplabx/v')+8);
  Result := Result.Remove(Result.IndexOf('/'));
  {$ENDIF}
end;

procedure TForm1.WriteIni(Section,Key,Value : String);
var
  IniFile : TIniFile;
begin
  IniFile := TIniFile.Create(FConfigFile);
  IniFile.WriteString(Section,Key,Value);
  FreeAndNil(IniFile);
end;

function TForm1.ReadIni(Section,Key,DefaultValue : String):String;
var
  IniFile : TIniFile;
begin
  IniFile := TIniFile.Create(FConfigFile);
  Result := IniFile.ReadString(Section,Key,DefaultValue);
  FreeAndNil(IniFile);
end;

procedure TForm1.FormCreate(Sender: TObject);
var
  ConfigDir,Line : String;
  Lines : TStringArray;
  f : TextFile;
begin
  Memo1.Lines.Clear;
  ComboBox1.Items.Clear;
  ComboBox2.Items.Clear;
  ComboBox3.Items.Clear;

  Panel1.Caption := '';

  ButtonConnect.Enabled := false;
  FTcpPort := 2345;

  ConfigDir := PrepareConfigDir;
  FConfigFile := ConfigDir+DirectorySeparator+'mdbproxy.ini';
  Log('Using Config-File:'+FConfigFile);
  Memo1.Lines.Add('Using Config-File:');
  Memo1.Lines.Add(FConfigFile);
  FMPlabXDir := DetectMPLabXDir;
  Memo1.Lines.Add('Detected MPLabXDirectory:');
  Memo1.Lines.Add(FMPlabXDir);
  if FMPlabXDir <> ReadIni('Default','MPlabXDir',FMPlabXDir) then
  begin
    FMPlabXDir := ReadIni('Default','MPlabXDir',FMPlabXDir);
    Memo1.Lines.Add('Overriding MPLabXDirectory from ConfigFile:');
    Memo1.Lines.Add(FMPlabXDir);
  end;
  if FMPLabXDir <> '' then
  begin
    FMpLabXVersion := extractMPlabXVersion(FMPLabXDir);
    FMdbgExecutable := DetectMdbPath(FMPLabXDir);
    Memo1.Lines.Add('Found mdb script:');
    Memo1.Lines.Add(FMdbgExecutable);
    FDeviceSupportFile := ConfigDir+DirectorySeparator+'DeviceSupport-' + FMpLabXVersion;

    FMdbgProxy:= TMDbgProxy.Create(FMdbgExecutable);

    if FileExists(FDeviceSupportFile) then
    begin
      assignFile(f,FDeviceSupportFile);
      reset(f);
      while eof(f) = false do
      begin
        readln(f,line);
        ComboBox2.Items.Add(line);
      end;
      CloseFile(f);
    end
    else
    begin
      Lines := FMdbgProxy.GetValidDevices(FMPLabXDir+'docs'+DirectorySeparator+'Device Support.htm');
      AssignFile(f,FDeviceSupportFile);
      Rewrite(f);
      for line in lines do
      begin
        writeln(f,line);
        ComboBox2.Items.Add(line);
      end;
      CloseFile(f);
    end;
    ComboBox2.Sorted:= true;
    ComboBox2.ItemIndex := 0;

    ComboBox3.Items.add('swd');
    ComboBox3.Items.add('dw');
    ComboBox3.Items.add('updi');
    ComboBox3.Items.add('jtag');
    ComboBox3.Items.add('isp');
    ComboBox3.Items.add('pdi');
    ComboBox3.Items.add('tpi');

    ComboBox3.ItemIndex := 0;

    FMdbgProxy.StartProcess;
    Lines := FMdbgProxy.GetHwtoolInfo(10000);
    if length(Lines) > 0 then
    begin
      for Line in Lines do
        Combobox1.AddItem(Line.Replace(#13,''),nil);
      ComboBox1.ItemIndex := 0;
      ComboBox1.OnChange(Self);
      ButtonConnect.Enabled := true;
    end
    else
    begin
      Memo1.Lines.Add('Could not detect an valid debug Probe on USB');
      Memo1.Lines.Add('');
      Memo1.Lines.Add('Please connect a valid Probe and restart this application');
      FMdbgProxy.Quit;
      Memo1.Lines.Add('MDB Process Terminated');
    end;
  end
  else
  begin
    Memo1.Lines.Add('Could not detect an installation of MPLabX, please download latest version from:');
    Memo1.Lines.Add('');
    Memo1.Lines.Add('https://www.microchip.com/mplab/mplab-x-ide');
    Memo1.Lines.Add('');
    Memo1.Lines.Add('If you have a version installed in a non-standard place then change the ''mdppath'' key');
    Memo1.Lines.Add('');
    Memo1.Lines.Add('in '+FConfigFile);
  end;
end;

procedure TForm1.FormDestroy(Sender: TObject);
begin
  if Assigned(FMdbgProxy) then
  begin
    FMdbgProxy.Quit;
    FreeAndNil(FMDbgProxy);
  end;
  if Assigned(FNetworkThread) then
  begin
    //FNetworkThread.StopAccepting(True);
    FNetworkThread.Terminate;
    FreeAndNil(FNetworkThread);
  end;
end;

procedure TForm1.ButtonConnectClick(Sender: TObject);
var
  SerialNo,Debugger,Chip,_Interface : String;
  ReturnedText : TStringArray;
  line : String;
  pc : word;
begin
  Debugger := ComboBox1.Caption;
  SerialNo := ComboBox1.Caption;
  SerialNo := SerialNo.SubString(SerialNo.IndexOf(' ')+1);

  Chip := ComboBox2.Caption;
  _Interface := ComboBox3.Caption;
  Memo1.Lines.Add('Setting Device: '+Chip);
  Application.ProcessMessages;

  ReturnedText := FMdbgProxy.setDevice(Chip,10000);
  for line in ReturnedText do
    Memo1.Lines.Add(line);
  Application.ProcessMessages;

  if ComboBox3.Enabled then
  begin
    Memo1.Lines.Add('Setting Interface: '+_interface);
    FMdbgProxy.setInterface(_Interface);
    Application.ProcessMessages;
  end;

  Memo1.Lines.Add('Enabling Software Breakpoints');
  FMdbgProxy.enableSoftBreakpoints;
  Application.ProcessMessages;

  Memo1.Lines.Add('Activating Debugger: '+Debugger);
  ReturnedText := FMdbgProxy.setHWTool(Debugger,10000);
  for line in ReturnedText do
  begin
    Memo1.Lines.Add(line);
    if Line.Contains('Updating firmware') or Line.Contains('Entering firmware upgrade mode') then
    begin
      Memo1.Lines.Add('');
      Memo1.Lines.Add('ERROR: New Firmware for your Debug Probe is available');
      Memo1.Lines.Add('use MPLabX or Atmel Studio to upgrade');
      Memo1.Lines.Add('');
    end;
  end;
  Memo1.Lines.Add('Resetting CPU');
  Application.ProcessMessages;

  ReturnedText := FMdbgProxy.ResetCPU(15000);
  for line in ReturnedText do
    Memo1.Lines.Add(line);

  Application.ProcessMessages;
  if FMdbgProxy.ReadPC(pc) = true then
  begin
    WriteIni(SerialNo,'Chip',Chip);
    if ComboBox3.Enabled = true then
      WriteIni(SerialNo,'Interface',_Interface);
    ComboBox1.Enabled := false;
    ComboBox2.Enabled := false;
    ComboBox3.Enabled := false;
    Memo1.Lines.Add('GDBServer waiting for TCP connection on port ' + IntToStr(FTcpPort));
    //FNetworkThread := TGDBRspServer.Create(FTcpPort,FMDBGProxy);
    //FNetworkThread.SetNonBlocking;
    //FNetworkThread.StartAccepting;
    FNetworkThread := TMdbgNetworkThread.Create(FTcpPort,FMDBGProxy);
    FNetworkThread.Resume;
    Memo1.Lines.Add('After FNetwork Thread execute');
  end;
end;

procedure TForm1.ComboBox1Change(Sender: TObject);
var
  SerialNo,Chip,_Interface : String;
begin
  SerialNo := ComboBox1.Caption;
  if SerialNo.toLower.contains('edbg') then
    ComboBox3.Enabled := true
  else
    ComboBox3.Enabled := false;
  SerialNo := SerialNo.SubString(SerialNo.IndexOf(' ')+1);
  Chip := ReadIni(SerialNo,'Chip','');
  if Chip <> '' then
    ComboBox2.ItemIndex := ComboBox2.Items.IndexOf(Chip);
  _Interface := ReadIni(SerialNo,'Interface','');
  if (_Interface <> '') and ComboBox3.Enabled then
    ComboBox3.ItemIndex := ComboBox3.Items.IndexOf(_Interface);
end;

end.

