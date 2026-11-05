#!/usr/bin/env python3
"""Source-level guards for the detachable controls. Not an LCL GUI test."""
from pathlib import Path
p = Path(__file__).resolve().parents[1] / 'client' / 'kvm_view_form.pas'
s = p.read_text(encoding='utf-8')
assert 'FTop.Align := alNone;' in s
assert 'FTop.Align := alTop;' not in s
assert 'FView.Align := alClient;' in s
assert 'FTop.BringToFront;' in s
assert 'FMenuButton.BringToFront;' in s
assert 'FMenuButton.Visible := FAuthorized;' in s
assert 'FMenuButton.OnClick := @MenuClick;' in s
assert s.count('SetCommandsVisible(False);') >= 2, 'Auto-hide after both AUTH outcomes'
assert 'if not FClosing then SetCommandsVisible(True);' in s, 'Controls return after disconnect'
assert 'if Key = VK_F8 then' in s[s.index('procedure TKvmViewForm.RemoteKeyDown'):], 'Local F8 handler'
assert 'if Key = VK_F8 then' in s[s.index('procedure TKvmViewForm.RemoteKeyUp'):], 'No remote F8 keyup'
assert "if FAuthorized and FControlGranted then SendPacket('Z');" in s, 'Release held keys on opening menu'
assert "Caption := 'MeshKVM | '" in s, 'Status remains visible when menu hidden'
print('PASS: 13 checks for overlay structure and session behavior (not compiled)')
