#!/usr/bin/env python3
"""Structure-only startup checks; FPC/LCL runtime validation is separate."""
from pathlib import Path
import re
root = Path(__file__).resolve().parents[1]
cli = (root / 'shared/kvm_cli.pas').read_text(encoding='utf-8')
gui = (root / 'client/kvm_view_form.pas').read_text(encoding='utf-8')
app = (root / 'client/MeshKVMClient.lpr').read_text(encoding='utf-8')
assert 'AutoControl: Boolean' in cli
assert 'Maximized: Boolean' in cli
assert 'Options.AutoControl := False;' in cli, 'control must remain opt-in'
assert 'Options.Maximized := True;' in cli
assert "A = '--control'" in cli and 'Options.AutoControl := True' in cli
assert "A = '--windowed'" in cli and 'Options.Maximized := False' in cli
assert "A = '--maximized'" in cli
assert 'MainForm.ApplyOptions(Options);' in app
assert 'if Options.Maximized then WindowState := wsMaximized' in gui
assert 'else WindowState := wsNormal;' in gui
assert 'FAutoControl := Options.AutoControl;' in gui
assert 'FAutoControlPending := FAutoControl;' in gui
assert 'FAutoControlPending := False;' in gui
body = gui.split('procedure TKvmViewForm.TryAutoRequestControl;', 2)[-1]
body = body.split('procedure TKvmViewForm.WindowDeactivated', 1)[0]
for guard in ('not FAutoControlPending', 'not FAuthorized', 'not FRemoteControl',
              'FDesktopPaused', 'not FControl.Enabled',
              '(FSocket=nil)', '(FSocket.WebSockets=nil)'):
    assert guard in body, guard
assert 'FControl.OnClick := nil;' in body, 'programmatic check must not trigger a second G'
assert 'FControl.OnClick := SavedClick;' in body
assert 'FControl.Checked := True;' in body
assert 'ControlClick(nil);' in body
assert "SendPacket('G');" not in body, 'reuse the existing authorized click path'
assert gui.count('TryAutoRequestControl;') == 3, 'declaration, implementation and timer call'
assert 'TryAutoRequestControl; // AUTH and desktop state have both been processed.' in gui
assert 'if not FAuthorized then Exit;' in gui
assert "else if TextMsg = 'OK VIEW'" in gui
assert "else if TextMsg = 'CTRL BUSY'" in gui
assert 'FControl.Checked := False;' in gui
assert 'SavedClick := FControl.OnClick;' in body
assert 'FAutoControlPending := False; // one request per connection' in body
assert 'FControlGranted := not FDesktopPaused;' in gui, 'grant still belongs to server reply'
print('PASS: client startup maximize and opt-in server-authorized exclusive control (source checks only)')
