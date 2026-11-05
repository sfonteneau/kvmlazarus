unit kvm_quartz_api;

{$mode objfpc}{$H+}{$packrecords c}

interface

{$IFNDEF DARWIN}
  {$FATAL kvm_quartz_api requires macOS}
{$ENDIF}

{$linkframework CoreGraphics}
{$linkframework ApplicationServices}
{$linkframework CoreFoundation}

uses ctypes;

type
  TCGPoint = record
    X, Y: Double;
  end;
  TCGSize = record
    Width, Height: Double;
  end;
  TCGRect = record
    Origin: TCGPoint;
    Size: TCGSize;
  end;

function CGGetActiveDisplayList(Max: CUInt; Displays, Count: PCUInt): CInt;
  cdecl; external name '_CGGetActiveDisplayList';
function CGDisplayPixelsWide(DisplayID: CUInt): NativeUInt;
  cdecl; external name '_CGDisplayPixelsWide';
function CGDisplayPixelsHigh(DisplayID: CUInt): NativeUInt;
  cdecl; external name '_CGDisplayPixelsHigh';
procedure CGEventSetFlags(Event: Pointer; Flags: QWord);
  cdecl; external name '_CGEventSetFlags';
procedure CGEventSetIntegerValueField(Event: Pointer; Field: CUInt; Value: Int64);
  cdecl; external name '_CGEventSetIntegerValueField';
function CGMainDisplayID: CUInt; cdecl; external name '_CGMainDisplayID';
function CGPreflightScreenCaptureAccess: Boolean; cdecl;
  external name '_CGPreflightScreenCaptureAccess';
function CGRequestScreenCaptureAccess: Boolean; cdecl;
  external name '_CGRequestScreenCaptureAccess';
function CGDisplayBounds(DisplayID: CUInt): TCGRect; cdecl;
  external name '_CGDisplayBounds';
function CGEventCreate(Source: Pointer): Pointer; cdecl;
  external name '_CGEventCreate';
function CGEventGetLocation(Event: Pointer): TCGPoint; cdecl;
  external name '_CGEventGetLocation';
function CGEventCreateMouseEvent(Source: Pointer; EventType: CUInt;
  Position: TCGPoint; Button: CUInt): Pointer; cdecl;
  external name '_CGEventCreateMouseEvent';
function CGEventCreateKeyboardEvent(Source: Pointer; KeyCode: Word;
  KeyDown: Boolean): Pointer; cdecl;
  external name '_CGEventCreateKeyboardEvent';
function CGEventCreateScrollWheelEvent(Source: Pointer; Units,
  WheelCount: CUInt; Wheel1: CInt): Pointer; cdecl; varargs;
  external name '_CGEventCreateScrollWheelEvent';
procedure CGEventKeyboardSetUnicodeString(Event: Pointer;
  StringLength: NativeUInt; UnicodeString: PWord); cdecl;
  external name '_CGEventKeyboardSetUnicodeString';
procedure CGEventPost(Tap: CUInt; Event: Pointer); cdecl;
  external name '_CGEventPost';
procedure CFRelease(Obj: Pointer); cdecl; external name '_CFRelease';
function AXIsProcessTrusted: Boolean; cdecl;
  external name '_AXIsProcessTrusted';

implementation
end.
