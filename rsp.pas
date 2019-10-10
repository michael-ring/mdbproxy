unit rsp;

interface

uses
  {$ifdef unix}cthreads,{$endif}
  Classes, SysUtils, ssockets,UMDBGProxy;

  type
  {TGdbRspThread }
  TDebugState = (dsPaused, dsRunning);
  TDebugStopReason = (srCtrlC, srHWBP, srSWBP);

  TFlashWriteBuffer = record
    addr: word;
    Data: TBytes;
  end;

  // To view rsp communication as received by gdb:
  // (gdb) set debug remote 1
  TGdbRspThread = class(TThread)
  private
    FClientStream: TSocketStream;
    FDebugState: TDebugState;
    //FBPManager: TBPManager;
    FLastCmd: string;  // in case a resend is required;
    FFlashWriteBuffer: array of TFlashWriteBuffer;
    FMDBGProxy : TMDBGProxy;

    function gdb_fieldSepPos(cmd: string): integer;
    procedure gdb_response(s: string);
    procedure gdb_response(data: TBytes);
    procedure gdb_qSupported(cmd: string);

    function FTCPDataAvailable: boolean;

    // Debugwire interface
    procedure DebugContinue;
    procedure DebugStep;
    procedure DebugGetRegisters;
    procedure DebugGetRegister(cmd: string);
    procedure DebugSetRegisters(cmd: string);
    procedure DebugSetRegister(cmd: string);
    procedure DebugGetMemory(cmd: string);
    procedure DebugSetMemoryHex(cmd: string);
    procedure DebugSetMemoryBinary(cmd: string);
    procedure DebugStopReason(signal: integer; stopReason: TDebugStopReason);
    procedure DecodeBinary(const s: string; out data: TBytes);
    procedure EncodeBinary(const data: TBytes; out s: string);
  public
    constructor Create(AClientStream: TSocketStream; var aMDBGProxy : TMDBGProxy);
    procedure Execute; override;
    //property OnLog: TLog read FLogger write FLogger;
  end;

  { TGdbRspServer }

  TGdbRspServer = class(TInetServer{TTCPServer})
  private
    FActiveThread: TGdbRspThread;
    FActiveThreadRunning: boolean;
    FMDBGProxy : TMDBGProxy;

    procedure FActiveThreadOnTerminate(Sender: TObject);
    procedure FAcceptConnection(Sender: TObject; Data: TSocketStream);
    procedure FQueryConnect(Sender: TObject; ASocket: LongInt; var doaccept: Boolean);
  public
    constructor Create(APort: Word;var aMDBGProxy : TMDBGProxy);
  end;

  TMdbgNetworkThread = class(TThread)
  private
    FServerPort : word;
    FRspServer : TGdbRspServer;
    FMDBGProxy : TMDBGProxy;
  public
    constructor Create(const ServerPort : word;var aMDBGProxy : TMDBGProxy);
    procedure Execute; override;
    destructor Destroy; override;
  end;

implementation

uses
  DbugIntf,
  {$IFNDEF WINDOWS}BaseUnix, sockets, math;
  {$ELSE}winsock2, windows;
  {$ENDIF}

function AddrToString(Addr: TSockAddr): String;
{$IFDEF WINDOWS}
//var

{$ENDIF}
begin
  {$IFNDEF WINDOWS}
  Result := NetAddrToStr(Addr.sin_addr);
  {$ELSE}
  Result := inet_ntoa(Addr.sin_addr);
  {$ENDIF}

  Result := Result  + ':' + IntToStr(Addr.sin_port);
end;

procedure Log(const LogText: string);
begin
  SendDebug(FormatDateTime('YYYY-MM-DD hh:nn:ss.zzz ', Now) + LogText);
end;

function TGdbRspThread.gdb_fieldSepPos(cmd: string): integer;
var
  colonPos, commaPos, semicolonPos: integer;
begin
  colonPos := pos(':', cmd);
  commaPos := pos(',', cmd);
  semicolonPos := pos(';', cmd);

  result := Max(colonPos, semicolonPos);
  result := Max(result, commaPos);

  if (colonPos > 0) and (result > colonPos) then
    result := colonPos;

  if (commaPos > 0) and (result > commaPos) then
    result := commaPos;

  if (semicolonPos > 0) and (result > semicolonPos) then
    result := semicolonPos;
end;


procedure TGdbRspThread.gdb_response(s: string);
var
  checksum, i: integer;
  reply: string;
begin
  FLastCmd := s;
  checksum := 0;

  for i := 1 to length(s) do
    checksum := checksum + ord(s[i]);

  reply := '$' + s + '#' + hexStr(byte(checksum), 2);
  FClientStream.WriteBuffer(reply[1], length(reply));
  Log('<- ' + reply);
end;


procedure TGdbRspThread.gdb_response(data: TBytes);
var
  resp: string;
  i: integer;
begin
  resp := '';
  for i := 0 to length(data)-1 do
    resp := resp + hexStr(data[i], 2);

  gdb_response(resp);
end;

procedure TGdbRspThread.gdb_qSupported(cmd: string);
begin
  if pos('Supported', cmd) > 0 then
    gdb_response('PacketSize=216;qXfer:memory-map:read-;swbreak+;hwbreak+;')
      // A packetsize of 216 results in flash memory write commands that are 512 Bytes
      // to prevent potential repeated erasing of the same flash page
      // due to data transfer fragementation
  else if pos('Offsets', cmd) > 0 then
    gdb_response('Text=0;Data=0;Bss=0')
  else if pos('Symbol', cmd) > 0 then
    gdb_response('OK');
end;

function TGdbRspThread.FTCPDataAvailable: boolean;
{$if defined(unix) or defined(windows)}
var
  FDS: TFDSet;
  TimeV: TTimeVal;
{$endif}
begin
  Result:=False;
{$if defined(unix) or defined(windows)}
  TimeV.tv_usec := 1 * 1000;  // 1 msec
  TimeV.tv_sec := 0;
{$endif}
{$ifdef unix}
  FDS := Default(TFDSet);
  fpFD_Zero(FDS);
  fpFD_Set(self.FClientStream.Handle, FDS);
  Result := fpSelect(self.FClientStream.Handle + 1, @FDS, nil, nil, @TimeV) > 0;
{$else}
{$ifdef windows}
  FDS := Default(TFDSet);
  FD_Zero(FDS);
  FD_Set(self.FClientStream.Handle, FDS);
  Result := Select(self.FClientStream.Handle + 1, @FDS, nil, nil, @TimeV) > 0;
{$endif}
{$endif}
end;

procedure TGdbRspThread.DebugContinue;
begin
  FDebugState := dsRunning;
  // Do not wait for Command Results when calling Continue, we will wait for a hit breakpoint in the main loop
  FMDBGProxy.SendCommand('Continue',-1);
end;

procedure TGdbRspThread.DebugStep;
var
  instruction, oldPC: word;
//  ActiveBPRecord: PBP;
begin
  // Do not wait for Command Results when calling Continue, we will wait for a hit breakpoint in the main loop
  FDebugState := dsRunning;
  FMDBGProxy.SendCommand('Step',-1);
end;

procedure TGdbRspThread.DebugGetRegisters;
var
  data: TBytes;
  s : string;
  i: integer;
begin
  try
    s := '';
    setLength(Data,32);
    FMDBGProxy.ReadMemory($800000+0,32,data);
    for i := 0 to 31 do
      s := s + data[i].ToHexString(2);

    // SREG
    FMDBGProxy.ReadMemory($800000+$5F,1,data);
    s := s + data[0].ToHexString(2);

    // SP
    FMDBGProxy.ReadMemory($800000+$5D,2,data);
    s := s + data[0].ToHexString(2) + data[1].ToHexString(2);

    // PC
    FMDBGProxy.ReadPC(data);
    s := s + data[0].ToHexString(2) + data[1].ToHexString(2);
    // PC in GDB is 32 Bit so fill PC to 32Bits
    s := s+'0000';
    gdb_response(s.toLower);
  except
    gdb_response('E00');
  end;
end;

procedure TGdbRspThread.DebugGetRegister(cmd: string);
var
  regID: integer;
  s: string;
  i: integer;
  values : TBytes;
begin
  try
    s := '';
    setLength(values,2);
    // cmd still contain full gdb string with p prefix
    delete(cmd, 1, 1);
    if Length(cmd) = 2 then // Hex number of a byte value
    begin
      regID := StrToInt('$'+cmd)+$800000;
      case regID of
        0..31: begin // normal registers
                 FMDBGProxy.ReadMemory(regID,1,values);
                 s := values[0].ToHexString(2);
               end;
        32:    begin // SREG
                 FMDBGProxy.ReadMemory($5F,1,values);
                 s := values[0].ToHexString(2);
               end;
        33: begin
               FMDBGProxy.ReadMemory($5D,2,values);
               s := values[0].ToHexString(2)+values[1].ToHexString(2);
            end;

        34: begin // PC
               FMDBGProxy.ReadPC(values);
               s := values[0].ToHexString(2)+values[1].ToHexString(2)+'0000';
            end;
      end;
    end;
    if s <> '' then
      gdb_response(s.toLower)
    else
      gdb_response('E00');
  except
    gdb_response('E00');
  end;
end;

procedure TGdbRspThread.DebugSetRegisters(cmd: string);
var
  data: TBytes;
  l1, len, i: integer;
  s: string;
begin
  try
    // cmd still contain full gdb string with G prefix
    delete(cmd, 1, 1);
    len := length(cmd) div 2;  // in byte equivalents

    // extract normal registers
    l1 := min(len, 32);
    SetLength(data, l1);
    for i := 0 to l1-1 do
    begin
      s := '$' + cmd[2*i + 1] + cmd[2*i + 2];
      FMDBGProxy.WriteMemory(i+800000,1,[byte(s.ToInteger)]);
    end;

    // Check for SREG
    if (len > 32) then
    begin
      s := '$' + cmd[65] + cmd[66];
      SetLength(data, 1);
      FMDBGProxy.WriteMemory($5F+$80000,1,[byte(s.ToInteger)]);
    end;

    // Check for SPL/SPH
    if (len > 34) then
    begin
      SetLength(data, 2);
      s := '$' + cmd[67] + cmd[68];
      data[0] := StrToInt(s);
      SetLength(data, 2);
      s := '$' + cmd[69] + cmd[70];
      data[1] := StrToInt(s);
      FMDBGProxy.WriteMemory($5D+$800000,2,data);
    end;

    // Should be PC
    if (len = 39) then
    begin
      s := '$' + copy(cmd, 71, 8);
      FMDBGProxy.WritePC(word(s.ToInteger));
    end;
    gdb_response('OK');
  except
    gdb_response('E00');
  end;
end;

procedure TGdbRspThread.DebugSetRegister(cmd: string);
var
  regID: integer;
  data: TBytes;
  sep, val, numbytes, i: integer;
begin
  try
    // cmd still contain full gdb string with P prefix
    delete(cmd, 1, 1);
    sep := pos('=', cmd);
    if sep = 3 then // regID is before '='
    begin
      regID := StrToInt('$' + copy(cmd, 1, 2));

      numbytes := (length(cmd) - 3) div 2;
      SetLength(data, numbytes);
      for i := 0 to numbytes-1 do
      begin
        val := StrToInt('$' + cmd[4 + i*2] + cmd[4 + i*2 + 1]);
        data[i] := (val shr (8*i)) and $ff;
      end;

      case regID of
        // normal registers
        0..31: begin
                 FMDBGProxy.WriteMemory(regID+$800000,1,data);
               end;
        // SREG
        32: begin
              FMDBGProxy.WriteMemory($5F+$800000,1,data);
            end;
        // SPL, SPH
        33: begin
              FMDBGProxy.WriteMemory($5D+800000,2,data);
            end;
        // PC
        34: begin
              FMDBGProxy.WritePC(data);
            end;
      end;
    end;
    gdb_response('OK');
  except
    gdb_response('E00');
  end;
end;

procedure TGdbRspThread.DebugGetMemory(cmd: string);
var
  len, i, err: integer;
  s: string;
  addr: dword;
  data: TBytes;
begin
  try
    delete(cmd, 1, 1);
    len := gdb_fieldSepPos(cmd);
    s := '$' + copy(cmd, 1, len-1);
    delete(cmd, 1, len);

    val(s, addr, err);
    if err <> 0 then
      addr := $FFFFFFFF; // invalid address, should be caught below

    len := gdb_fieldSepPos(cmd);
    delete(cmd, len, length(cmd) - len);
    len := StrToInt('$' + cmd);

    s := '';
    setLength(data,len);
    FMDBGProxy.ReadMemory(addr,len,data);

    for i := 0 to high(data) do
      s := s + hexStr(data[i], 2);

    gdb_response(s);
  except
    gdb_response('E00');
  end;
end;

procedure TGdbRspThread.DebugSetMemoryHex(cmd: string);
var
  len, i: integer;
  s: string;
  addr: dword;
  data: TBytes;
begin
  try
    delete(cmd, 1, 1);
    len := gdb_fieldSepPos(cmd);
    s := '$' + copy(cmd, 1, len-1);
    addr := StrToInt(s);
    delete(cmd, 1, len);

    len := gdb_fieldSepPos(cmd);
    s := '$' + copy(cmd, 1, len-1);
    delete(cmd, 1, len);

    // now convert data
    len := length(cmd) div 2;
    SetLength(data, len);
    s := '';
    for i := 0 to len-1 do
    begin
      s := '$' + cmd[2*i + 1] + cmd[2*i + 2]; // 1 based index
      data[i] := StrToInt(s);
    end;
    FMDBGProxy.WriteMemory(addr,len,data);
    gdb_response('OK');
  except
    gdb_response('E00');
  end;
end;

// X addr,len:XX...
procedure TGdbRspThread.DebugSetMemoryBinary(cmd: string);
var
  len: integer;
  s: string;
  addr: dword;
  data: TBytes;
  f : file;
begin
  try
    delete(cmd, 1, 1);
    len := gdb_fieldSepPos(cmd);
    s := '$' + copy(cmd, 1, len-1);
    addr := StrToInt(s);
    delete(cmd, 1, len);

    len := gdb_fieldSepPos(cmd);
    s := '$' + copy(cmd, 1, len-1);
    delete(cmd, 1, len);
    len := StrToInt(s);
    if (addr = 0) and (len = 0) then
    begin
      //Answer with OK to switch to binary mode:
      gdb_response('OK');
    end
    else
    begin
      // now convert data
      DecodeBinary(cmd, data);
      if len = length(data) then // ensure decoding yields the expected length data
      begin
        FMDBGProxy.WriteMemory(addr,len,data);
        gdb_response('OK');
      end
      else
      begin
        //FLog('Decoded length <> expected length of binary data.');
        gdb_response('E02');
     end;
    end;
  except
    gdb_response('E00');
  end;
end;

procedure TGdbRspThread.DecodeBinary(const s: string; out data: TBytes);
var
  i, j, n: integer;
  repeatData: byte;
begin
  SetLength(data, 128);
  // s should start before ':', then scan until ending #
  i := 1;
  j := 0;

  while (i <= length(s)) and (s[i] <> '#') do
  begin
    if s[i] = '}' then  // escape character
    begin
      inc(i);  // read next character
      data[j] := ord(s[i]) XOR $20;
      inc(j);
    end
    else if s[i] = '*' then //run length encoding
    begin
      if j > 0 then
      begin
        // repeat count in next byte
        // previous byte is repeated
        inc(i);
        n := ord(s[i]) - 29;
        repeatData := data[j-1];
        while n > 0 do
        begin
          data[j] := repeatData;
          inc(j);
          dec(n);
        end;
      end
      else
        Log('Unexpected run length encoding detected at start of data.');
    end
    else
    begin
      data[j] := ord(s[i]);
      inc(j);
    end;
    inc(i);
    if j >= length(data) then
      SetLength(data, j + 128);
  end;

  SetLength(data, j);
end;

procedure TGdbRspThread.EncodeBinary(const data: TBytes; out s: string);
var
  i, j: integer;
begin
  SetLength(s, 128);

  j := 1;
  for i := 0 to high(data) do
  begin
    case data[i] of
      $23, $24, $2A, $7D:    // #, $, *, }
        begin
          s[j] := '}';
          inc(j);
          s[j] := char(data[i] XOR $20);
        end
      else
        s[j] := char(data[i]);
    end;

    inc(j);
    if j > length(s)-1 then
      SetLength(s, Length(s) + 128);
  end;
  SetLength(s, j-1);
end;

procedure TGdbRspThread.DebugStopReason(signal: integer;
  stopReason: TDebugStopReason);
var
  s: string;
  data: TBytes;
  i: integer;
begin
  try
    //s := 'T' + hexStr(signal, 2);
    s := 'S05';
    case stopReason of
      srHWBP: s := s + 'hwbreak';
      srSWBP: s := s + 'swbreak';
    end;

    setLength(Data,32);
    FMDBGProxy.ReadMemory($800000+0,32,data);
    for i := 0 to 31 do
      s := s + data[i].ToHexString(2);

    // SREG
    FMDBGProxy.ReadMemory($800000+$5F,1,data);
    s := s + data[0].ToHexString(2);

    // SP
    FMDBGProxy.ReadMemory($800000+$5D,2,data);
    s := s + data[0].ToHexString(2) + data[1].ToHexString(2);

    // PC
    FMDBGProxy.ReadPC(data);
    s := s + data[0].ToHexString(2) + data[1].ToHexString(2);
    // PC in GDB is 32 Bit so fill PC to 32Bits
    s := s+'0000';
    gdb_response(s);
  except
    gdb_response('E00');
  end;
end;

{ TGdbRspThread }

constructor TGdbRspThread.Create(AClientStream: TSocketStream;var aMDBGProxy : TMDBGProxy);
//  logger: TLog);
begin
  inherited Create(false);
  FreeOnTerminate := true;
  FClientStream := AClientStream;
  FMDBGProxy := aMDBGProxy;
  FDebugState := dsPaused;
end;

function pos_(const c: char; const s: RawByteString): integer;
var
  i, j: integer;
begin
  i := 1;
  j := length(s);
  while (i < j) and (s[i] <> c) do
    inc(i);

  if s[i] = c then result := i
  else
  result := 0;
end;

procedure TGdbRspThread.Execute;
var
  msg, cmd : RawByteString;
  BreakAddress : LongWord;
  buf: array[0..1023] of char;
  count, i, j, idstart, idend, addr: integer;
  Done: boolean;
begin
  Done := false;
  msg := '';

  repeat
    try
      if FTCPDataAvailable then
      begin
        count := FClientStream.Read(buf[0], length(buf));
        // if socket signaled and no data available -> connection closed
        if count = 0 then
        begin
          // simulate a kill command, it will delete hw BP and run target
          // then exit this thread
          buf[0]:='$'; buf[1]:='k'; buf[2]:='#'; buf[3]:='0'; buf[4]:='0';  // CRC is not checked...
          count := 5;
          Log('No data read, exiting read thread by simulating [k]ill...');
        end;
      end
      else
        count := 0;

      // If running target, check check for break
      if FDebugState = dsRunning then
      begin
        if FMDBGProxy.WaitForBreak(BreakAddress) = true then
        begin
          FDebugState := dsPaused;
          DebugStopReason(5, srHWBP);
        end
      end;

      if count > 0 then
      begin
        SetLength(msg, count);
        Move(buf[0], msg[1], count);
        //msg := copy(buf, 1, count);

        // ctrl+c falls outside of normal gdb message structure
        if msg[1] = #3 then // ctrl+C
        begin
          // ack received command
          FClientStream.WriteByte(ord('+'));
          Log('-> Ctrl+C');
          //FDebugWire.BreakCmd;
          //FDebugWire.Reconnect;
          //FDebugState := dsPaused;
          DebugStopReason(2, srCtrlC); // SIGINT, because the program was interrupted...
        end
        else
          Log('-> ' + msg);

        i := pos('$', msg);  // start of command
        j := pos('#', msg);  // end of command

        // This check also skip ack / nack replies (+/-)
        if (i > 0) and ((count - 2) >= j) then  // start & terminator + 2 byte CRC received
        begin
          // ack received command
          FClientStream.WriteByte(ord('+'));
          Log('<- +');

          cmd := copy(msg, i + 1, (j - i - 1));

          case cmd[1] of
            // stop reason
            '?': DebugStopReason(5, srHWBP);

            // continue
            'c': begin
                   //FBPManager.FinalizeBPs;  // check which BPs needs to be removed/written
                   //FBPManager.PrintBPs;     // debug
                   DebugContinue;
                 end;

            // detach, kill
            // Reset and continue MCU - no way to kill target anyway
            'D', 'k':
              begin
                Done := true;         // terminate debug connection
                if cmd[1] = 'k' then  // kill handled as break/reset/run
                  //FDebugWire.Reset
                else                  // assume detach leaves system in a runnable state
                  gdb_response('OK');

                //Done: call BP manager to remove HW & SW BPs
                //FBPManager.DeleteAllBPs;
                //FBPManager.FinalizeBPs;
                //FBPManager.PrintBPs;     // debug
                //FDebugWire.Run;
              end;

            // read general registers 32 registers + SREG + PCL + PCH + PCHH
            'g': DebugGetRegisters;

            // write general registers 32 registers + SREG + PCL + PCH + PCHH
            'G': DebugSetRegisters(cmd);

            // Set thread for operation - only 1 so just acknowledge
            'H': gdb_response('OK');

            // Read memory
            'm': DebugGetMemory(cmd);

            // Write memory
            'M': DebugSetMemoryHex(cmd);

            'p': DebugGetRegister(cmd);

            'P': DebugSetRegister(cmd);

            'q': if pos('Supported', cmd) > 0 then
                   gdb_qSupported(cmd)
            {$IFDEF memorymap}
                 else if pos('Xfer:memory-map:read', cmd) > 0 then
                   DebugMemoryMap(cmd)
            {$ENDIF memorymap}
                 else
                   gdb_response('');

            // step
            's': begin
                   // TODO: Check if stepping into a sw BP?
                   DebugStep;
                   DebugStopReason(5, srSWBP);
                 end;
            'X': begin
                   DebugSetMemoryBinary(cmd);
                 end;

            // delete breakpoint
            'z': begin
                   if (cmd[2] in ['0', '1']) then
                   begin
                     idstart := gdb_fieldSepPos(cmd);
                     delete(cmd, 1, idstart);
                     idend := gdb_fieldSepPos(cmd);
                     msg := copy(cmd, 1, idend-1);
                     addr := StrToInt('$' + msg);

                     //FBPManager.DeleteBP(addr);
                     gdb_response('OK');
                   end
                   else
                     gdb_response('');
                 end;

            // insert sw or hw breakpoint via BP manager
            'Z': begin
                   if (cmd[2] in ['0', '1']) then
                   begin
                     idstart := gdb_fieldSepPos(cmd);
                     delete(cmd, 1, idstart);
                     idend := gdb_fieldSepPos(cmd);
                     msg := copy(cmd, 1, idend-1);

                     addr := StrToInt('$'+msg);
                     FMDBGProxy.SendCommand('break *0x'+addr.ToHexString(8));
                     gdb_response('OK');
                   end
                   else  // other BPs such as watch points not supported
                     gdb_response('');
                 end;
            else
              gdb_response('');
          end; // case
        end     // if (i > 0) and ((count - 2) >= j)
        else if (msg[1] = '-') then
        begin
          Log('Resending previous message');
          gdb_response(FLastCmd);
        end;
        count := 0;  // so that next loop doesn't echo...
      end;       // if (count > 0)
    except
      on e: Exception do
      begin
        Done := true;
        Log('Exception: ' + e.Message);
      end;
    end;
  until Done;

  // Update status of server thread
  OnTerminate(self);
end;

{ TGdbRspServer }

procedure TGdbRspServer.FActiveThreadOnTerminate(Sender: TObject);
begin
  FActiveThreadRunning := false;
  Log('FActiveThreadOnTerminate');
  halt;
end;

procedure TGdbRspServer.FAcceptConnection(Sender: TObject; Data: TSocketStream);
begin
  if not FActiveThreadRunning then
  begin
    Log('Incoming connection from ');// + AddrToString(Data.RemoteAddress));
    FActiveThread := TGdbRspThread.Create(Data,FMDBGProxy);
    FActiveThread.OnTerminate := @FActiveThreadOnTerminate;
    FActiveThreadRunning := true;
  end
  else
  begin
    Log('Multiple connections not allowed...');
  end;
end;

procedure TGdbRspServer.FQueryConnect(Sender: TObject; ASocket: LongInt;
  var doaccept: Boolean);
begin
  if FActiveThreadRunning then
  begin
    doaccept := false;
    Log('Refusing new connection - already connected');
  end
  else
  begin
    doaccept := true;
    Log('Accepting new connection');
  end;
end;

constructor TGdbRspServer.Create(APort: Word; var aMDBGProxy : TMDBGProxy);
begin
  inherited Create(APort);
  OnConnect := @FAcceptConnection;
  OnConnectQuery := @FQueryConnect;
  FActiveThreadRunning := false;
  FMDBGProxy := aMDBGProxy;
end;

constructor TMdbgNetworkThread.Create(const ServerPort : word;var aMDBGProxy : TMDBGProxy);
begin
  inherited Create(False);
  FServerPort := ServerPort;
  FMDBGProxy := aMDBGProxy;
  FreeOnTerminate := True;
  SendDebug('MDB Network Thread Created');
end;

procedure TMdbgNetworkThread.Execute;
begin
  SendDebug('MDB Network Thread Executing');
  FRspServer := TGdbRspServer.Create(FServerPort,FMDBGProxy);
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

end.
