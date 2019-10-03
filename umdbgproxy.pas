unit UMdbgProxy;

{$mode objfpc}{$H+}

interface

uses
  {$ifdef unix}cthreads,{$endif}
  Classes, SysUtils, Forms, Process,rsp;

type
  TLoggerProc = procedure(const LogText: string);

type
  TMdbgNetworkThread = class(TThread)
  private
    FServerPort : word;
    FRspServer : TGdbRspServer;
  public
    constructor Create(const ServerPort : word);
    procedure Execute; override;
    destructor Destroy; override;
  end;

type
  TMdbgProxy = class
  private
    //FMdbgThread: TMdbgThread;
    FMdbgPath: string;
    FmdbServerProcess : TProcess;
  public
    constructor Create(const MdbgPath: string);
    procedure Log(const LogText: string);
    function SendCommand(Command: string; Timeout: integer = 1000): TStringArray;
    function WaitForPrompt(Timeout: integer = 1000): TStringArray;
    procedure StartProcess(Timeout: integer = 1000);
    function GetHwtoolInfo(Timeout: integer = 1000): TStringArray;
    function GetValidDevices(const DeviceFile : String): TStringArray;
    function SetDevice(DeviceName : String ; Timeout: integer = 1000): TStringArray;
    procedure SetInterface(InterfaceName : String ; Timeout: integer = 1000);
    function SetHWTool(HWToolName : String ; Timeout: integer = 1000): TStringArray;
    function ResetCPU(Timeout: integer = 1000): TStringArray;
    function Quit(Timeout: integer = 1000): boolean;
    function GetPC(Timeout: integer = 1000): String;
    function GetPrintResult(Parameter : String;Timeout: integer = 1000): String;
  end;

implementation

uses
  DbugIntf;

constructor TMdbgNetworkThread.Create(const ServerPort : word);
begin
  inherited Create(False);
  FServerPort := ServerPort;
  FreeOnTerminate := True;
  SendDebug('MDB Network Thread Created');
end;

procedure TMdbgNetworkThread.Execute;
begin
  SendDebug('MDB Network Thread Executing');
  FRspServer := TGdbRspServer.Create(FServerPort);
  if FRspServer.MaxConnections <> 0 then
  begin
    SendDebug('MDB Network Thread before StartAccepting');
    FRspServer.StartAccepting;
    SendDebug('MDB Network Thread after StartAccepting');
  end
end;

destructor TMdbgNetworkThread.Destroy;
begin
  inherited Destroy;
  SendDebug('MDB Network Thread Destroyed');
end;

constructor TMdbgProxy.Create(const MdbgPath: string);
begin
  inherited Create;
  FMdbgPath := MDbgPath;
end;

procedure TMdbgProxy.Log(const LogText: string);
begin
  SendDebug(FormatDateTime('YYYY-MM-DD hh:nn:ss.zzz ', Now) + LogText);
end;

function TMdbgProxy.WaitForPrompt(Timeout: integer = 1000): TStringArray;
var
  CharCount, i: integer;
  Data: char;
  Line: string;
begin
  Result := nil;
  Line := '';
  repeat
    Application.ProcessMessages;
    Sleep(100);
    TimeOut := Timeout - 100;

    CharCount := FMdbServerProcess.Output.NumBytesAvailable;
    if CharCount > 0 then
    begin
      for i := 1 to CharCount do
      begin
        Data := char(FMdbServerProcess.Output.ReadByte);
        if Data = #10 then
        begin
          Line := Line.Replace(#13,'');
          Log(Line);
          if Line.contains('Downloading AP') then
          begin
            Log('Detected Firmware upgrade, increasing Timeout');
            TimeOut +=30000;
          end;
          if line <> '' then
          begin
            SetLength(Result, Length(Result) + 1);
            Result[Length(Result) - 1] := Line;
            Line := '';
          end;
        end
        else
          Line := Line + Data;
      end;
    end;
  until (pos('>', Line) = 1) or (Timeout < 0);

  if Timeout < 0 then
    Log('WaitForPrompt timeout');
end;

function TMdbgProxy.SendCommand(Command: string;
  Timeout: integer = 1000): TStringArray;
var
  i: integer;
begin
  Log(Command);
  Command := Command + #10;

  //if FMdbgThread.MdbServerProcess.Running then
  if FMdbServerProcess.Running then
  begin
    for i := 1 to length(Command) do
      FMdbServerProcess.Input.Write(Command[i], 1);
    Result := WaitforPrompt(Timeout);
  end;
end;

procedure TMdbgProxy.StartProcess(Timeout: integer = 1000);
begin
  FMdbServerProcess := TProcess.Create(nil);
  FMdbServerProcess.Options := [poUsePipes,poStderrToOutput];
  FMdbServerProcess.Executable := FMdbgPath;
  FMdbServerProcess.CurrentDirectory:=ExtractFileDir(FMdbgPath);
  FMdbServerProcess.Execute;

  WaitForPrompt(TimeOut);
end;

function TMdbgProxy.GetValidDevices(const DeviceFile : String): TStringArray;
var
  f : TextFile;
  line,line2 : String;
  Count : integer;
begin
  Result := nil;
  SetLength(Result,0);
  assignFile(f,DeviceFile);
  reset(f);
  count := 0;
  while eof(f) = false do
  begin
    Readln(f,line);
    if line.contains('<td class=device>') then
    begin
      while line.indexOf('td class=device>') > 0 do
      begin
        line := line.Remove(0,line.indexOf('<td class=device>')+17);
        line2 := line.subString(0,line.IndexOf('<'));
        if count mod 100 = 0 then
          Setlength(Result,Length(Result)+100);
        Result[count] := line2;
        inc(count);
      end;
    end;
  end;
  SetLength(Result,count+1);
end;

function TMdbgProxy.GetHwtoolInfo(Timeout: integer = 1000): TStringArray;
var
  Lines : TStringArray;
  Line : String;
begin
  Result := nil;
  SetLength(Result,0);
  Lines := SendCommand('hwtool',Timeout);
  for Line in Lines do
  begin
    if (length(line) > 0) and (Line[1] >='0') and (Line[1] <= '9') then
    begin
      SetLength(Result,Length(Result)+1);
      Result[Length(Result)-1] := Line.Split(#9)[1];
    end;
  end;
end;

function TMdbgProxy.SetDevice(DeviceName : String ; Timeout: integer = 1000): TStringArray;
var
  Lines : TStringArray;
  Line : String;
begin
  Result := nil;
  SetLength(Result,0);
  Lines := SendCommand('device '+DeviceName,Timeout);
  for line in lines do
  begin
    if (not line.contains('java.util.prefs.WindowsPreferences'))
    and
      ( not line.contains('Could not open/create prefs root node'))
    and
      ( not line.contains('printStackTrace'))
    and
      ( not line.contains('at com.microchip'))
    and
      ( not line.contains('...'))
    and
      ( not line.contains('Caused by:')) then
    begin
      SetLength(Result,Length(Result)+1);
      Result[Length(Result)-1] := Line;
    end;
  end;
end;

procedure TMdbgProxy.SetInterface(InterfaceName : String ; Timeout: integer = 1000);
begin
  SendCommand('set communication.interface '+InterfaceName,Timeout);
end;

function TMdbgProxy.ResetCPU(Timeout: integer = 1000): TStringArray;
begin
  Result := SendCommand('reset',Timeout);
end;

function TMdbgProxy.Quit(Timeout: integer = 1000): boolean;
begin
  Result := true;
  SendCommand('quit',Timeout);
  FMdbServerProcess.CloseInput;
  FMdbServerProcess.CloseOutput;
  if FMdbServerProcess.Running = true then
  begin
    Log('Waiting for Termination');
    Sleep(100);
  end;
  Log('MDB Process Terminated');
  FMdbServerProcess.Terminate(0);
  FreeAndNil(FMdbServerProcess);
end;

function TMdbgProxy.SetHWTool(HWToolName : String ; Timeout: integer = 1000): TStringArray;
var
  Lines : TStringArray;
  Line : String;
begin
  Result := nil;
  SetLength(Result,0);
  if HWToolName.contains('mEDBG') then
    HWToolName := 'EDBG';
  if HWToolName.contains('PICkit 4') then
    HWToolName := 'PICkit4';
  if HWToolName.contains('Snap ICD') then
    HWToolName := 'Snap';
  if HWToolName.contains('PIC32MM Curiosity Development Board') then
    HWToolName := 'SK';
  if HWToolName.contains('PIC32MX470 Family') then
    HWToolName := 'SK';

  Lines := SendCommand('hwtool '+HWToolName,Timeout);
  for line in lines do
  begin
    if (not line.contains('org.openide.util.NbPreferences getPreferencesProvider'))
    and
      (not line.contains('Exception in thread'))
    and
      (not line.contains('ArrayIndexOutOfBoundsException'))
    and
      (not line.contains('at com.microchip'))
    and
      (not line.contains('at java.lang.'))
    and
      (not line.contains('NetBeans implementation of Preferences not found'))
    and
      ( not line.contains('AM com.microchip.mplab'))
    and
      ( not line.contains('PM com.microchip.mplab')) then
    begin
      SetLength(Result,Length(Result)+1);
      Result[Length(Result)-1] := Line;
    end;
  end;
end;

function TMdbgProxy.GetPrintResult(Parameter : String;Timeout: integer = 1000): String;
var
  Lines : TStringArray;
  _char : char;
begin
  Result := 'null';
  Lines := SendCommand('print /f x '+Parameter,Timeout);
  if (length(Lines)=1) and Lines[0].contains('=') then
  begin
    Result := Lines[0].SubString(Lines[0].IndexOf('=')+1).trim;
    for _char in Result do
    begin
      if (_char <'0') or (_char>'9') then
      begin
        Result := 'null';
        break;
      end;
    end;
  end;
end;

function TMdbgProxy.GetPC(Timeout: integer = 1000): String;
var
  Lines : TStringArray;
  _char : char;
begin
  Result := 'null';
  Lines := SendCommand('print PC',Timeout);
  if (length(Lines)=1) and Lines[0].contains('=') then
  begin
    Result := Lines[0].SubString(Lines[0].IndexOf('=')+1).trim;
    for _char in Result do
    begin
      if (_char <'0') or (_char>'9') then
      begin
        Result := 'null';
        break;
      end;
    end;
  end;
end;

end.
