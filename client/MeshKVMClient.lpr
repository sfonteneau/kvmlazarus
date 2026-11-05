program MeshKVMClient;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces, Forms, Dialogs, SysUtils, kvm_cli, kvm_view_form;

var
  MainForm: TKvmViewForm;
  Options: TKvmClientOptions;
  ErrorText: string;
  ShowHelp: Boolean;
begin
  Application.Initialize;
  if not ParseClientOptions(Options, ErrorText, ShowHelp) then
  begin
    MessageDlg('Parametres MeshKVM incorrects',
      ErrorText + LineEnding + LineEnding + ClientUsage, mtError, [mbOK], 0);
    Halt(2);
  end;
  if ShowHelp then
  begin
    MessageDlg('MeshKVMClient - aide', ClientUsage, mtInformation, [mbOK], 0);
    Halt(0);
  end;
  Application.Title := 'MeshKVM';
  Application.CreateForm(TKvmViewForm, MainForm);
  MainForm.ApplyOptions(Options);
  Application.Run;
end.
