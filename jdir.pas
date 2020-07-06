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

}

const

  { Bdos Functions }
  SEARCH_FIRST      = $11;  { F_SFIRST - Bdos search for first file. }
  SEARCH_NEXT       = $12;  { F_SNEXT  - Bdos search for next file. }
  SET_DMA_ADDRESS   = $1A;  { F_DMAOFF - Bdos Set DMA Address function number}

  SEARCH_LAST       = $FF;  { No more files found on Bdos search for first and next. }

  { Debug Flags }
  DEBUG_GetFile     = False; { DEBUG - Print debug information for GetFile. }
  DEBUG_Bdos        = False; { DEBUG - Print debug information for all Bdos calls. }

type
  Str12             = String[12];
  FileRecord_Ptr    = ^FileRecord;
  FileRecord =
    record
      FileName    : Str12;          { File Name }
      UserNumber  : Integer;        { User Number }
      FileSize    : Integer;        { File size in KiloBytes }
      NextFile    : FileRecord_Ptr; { Next file pointer }
    end;
  AnyFCB            = Array[0..25] of Byte;
  AnyDMA            = Array[0..127] of Byte;

var
  DMA               : AnyDMA;
  FCB               : AnyFCB absolute $005C;
  FileList          : FileRecord_Ptr;
  NumberFiles       : Integer;
  scratch           : String[255];


{ Initialize Bdos DMA access. }
Procedure InitDMA;
var
  BdosReturn        : Byte;
begin
  BdosReturn := Bdos(SET_DMA_ADDRESS, Addr(DMA));
  if (DEBUG_Bdos) then
      WriteLn('Set DMA Return: ', BdosReturn);
end;

{ Initialize the FCB used to search for files. }
Procedure InitFCB;
var
  LoopIdx           : Byte;

begin
  { Set the disk to Default. }
  FCB[0] := 0;

  { Set the file name and type to all '?'. }
  for LoopIdx := 1 to 11 do
    FCB[LoopIdx] := ord('?');

  { Set the rest of the FCB to 0. }
  for LoopIdx := 12 to SizeOf(FCB) do
    FCB[LoopIdx] := 0;
end;

{ Add a file to the existing list of files. }
{ The files are sorte by name. }
{ NOTE: This is using a simple insertion sort. }
Procedure AddFile(var NewFile : FileRecord_Ptr);
var
  FilePtr : FileRecord_Ptr;
  NextPtr : FileRecord_Ptr;

begin
  if (FileList = Nil) then
    { First file in the list. }
    FileList := NewFile
  else begin
    { Scan the file list looking for a place the new file fits. }
    FilePtr := FileList;
    While (FilePtr <> Nil) do begin
      NextPtr := FilePtr^.NextFile;
      if (NextPtr = Nil) then begin
        { Reached the end of the list. Append the new file. }
        FilePtr^.NextFile := NewFile;
        FilePtr := Nil;
      end else begin
        if (NewFile^.FileName < NextPtr^.FileName) then begin
          { Found where the file belings. }
          if (FileList = FilePtr) then begin
            FileList := NewFile;
            NewFile^.NextFile := FilePtr;
          end else begin
            FilePtr^.NextFile := NewFile;
            NewFile^.NextFile := NextPtr;
          end; { if (FileList = FilePtr) }
          FilePtr := Nil;
        end else begin
          { Move on to the next file in the list. }
          FilePtr := NextPtr;
        end; { if (NewFile^.FileName < NextPtr^.FileName) }
      end; { if (FilePtr^.NextFile = Nil) }
    end; { While (FilePtr <> Nil) }
  end; { if (FileList = Nil) }
end; { Procedure AddFile }

{ Get a file entry from Bdos. }
Function GetFile(
      BdosFunction  : Byte;
  var FCB           : AnyFCB;
  var DMA           : AnyDMA
) : byte;

var
  LoopIdx           : Byte;
  FirstByte         : Byte;
  BdosReturn        : Byte;
  NewFile           : FileRecord_Ptr;

begin
  BdosReturn := Bdos(BdosFunction, Addr(FCB));
  if (DEBUG_Bdos) then
    WriteLn('GetFile Bdos Return: ', BdosReturn);

  if (BdosReturn <> SEARCH_LAST) then begin
    { First byte of the file name in memory. }
    FirstByte := BdosReturn * 32;

    { Create the next file entry. }
    NumberFiles := NumberFiles + 1;
    New(NewFile);
    with NewFile^ do begin
      UserNumber := DMA[FirstByte];;

      { Get the file name. }
      FileName[0] := Chr(12);
      for LoopIdx := 1 to 8 do
        FileName[LoopIdx] := Chr(DMA[FirstByte + LoopIdx]);

      { Get the File Type. }
      FileName[9] := '.';
      for LoopIdx := 9 to 11 do
        FileName[Succ(LoopIdx)] := Chr(DMA[FirstByte + LoopIdx]);

      NextFile := Nil;

      if (DEBUG_GetFile) then begin
        WriteLn('User Number: ', UserNumber);
        WriteLn('File Name: ', FileName);
      end; { if (DEBUG_GetFile) }
    end; { with NewFile^ }

    { Add this file to the list. }
    AddFile(NewFile);
  end; { if (Get_File <> SEARCH_LAST) }
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
  BdosFunction := SEARCH_FIRST;
  Repeat
    BdosReturn := GetFile(BdosFunction, FCB, DMA);
    if (DEBUG_GetFile) then
        WriteLn('GetFile Return: ', BdosReturn);
    BdosFunction := SEARCH_NEXT;
  Until BdosReturn = SEARCH_LAST;

end; { Procedure GetFileList }

{ Print out the files that have been found. }
Procedure PrintFiles;
var
  FilePtr   : FileRecord_Ptr;

  rows      : Integer;

begin
  FilePtr := FileList;
  While (FilePtr <> Nil) do begin
    with FilePtr^ do begin
      WriteLn('File Name: ', FileName);
      FilePtr := NextFile;
    end; { with FilePtr^ }
  end; { While (FilePtr <> Nil) }


  Rows := NumberFiles div 4;
  if ((NumberFiles mod Rows) > 0) then
    Rows := Rows + 1;

end; { Procedure PrintFiles }


begin
  InitDMA;
  InitFCB;

  GetFileList;
  PrintFiles;
  Writeln('Found ', NumberFiles, ' files.');
end. { of program JDIR }
