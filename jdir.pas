{ Jessica's Directory }
program JDIR;

const
  { Configuration }
  OUTPUT_BY_COLUMN      = True; { True output by column, False by row. }
  PAGE_SIZE             = 22;   { Number of rows per-page. }
                                { Set to 0 for no pagination. }
  PARAM_LENGTH          = 32;   { Maximum length of the parameter string. }
                                { This is an arbitrary value. }

  { Bdos Functions. }
  BDOS_SET_DRIVE        = $0E; { DRV_SET  - Set the current drive. }
  BDOS_SEARCH_FIRST     = $11; { F_SFIRST - search for first file. }
  BDOS_SEARCH_NEXT      = $12; { F_SNEXT  - search for next file. }
  BDOS_CURRENT_DRIVE    = $19; { DRV_GET  - Get current drive. }
  BDOS_GET_SET_USER     = $20; { Get or set the current user. }
  BDOS_SET_DMA          = $1A; { F_DMAOFF - Set DMA Address function number. }
  BDOS_DISK_PARM        = $1F; { DRV_DPB  - Get the Disk Parameter Address. }

  { Bdos return codes. }
  BDOS_SEARCH_LAST      = $FF; { No more files found on Bdos search. }

  { Debug Flags }
  DEBUG_GetFile     = False; { Print debug information for GetFile. }
  DEBUG_Bdos        = False; { Print debug information for Bdos calls. }
  DEBUG_FCBParms    = False; { Print debug when updating the FCB. }
  DEBUG_Parms       = False; { Print debug when processing the parameters. }

type
  ParamString       = String[PARAM_LENGTH];
  FileRecord_Ptr    = ^FileRecord;
  FileRecord =
    record
      FileName    : String[12];
      UserNumber  : Byte;
      FileSize    : Integer;
      Records     : Integer;
      NextFile    : FileRecord_Ptr;
      System      : Boolean;
      ReadOnly    : Boolean;
    end;
  FCBDIR = { This is the format used for FCB and Directory Records. }
    record
      Number      : Byte;
      FileName    : array[1..11] of Byte;
      Extent      : Byte;
      S1          : Byte;
      S2          : Byte;
      Records     : Byte;
      Allocation  : array[0..15] of byte;
    end;
  DiskParmBlock =
    record
      SecorsPerTrack  : Integer; { spt - Number of 128-byte records per track }
      BlockShift      : Byte;    { bsh - Block shift. }
      BlockMask       : Byte;    { blm - Block mask. }
      ExtentMask      : Byte;    { exm - Extent mask, see later }
      BlocksOnDisk    : Integer; { dsm - (no. of blocks on the disc)-1 }
      DirOnDisk       : Integer; { drm - (no. of directory entries)-1 }
      Allocation0     : Byte;    { al0 - Directory allocation bitmap, first }
      Allocation1     : Byte;    { al1 - Directory allocation bitmap, second }
      ChecksumSize    : Integer; { cks - Checksum vector size }
                                 { ;No. directory entries/4, rounded up. }
      ReservedTracks  : Integer; { off - Offset, number of reserved tracks }
    end;

var
  { BDos and file settings. }
  DMA               : array [0..3] of FCBDIR;
  FCB               : FCBDIR absolute $005C;
  FileList          : FileRecord_Ptr;
  BlockSize         : Byte;

  { For pagination and showing the total file count. }
  NumberFiles       : Integer;

  { Command line paramter settings. }
  ByColumn          : Boolean;
  GetAllFiles       : Boolean;
  OneColumn         : Boolean;
  ShowSystem        : Boolean;
  PageSize          : Integer;

{ Initialize Bdos DMA access. }
Procedure InitDMA;
var
  BdosReturn        : Byte;
begin
  BdosReturn := Bdos(BDOS_SET_DMA, Addr(DMA));
  if (DEBUG_Bdos) then
      WriteLn('Set DMA Return: ', BdosReturn);
end; { Procedure InitDMA }

{ Initialize the FCB used to search for all files. }
Procedure InitFCB;
begin
  { Set the disk to Default. }
  FCB.Number := 0;

  { Set the file name and type to all '?'. }
  FillChar(FCB.FileName, 11, ord('?'));

  { Set Extent, S1 and S2 to '?' as well. }
  FCB.Extent := ord('?');
  FCB.S1 := ord('?');
  FCB.S2 := ord('?');

  { Set everything else to 0. }
  FCB.Records := 0;
  FillChar(FCB.Allocation, 16, 0);
end; { Procedure InitFCB }

{ Padd a string to Padlength with PaddChar. }
{ If the string is longer than PaddLength it is truncated. }
Function PaddStr(
  InputStr    : ParamString;
  PaddChar    : Char;
  PaddLength  : Byte
) : ParamString;
var
  OutputStr : ParamString;
  Index     : Byte;
begin
  OutputStr := InputStr;
  if (Length(InputStr) < PaddLength) then begin
    for Index := (Length(InputStr) + 1) to PaddLength do
      Insert(PaddChar, OutputStr, Index);
  end;
  OutputStr[0] := Chr(PaddLength);
  PaddStr := OutputStr;
end;

{ Set the current user. }
Procedure SetUser(User: Integer);
begin
  if (DEBUG_FCBParms) then
    WriteLn('Switching to User: ', User);
  Bdos(BDOS_GET_SET_USER, User);
end;

{ Update the FCB with a pattern from the command line. }
{ Destructively modifies Parameter. }
Procedure UpdateFCB(var Parameter : ParamString);
var
  Disk        : Char;
  User        : Integer;
  FileName    : String[8];
  FileType    : String[3];
  Index       : Byte;
begin
  FileName  := '';
  FileType  := '';
  Disk      := ' ';

  if (DEBUG_FCBParms) then
    WriteLn('Parameter: >', Parameter, '<');

  { Check for a Disk and/or User. }
  Index := Pos(':', Parameter);
  if (Index <> 0) then begin
    { Check for the Disk letter. }
    Disk := Upcase(Copy(Parameter, 1, 1));
    if (Disk in ['A'..'P']) then begin
      FCB.Number := Ord(Disk) - $40;
      { Delete the Disk letter. }
      Delete(Parameter, 1, 1);
      Index := Index - 1;
      if (DEBUG_FCBParms) then
        WriteLn('Parameter Disk: ', Disk);
    end;

    { Anything left will the the User number. }
    { I can't use Val since it messes with FCB. }
    if (Index > 1) then begin
      User := Ord(Copy(Parameter, 1, 1)) - $30;
      if (Index > 2) then
        User := (User * 10) + Ord(Copy(Parameter, 2, 1)) - $30;
      if (User < 16) then
        SetUser(User);
    end;
    Delete(Parameter, 1, Index);
    if (DEBUG_FCBParms) then
      WriteLn('New Parameter: >', Parameter, '<');
  end; { if (Index <> 0) }

  if (DEBUG_FCBParms) then
    writeln('Parameter: >', Parameter, '< User: ', User);

  { Extract a file pattern from the parameter. }
  { The FCB is already setup to fetch all files so skip '*' and '*.*'. }
  if ((Parameter <> '*') and (Parameter <> '*.*') and (Parameter <> '' )) then
  begin
    Index := Pos('.', Parameter);
    { If there is a '.' then get the file type. }
    if (Index > 0) then begin
      FileName := Copy(Parameter, 1, (Index - 1));
      FileType := Copy(Parameter, (Index + 1), Length(Parameter));
    end else
      FileName := Parameter;

    { Cleanup the FileName. }
    Index := Pos('*', FileName);
    if (Index <> 0) then
      FileName := PaddStr(Copy(FileName, 1, (Index - 1)), '?', 8)
    else
      FileName := PaddStr(FileName, ' ', 8);

    { Cleanup the FileType. }
    Index := Pos('*', FileType);
    if (Index <> 0) then
      FileType := PaddStr(Copy(FileType, 1, (Index - 1)), '?', 3)
    else if (length(FileType) > 0) then
      FileType := PaddStr(FileType, ' ', 3);

    { Copy the FileName and FileType to the FCB. }
    for Index := 1 to Length(FileName) do
      FCB.FileName[Index] := Ord(Upcase(FileName[Index]));
    for Index := 1 to Length(Filetype) do
      FCB.FileName[Index + 8] := Ord(Upcase(FileType[Index]));

    if (DEBUG_FCBParms) then begin
      WriteLn('File Name: >', FileName, '< Type: >', FileType, '<');
      Write('FCB File Name: >');
      for Index := 1 to 11 do
        Write(Chr(FCB.FileName[Index]));
      WriteLn('<');
    end;
  end; { if ((Parameter <> '*') and (Parameter <> '*.*')) }
end;

{ Get the block size for the currently logged disk. }
Function GetBlockSize : Byte;
var
  DiskParmBlock_Ptr : ^DiskParmBlock;
begin
  DiskParmBlock_Ptr := Ptr(BdosHL(BDOS_DISK_PARM));
  GetBlockSize := Succ(DiskParmBlock_Ptr^.BlockMask) shr 3;
end; { Function GetBlockSize }

{ Add a file to the existing list of files. }
{ The files are sorte by name. }
{ NOTE: This is using a simple insertion sort. }
Procedure AddFile(var NewFile : FileRecord_Ptr);
var
  FilePtr : FileRecord_Ptr;
  PrevPtr : FileRecord_Ptr;

begin
  if (FileList = Nil) then begin
    { This is the first file. }
    FileList := NewFile;
    NumberFiles := 1;
  end else begin
    PrevPtr := Nil;
    FilePtr := FileList;
    { Find where this file belongs. }
    while ((FilePtr <> Nil) and (FilePtr^.FileName < NewFile^.FileName)) do
    begin
      PrevPtr := FilePtr;
      FilePtr := FilePtr^.NextFile;
    end;
    if (FilePtr^.FileName <> NewFile^.FileName) then begin
      { Add the file to the list. }
      NewFile^.NextFile := FilePtr;
      NumberFiles := Succ(NumberFiles);
      if (PrevPtr = Nil) then
        FileList := NewFile
      else
        PrevPtr^.NextFile := NewFile;
    end else if (FilePtr^.FileSize < NewFile^.FileSize) then
      { This is not a new file, it's another directory entry. }
      FilePtr^.FileSize := NewFile^.FileSize;
  end; { if (FileList = Nil) }
end; { Procedure AddFile }

{ Get a file entry from Bdos. }
Function GetFile(BdosFunction  : Byte) : byte;
var
  FirstByte         : Byte;
  BdosReturn        : Byte;
  NewFile           : FileRecord_Ptr;
  Blocks            : Integer;
  BlockDivisor      : Integer;
  FileSize          : Integer;
  FileRecords       : Integer;

begin
  BdosReturn := Bdos(BdosFunction, Addr(FCB));
  if (DEBUG_Bdos) then
    WriteLn('GetFile Bdos Return: ', BdosReturn);

  if (BdosReturn <> BDOS_SEARCH_LAST) then begin
    { First byte of the file name in memory. }
    FirstByte := BdosReturn * 32;

    { Create the next file entry. }
    New(NewFile);
    with DMA[BdosReturn] do begin
      NewFile^.UserNumber := Number;

      { See if this is a system file. }
      if ((ord(FileName[10]) and $80) > 0) then begin
        NewFile^.System := True;
        FileName[10] := (FileName[10] and $7F) + $20;
      end else
        NewFile^.System := False;

      { See if this is Read Only. }
      if ((ord(FileName[9]) and $80) > 0) then begin
        NewFile^.ReadOnly := True;
        FileName[9] := (FileName[9] and $7F) + $20;
      end else
        NewFile^.ReadOnly := False;

      Number := 11; { Used for the file name length. }
      move(Number, NewFile^.FileName, 12);
      insert('.', NewFile^.FileName, 9);

      NewFile^.NextFile := Nil;

      { Calculate the file size. }
      { NOTE: This is messy, there has to be a better way. }
      FileRecords := Records + ((Extent + (S2 shl 5)) shl 7);
      BlockDivisor := BlockSize shl 3;
      Blocks := FileRecords div BlockDivisor;
      FileSize := Blocks * BlockSize;
      if ((FileRecords mod BlockDivisor) <> 0) then
        FileSize := FileSize + BlockSize;
      NewFile^.Records := FileRecords;
      NewFile^.FileSize := FileSize;

      if (DEBUG_GetFile) then begin
        WriteLn('User Number: ', Number);
        WriteLn('File Name: ', NewFile^.FileName);
      end; { if (DEBUG_GetFile) }
    end; { with DMA[BdosReturn] }

    { Add this file to the list. }
    { Only add if the file is not system or ShowSystem is set. }
    if (NOT NewFile^.System or ShowSystem) then
      AddFile(NewFile);
  end; { if (Get_File <> BDOS_SEARCH_LAST) }
  GetFile := BdosReturn;
end; { Function GetFile }

Procedure GetFileList;
var
  BdosFunction  : Byte;
  BdosReturn    : Byte;

begin
  { Get files as long as there are more to retrive. }
  BdosFunction := BDOS_SEARCH_FIRST;
  Repeat
    BdosReturn := GetFile(BdosFunction);
    if (DEBUG_GetFile) then
        WriteLn('GetFile Return: ', BdosReturn);
    BdosFunction := BDOS_SEARCH_NEXT;
  Until BdosReturn = BDOS_SEARCH_LAST;

end; { Procedure GetFileList }

{ Prompts the user to press any key. }
Procedure PromptAnyKey;
var
  Character   : Char;
begin
  Write('Pres any key to continue...');
  Read(Kbd, Character);
  WriteLn;
end;

{ Print out the files in one column. }
Procedure PrintFiles;
var
  FilePtr     : FileRecord_Ptr;
  TotalKBytes : Integer;
  Row         : Integer;

begin
  FilePtr := FileList;
  TotalKBytes := 0;
  Row := 1;

  While (FilePtr <> Nil) do begin
    with FilePtr^ do begin
      WriteLn(FileName, '', FileSize:4, 'k ');
      TotalKBytes := TotalKBytes + FileSize;
      FilePtr := NextFile;

      if (PageSize > 0) then
        if ((Row mod PageSize) = 0) then
          PromptAnyKey;
      Row := Succ(Row);
    end; { with FilePtr^ }
  end; { While (FilePtr <> Nil) }

  Writeln('Files: ', NumberFiles, ' ', TotalKBytes, 'k');
end; { Procedure PrintFilesColumn }

{ Print out the files in columns sorted by row. }
Procedure PrintFilesRow;
var
  FilePtr     : FileRecord_Ptr;
  TotalKBytes : Integer;
  Column      : Integer;
  Row         : Integer;

begin
  FilePtr := FileList;
  Column := 0;
  Row := 1;
  TotalKBytes := 0;

  While (FilePtr <> Nil) do begin
    with FilePtr^ do begin
      Write(FileName, '', FileSize:4, 'k ');
      TotalKBytes := TotalKBytes + FileSize;
      FilePtr := NextFile;

      { Check the column currently on. }
      Column := Succ(Column);
      if (Column = 4) then begin
        WriteLn;
        Column := 0;
        if (PageSize > 0) then
          if ((Row mod PageSize) = 0) then
            PromptAnyKey;
        Row := Succ(Row);
      end else
        Write('| ');
    end; { with FilePtr^ }
  end; { While (FilePtr <> Nil) }

  if ((Column mod 4) <> 0) then
    WriteLn;

  Writeln('Files: ', NumberFiles, ' ', TotalKBytes, 'k');
end; { Procedure PrintFiles }

{ Print out the files in columns sorted by column. }
Procedure PrintFilesColumn;
var
  FilePtr     : FileRecord_Ptr;
  TotalKBytes : Integer;
  Columns     : array[0..3] of FileRecord_Ptr;
  Column      : Byte;
  Rows        : Integer;
  Row         : Integer;

begin
  FilePtr := FileList;
  TotalKBytes := 0;

  { Calculate the number of rows. }
  Rows := NumberFiles div 4;
  if ((NumberFiles mod 4) <> 0) then
    Rows := Succ(Rows);

  { Set the pointer for each column. }
  Columns[0] := FilePtr;
  for Column := 1 to 3 do begin
    for Row := 1 to Rows do
      FilePtr := FilePtr^.NextFile;
    Columns[Column] := FilePtr;
  end;

  { Write out the rows. }
  for Row := 1 to Rows do begin
    for Column := 0 to 3 do begin
      if (Columns[Column] <> Nil) then
        with Columns[Column]^ do begin
          Write(FileName, '', FileSize:4, 'k ');
          TotalKBytes := TotalKBytes + FileSize;
          Columns[Column] := NextFile;
        end;
      if (Column < 3) then
        Write('| ');
    end; { for Column := 0 to 3 }
    WriteLn;
    if (PageSize > 0) then
      if ((Row mod PageSize) = 0) then
        PromptAnyKey;
  end; { for Row := 1 to Rows }

  Writeln('Files: ', NumberFiles, ' ', TotalKBytes, 'k');
end; { Procedure PrintFilesColumn }

{ Print the command line options. }
Procedure PrintUsage;
begin
  WriteLn('Usage: THIS_PROGRAM [Paramters] [File Patterns]');
  WriteLn('Lists files like DIR, but more like Unix ls.');
  WriteLn('Lists all files by default.');
  WriteLn('File patters work more line Unix wild cards.');
  WriteLn;
  WriteLn('Parameters:');
  WriteLn('  -- Start processing file patterns.');
  WriteLn('  -1 Display files in one column. ByColumn');
  WriteLn('  -a Include system files in the file list.');
  WriteLn('  -l Synonymous with -1.');
  WriteLn('  -n Do not paginate output. PageSize');
  WriteLn('  -x Display the file columns across rather than down. ByColumn');
  Halt;
end;

{ Process command line parameters. }
Procedure ProcessParameters;
var
  ParamNum    : Integer;
  Parameter   : ParamString;
  Option      : Char;
  Stop        : Boolean;
begin
  ParamNum := 1;
  Stop := False; { Stop processing Parameters. }

  { Fetch any command line parameters. }
  Repeat 
    Parameter := ParamStr(ParamNum);
    if (DEBUG_Parms) then
      WriteLn('Parameter: ', Parameter);
    if (Copy(Parameter, 1, 1) = '-') then begin
      Option := Upcase(Copy(Parameter, 2, 1));
      if (DEBUG_Parms) then
        WriteLn('Option: ', Option);
      Case Option  of
        '-': Stop := True;      { End of parameters, start of file patterns. }
        '1': OneColumn := True;
        'A': ShowSystem := True;
        'H': PrintUsage;
        'L': OneColumn := True;
        'N': PageSize := 0;
        'X': ByColumn := False;
      end;
      ParamNum := Succ(ParamNum);
    end else
      Stop := True;
  Until (Stop or (ParamNum > ParamCount));

  { Process any file patterns. }
  While (ParamNum <= ParamCount) do begin
    Parameter := ParamStr(ParamNum);
    if (DEBUG_Parms) then
      WriteLn('File Pattern: ', Parameter);
    GetAllFiles := False;
    InitFCB;
    UpdateFCB(Parameter);
    GetFileList;
    ParamNum := Succ(ParamNum);
  end;
end;

begin
  { Initialize global variables. }
  BlockSize := GetBlockSize;
  { CPM for OS X does not set the block size. }
  if (BlockSize = 0) then BlockSize := 1;
  ByColumn := OUTPUT_BY_COLUMN;
  FileList := Nil;
  GetAllFiles := True;
  NumberFiles := 0;
  OneColumn := False;
  PageSize := PAGE_SIZE;
  ShowSystem := False;

  { Prepare for the BDos calls. }
  InitDMA;

  { Check if there are command line parameters. }
  if (ParamCount >= 1) then
    ProcessParameters;

  { If there were no file patterns get all of the files. }
  if GetAllFiles then begin
    InitFCB;
    GetFileList;
  end;

  if (NumberFiles = 0) then
    WriteLn('No files found.')
  else if OneColumn then
    PrintFiles
  else if (ByColumn and (NumberFiles > 4)) then
    PrintFilesColumn
  else
    PrintFilesRow;
end. { Program JDIR }
