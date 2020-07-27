{ vim:set ts=2 sts=2 sw=2 }
program JDIR;

{

Jessica's Directory
2020-04-03 First working output.
2020-04-04 File list is sorted.
2020-07-11 Reorganized variables and types.
           File size is now calculated correctly.
           Output in columns order by row, PrintFilesRow.
           Output in columns order by column, PrintFilesColumn.
           Made output format configurable.
           Added Pagination of output.
2020-07-19 Use a pattern given on the command line.
2020-07-26 The pattern can specify the disk and/or user.

Learning Turbo Pascal and CP/M programming.

This is a conglomeration of the Tubo Pascal tutorial programs CPMDIR.PAS along
the files TDIR.PAS and SORTDIR.PAS found on the Walnut Creek CDOM.

TODO:
  Add an option to list system files.
  Configurable number of rows for pagination.
  Option for no pagination.
}

const
  { Configuration }
  OUTPUT_BY_COLUMN      = True; { True output by column, False by row. }
  PAGE_SIZE             = 22;   { Number of rows per-page. }
                                { Set to 0 for no pagination. }
  PARAM_LENGTH          = 32;   { Maximum length of the parameter string. }

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
  DMA               : array [0..3] of FCBDIR;
  FCB               : FCBDIR absolute $005C;
  FileList          : FileRecord_Ptr;
  NumberFiles       : Integer;
  scratch           : String[255];
  BlockSize         : Byte;


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
  if (DEBUG_Parms) then
    WriteLn('Switching to User: ', User);
  Bdos(BDOS_GET_SET_USER, User);
end;

{ Update the FCB with a pattern from the command line. }
Procedure UpdateFCB(ParamNum : Integer);
var
  Parameter   : ParamString;
  Disk        : Char;
  User        : Integer;
  FileName    : String[8];
  FileType    : String[3];
  Index       : Byte;
begin
  Parameter := ParamStr(ParamNum);
  FileName  := '';
  FileType  := '';
  Disk      := ' ';

  if (DEBUG_Parms) then
    WriteLn('Parameter: >', Parameter, '<');

  { Check for a Disk and/or User. }
  Index := Pos(':', Parameter);
  if (Index <> 0) then begin
    Disk := Copy(Parameter, 1, 1);
    Disk := Upcase(Disk);
    if (Disk in ['A'..'P']) then begin
      WriteLn('Parameter Disk: ', Disk);
      FCB.Number := Ord(Disk) - $40;
      Delete(Parameter, 1, 1);
      Index := Index - 1;
    end;
    if (Index > 1) then begin
      User := Ord(Copy(Parameter, 1, 1)) - $30;
      if (Index > 2) then
        User := (User * 10) + Ord(Copy(Parameter, 2, 1)) - $30;
      if (User < 16) then
        SetUser(User);
    end;
    Delete(Parameter, 1, Index);
    if (DEBUG_Parms) then
      WriteLn('New Parameter: >', Parameter, '<');
  end; { if (Index <> 0) }

  writeln('Parameter: >', Parameter, '< User: ', User);

  { Extract a file pattern from the parameter. }
  { The FCB is already setup to fetch all files so skip '*' and '*.*'. }
  if ((Parameter <> '*') and (Parameter <> '*.*') and (Parameter <> '' )) then begin
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
      FileType := PaddStr(Copy(FileType, 1, (Index - 1)), '?', 8)
    else if (length(FileType) > 0) then
      FileType := PaddStr(FileType, ' ', 8);

    { Copy the FileName and FileType to the FCB. }
    for Index := 1 to Length(FileName) do
      FCB.FileName[Index] := Ord(Upcase(FileName[Index]));
    for Index := 1 to Length(Filetype) do
      FCB.FileName[Index + 8] := Ord(Upcase(FileType[Index]));

    if (DEBUG_Parms) then begin
      WriteLn('File Name: >', FileName, '< Type: >', FileType, '<');
      Write('FCB File Name: >');
      for Index := 1 to 11 do
        Write(Chr(FCB.FileName[Index]));
      WriteLn('<');
    end;
  end; { if ((Parameter <> '*') and (Parameter <> '*.*')) }
end;

{ Get the currently logged disk. }
{ Returns the drive number. A = 0, B = 1 ... }
Function GetDisk : Byte;
begin
  GetDisk := Bdos(BDOS_CURRENT_DRIVE);
end; { Function GetDisk }

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
    end; { with NewFile^ }

    { Add this file to the list. }
    AddFile(NewFile);
  end; { if (Get_File <> BDOS_SEARCH_LAST) }
  GetFile := BdosReturn;
end; { Function GetFile }

Procedure GetFileList;
var
  BdosFunction  : Byte;
  BdosReturn    : Byte;

begin
  { Initialize the list of files. }
  FileList := Nil;
  NumberFiles := 0;

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

{ Print out the files that have been found by row. }
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
        Row := Succ(Row);
      end else
        Write('| ');
    end; { with FilePtr^ }
    if ((PAGE_SIZE > 0) and ((Row mod PAGE_SIZE) = 0)) then begin
      PromptAnyKey;
      Row := Succ(Row);
    end;
  end; { While (FilePtr <> Nil) }

  if ((Column mod 4) <> 0) then
    WriteLn;

  Writeln('Files: ', NumberFiles, ' ', TotalKBytes, 'k');
end; { Procedure PrintFiles }

{ Print out the files that have been found by Column. }
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
    if ((PAGE_SIZE > 0) and ((Row mod PAGE_SIZE) = 0)) then begin
      PromptAnyKey;
    end;
  end; { for Row := 1 to Rows }

  Writeln('Files: ', NumberFiles, ' ', TotalKBytes, 'k');
end; { Procedure PrintFilesColumn }

begin
  InitDMA;
  InitFCB;

  { Check if there is a parameter. }
  if (ParamCount >= 1) then
    UpdateFCB(1);

  BlockSize := GetBlockSize;
  { CPM for OS X does not set the block size. }
  if (BlockSize = 0) then BlockSize := 1;

  GetFileList;
  if (NumberFiles = 0) then
    WriteLn('No files found.')
  else if (OUTPUT_BY_COLUMN and (NumberFiles > 4)) then
    PrintFilesColumn
  else
    PrintFilesRow;
end. { Program JDIR }
