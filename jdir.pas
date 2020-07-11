{ vim:set ts=2 sts=2 sw=2 }
program JDIR;

{

Jessica's Directory
2020-04-03 Version 0.1 First working output.
2020-04-04 Version 0.2 File list is sorted.

Learning Turbo Pascal and CP/M programming.

This is a conglomeration of the Tubo Pascal tutorial programs CPMDIR.PAS and
SORTDIR.PAS found on the Walnut Creek CDOM.

TODO:
  Output files in columns.
  Allow search patterns to be passed on the command line.
  Get the size of each file.
  Add an option to list system files.
  Configurable number of rows for pagination.
  Option for no pagination.

}

const
  { Bdos Functions. }
  BDOS_SET_DRIVE        = $0E; { DRV_SET  - Set the current drive. }
  BDOS_SEARCH_FIRST     = $11; { F_SFIRST - search for first file. }
  BDOS_SEARCH_NEXT      = $12; { F_SNEXT  - search for next file. }
  BDOS_CURRENT_DRIVE    = $19; { DRV_GET  - Get current drive. }
  BDOS_SET_DMA          = $1A; { F_DMAOFF - Set DMA Address function number. }
  BDOS_DISK_PARM        = $1F; { DRV_DPB  - Get the Disk Parameter Address. }

  { Bdos return codes. }
  BDOS_SEARCH_LAST      = $FF; { No more files found on Bdos search. }

  { Debug Flags }
  DEBUG_GetFile     = False; { DEBUG - Print debug information for GetFile. }
  DEBUG_Bdos        = False; { DEBUG - Print debug information for Bdos calls. }

type
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
      ExtentMasl      : Byte;    { exm - Extent mask, see later }
      BlocksOnDisk    : Integer; { dsm - (no. of blocks on the disc)-1 }
      DirOnDisk       : Integer; { drm - (no. of directory entries)-1 }
      Allocation0     : Byte;    { al0 - Directory allocation bitmap, first byte }
      Allocation1     : Byte;    { al1 - Directory allocation bitmap, second byte }
      ChecksumSize    : Integer; { cks - Checksum vector size, 0 for a fixed disc }
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
end;

{ Initialize the FCB used to search for files. }
Procedure InitFCB;
var
  LoopIdx           : Byte;

begin
  { Set the disk to Default. }
  FCB.Number := 0;

  { Set the file name and type to all '?'. }
  for LoopIdx := 1 to 11 do
    FCB.FileName[LoopIdx] :=  ord('?');

  { Set Extent, S1 and S2 to '?' as well. }
  FCB.Extent := ord('?');
  FCB.S1 := ord('?');
  FCB.S2 := ord('?');

  { Set everything else to 0. }
  FCB.Records := 0;
  for LoopIdx := 0 to 15 do
    FCB.Allocation[LoopIdx] := 0;
end;

{ Get the currently logged disk. }
{ Returns the drive number. A = 0, B = 1 ... }
Function GetDisk : Byte;
begin
  GetDisk := Bdos(BDOS_CURRENT_DRIVE);
end;

{ Get the block size for the currently logged disk. }
Function GetBlockSize : Byte;
var
  DiskParmBlock_Ptr : ^DiskParmBlock;
begin
  DiskParmBlock_Ptr := Ptr(BdosHL(BDOS_DISK_PARM));
  GetBlockSize := Succ(DiskParmBlock_Ptr^.BlockMask) shr 3;
end;

{ Add a file to the existing list of files. }
{ The files are sorte by name. }
{ NOTE: This is using a simple insertion sort. }
Procedure AddFile(var NewFile : FileRecord_Ptr);
var
  FilePtr : FileRecord_Ptr;
  PrevPtr : FileRecord_Ptr;

begin
  if (FileList = Nil) then begin
    FileList := NewFile;
    NumberFiles := 1;
  end else begin
    PrevPtr := Nil;
    FilePtr := FileList;
    while ((FilePtr <> Nil) and (FilePtr^.FileName < NewFile^.FileName)) do
    begin
      PrevPtr := FilePtr;
      FilePtr := FilePtr^.NextFile;
    end;
    if (FilePtr^.FileName <> NewFile^.FileName) then begin
      NewFile^.NextFile := FilePtr;
      NumberFiles := Succ(NumberFiles);
      if (PrevPtr = Nil) then
        FileList := NewFile
      else
        PrevPtr^.NextFile := NewFile;
    end else if (FilePtr^.FileSize < NewFile^.FileSize) then
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

{ Print out the files that have been found. }
Procedure PrintFiles;
var
  FilePtr   : FileRecord_Ptr;
  Rows      : Integer;

begin
  FilePtr := FileList;
  While (FilePtr <> Nil) do begin
    with FilePtr^ do begin
      WriteLn('File Name: ', FileName, ' (', FileSize, 'k)');
      FilePtr := NextFile;
    end; { with FilePtr^ }
  end; { While (FilePtr <> Nil) }


{
  Rows := NumberFiles div 4;
  if ((NumberFiles mod Rows) > 0) then
    Rows := Succ(Rows);
}

  Writeln('Found ', NumberFiles, ' files.');

end; { Procedure PrintFiles }


begin
  InitDMA;
  InitFCB;

  BlockSize := GetBlockSize;
  if (BlockSize = 0) then
    BlockSize := 1;
  GetFileList;
  PrintFiles;
end. { of program JDIR }
