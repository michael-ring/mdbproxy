unit UMdbgProxy;

{$mode objfpc}{$H+}

interface

uses
  {$ifdef unix}cthreads,{$endif}
  Classes, SysUtils, Forms, Process;

type
  TLoggerProc = procedure(const LogText: string);

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
    function WaitForBreak(out BreakAddress : longWord; Timeout: integer = 1000) : boolean;
    procedure StartProcess(Timeout: integer = 1000);
    function GetHwtoolInfo(Timeout: integer = 1000): TStringArray;
    function GetValidDevices(const DeviceFile : String): TStringArray;
    function SetDevice(DeviceName : String ; Timeout: integer = 1000): TStringArray;
    procedure SetInterface(InterfaceName : String ; Timeout: integer = 1000);
    procedure EnableSoftBreakpoints(Timeout: integer = 1000);
    function SetHWTool(HWToolName : String ; Timeout: integer = 1000): TStringArray;
    function ResetCPU(Timeout: integer = 1000): TStringArray;
    function Quit(Timeout: integer = 1000): boolean;

    function ReadByte(const addr : longWord; out Value : byte; Timeout: integer = 1000): boolean;
    function ReadWord(const addr : longWord; out Value : word; Timeout: integer = 1000): boolean;
    function ReadLongWord(const addr : longWord; out Value : LongWord; Timeout: integer = 1000): boolean;

    function WriteByte(const addr : longWord; const Value : byte; Timeout: integer = 1000): boolean;
    function WriteWord(const addr : longWord; const Value : word; Timeout: integer = 1000): boolean;
    function WriteLongWord(const addr : longWord; const Value : longWord; Timeout: integer = 1000): boolean;

    function ReadPC(out Value : TBytes; Timeout: integer = 1000): boolean;
    function ReadPC(out Value : word; Timeout: integer = 1000): boolean;
    function WritePC(const Value : TBytes; Timeout: integer = 1000): boolean;
    function WritePC(const Value : word; Timeout: integer = 1000): boolean;
    function ReadMemory(const addr : longWord; const Len : LongWord; out Values : TBytes; Timeout: integer = 1000): boolean;
    function WriteMemory(const addr : longWord; const Len : LongWord; const Values : TBytes; Timeout: integer = 1000): boolean;
  end;

implementation

uses
  DbugIntf;


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
    //Application.ProcessMessages;
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
          if Line.contains('Failed to reset') then
            TimeOut :=-1;
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

function TMdbgProxy.WaitForBreak(out BreakAddress : longWord; Timeout: integer = 1000):boolean;
var
  Lines : TStringArray;
begin
  Lines := WaitForPrompt(Timeout);
  if length(lines) > 0 then
  begin
    if Lines[0].Contains('Stop at') then
      BreakAddress := Lines[1].Replace('address:0x','$').toInteger;
  end;
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
    if Timeout = -1 then
      Result := nil
    else
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

procedure TMdbgProxy.EnableSoftBreakpoints(Timeout: integer = 1000);
begin
  SendCommand('set debugoptions.useswbreakpoints true',Timeout);
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
  if HWToolName.contains('EDBG') then
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

(*function TMdbgProxy.GetPrintResult(Parameter : String;Timeout: integer = 1000): String;
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
*)

function TMdbgProxy.ReadByte(const Addr : longWord; out Value : Byte; Timeout: integer = 1000): boolean;
var
  Tmp : TBytes;
begin
  setLength(tmp,1);
  Result := ReadMemory(Addr,1,Tmp,Timeout);
  Value := tmp[0];
end;

function TMdbgProxy.ReadWord(const Addr : longWord; out Value : Word; Timeout: integer = 1000): boolean;
var
  Tmp : TBytes;
begin
  setLength(tmp,2);
  Result := ReadMemory(Addr,2,Tmp,Timeout);
  Value := tmp[0]+tmp[1] shl 8;
end;

function TMdbgProxy.ReadLongWord(const Addr : longWord; out Value : LongWord; Timeout: integer = 1000): boolean;
var
  Tmp : TBytes;
begin
  setLength(tmp,4);
  Result := ReadMemory(Addr,1,Tmp,Timeout);
  Value := tmp[0]+tmp[1] shl 8++tmp[2] shl 16+tmp[3] shl 24;
end;

function TMdbgProxy.WriteByte(const Addr : longWord; const Value : Byte; Timeout: integer = 1000): boolean;
begin
  Result := WriteMemory(Addr,4,[Value]);
end;

function TMdbgProxy.WriteWord(const Addr : longWord; const Value : Word; Timeout: integer = 1000): boolean;
begin
  Result := WriteMemory(Addr,1,[Value and $ff,Value shr 8]);
end;

function TMdbgProxy.WriteLongWord(const Addr : longWord; const Value : LongWord; Timeout: integer = 1000): boolean;
begin
  Result := WriteMemory(Addr,1,[Value and $ff,(Value shr 8) and $ff,(Value shr 16) and $ff,(Value shr 24) and $ff]);
end;

function TMdbgProxy.ReadPC(out Value : TBytes; Timeout: integer = 1000): boolean;
var
  Lines : TStringArray;
  tmp : word;
  tmp2 : string;
  _char : char;
begin
  Lines := SendCommand('print PC');
  if (length(lines) = 1) then
  begin
    setLength(Value,2);
    tmp2 := lines[0].subString(3,999);
    tmp := lines[0].subString(3,999).toInteger;
    Value[0] := tmp and $ff;
    Value[1] := tmp shr 8;
    Result := true;
  end
  else
    Result := false;
end;

function TMdbgProxy.ReadPC(out Value : Word; Timeout: integer = 1000): boolean;
var
  Lines : TStringArray;
  tmp : string;
  _char : char;
begin
  Lines := SendCommand('print PC');
  if (length(lines) = 1) then
  begin
    tmp := lines[0].subString(3,999);
    Value := lines[0].subString(3,999).toInteger;
    Result := true;
  end
  else
    Result := false;
end;

function TMdbgProxy.WritePC(const Value : TBytes; Timeout: integer = 1000): boolean;
var
  Lines : TStringArray;
  _char : char;
begin
  Lines := SendCommand('x /fx PC=');
  if (length(lines) >= 1) then
  begin

  end
  else
    Exit(false);
end;

function TMdbgProxy.WritePC(const Value : word; Timeout: integer = 1000): boolean;
var
  Lines : TStringArray;
  _char : char;
begin
  Lines := SendCommand('x /fx PC='+Value.tostring);
  if (length(lines) >= 1) then
  begin

  end
  else
    Exit(false);
end;

function TMdbgProxy.ReadMemory(const Addr : longWord; const Len : longWord; out Values : TBytes; Timeout: integer = 1000): boolean;
var
  i,j : integer;
  Lines : TStringArray;
  _char : char;
  tmp : string;
begin
  if Addr < $800000 then
    Lines := SendCommand('x /tpubfxn'+Len.ToString+' '+(Addr and $ffff).toString)
  else if Addr < $810000 then
    Lines := SendCommand('x /trubfxn'+Len.ToString+' '+(Addr and $ffff).toString)
  else if Addr >=$810000 then
    Lines := SendCommand('x /teubfxn'+Len.ToString+' '+(Addr and $ffff).toString)
  else
    setLength(Lines,0);

  setLength(Values,len);
  for i := 0 to length(lines)-1 do
  begin
    for j := 0 to (length(lines[i]) div 5)-1 do
    begin
      tmp := lines[i].Substring(j*5,2);
      Values[i*16+j] := ('$'+lines[i].Substring(j*5,2)).ToInteger;
    end;
    j := 0;
  end
end;

function TMdbgProxy.WriteMemory(const addr : longWord; const Len : LongWord; const Values : TBytes; Timeout: integer = 1000): boolean;
var
  Lines : TStringArray;
  _char : char;
  convertcount : LongWord;
  tmpline : string;
begin
  try
    ConvertCount := 0;
    tmpline := '';
    if Addr < $800000 then
    begin
      // Flash writes are always LongWord aligned.....
      while ConvertCount < len do
      begin
        if ConvertCount mod 4 = 0 then
          tmpline := tmpLine + '0x';
        tmpline := tmpline+Values[ConvertCount].ToHexString(2);
        inc(ConvertCount);
        if ConvertCount mod 4 = 0 then
          tmpLine := tmpLine + ' ';
        if ConvertCount mod 256 = 0 then
        begin
          Lines := SendCommand('write /tp '+((Addr-256+ConvertCount) and $ffff).toString+' '+tmpLine);
          tmpLine := '';
        end;
      end;
      if tmpLine <> '' then
      begin
        Lines := SendCommand('write /tp '+((Addr+256-ConvertCount) and $ffff).toString+' '+tmpLine);
      end;
    end
    else if Addr < $810000 then
    begin
      Lines := SendCommand('write /tr '+Addr.toString+' ')
    end
    else if Addr >=81000 then
    begin
      Lines := SendCommand('write /te'+Addr.toString+' ')
    end
    else
      SetLength(Lines,0);
  except
  end;

end;

end.
