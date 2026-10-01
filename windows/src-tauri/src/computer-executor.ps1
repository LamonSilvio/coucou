$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class CoucouInput {
 [StructLayout(LayoutKind.Sequential)] public struct Point { public int x,y; }
 [StructLayout(LayoutKind.Sequential)] public struct Mouse { public int dx,dy; public uint data,flags,time; public UIntPtr extra; }
 [StructLayout(LayoutKind.Sequential)] public struct Keyboard { public ushort vk,scan; public uint flags,time; public UIntPtr extra; }
 [StructLayout(LayoutKind.Explicit)] public struct Union { [FieldOffset(0)] public Mouse mouse; [FieldOffset(0)] public Keyboard keyboard; }
 [StructLayout(LayoutKind.Sequential)] public struct Input { public uint type; public Union union; }
 [DllImport("user32.dll")] public static extern uint SendInput(uint count, Input[] inputs, int size);
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr handle);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(Point point);
 [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr handle,uint flags);
 public static bool IsTarget(int x,int y,IntPtr target) { return GetAncestor(WindowFromPoint(new Point{x=x,y=y}),2)==target; }
 public static void Key(ushort vk,ushort scan,uint flags) { var i=new Input{type=1,union=new Union{keyboard=new Keyboard{vk=vk,scan=scan,flags=flags}}}; if(SendInput(1,new[]{i},Marshal.SizeOf(typeof(Input)))!=1) throw new Exception("Input denied"); }
 public static void MouseEvent(uint flags,int data=0) { var i=new Input{type=0,union=new Union{mouse=new Mouse{flags=flags,data=(uint)data}}}; if(SendInput(1,new[]{i},Marshal.SizeOf(typeof(Input)))!=1) throw new Exception("Input denied"); }
}
'@
$request = [Console]::In.ReadLine() | ConvertFrom-Json
$action = $request.action
$bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
if ($action.type -eq 'choose_image_path') {
 $dialog = New-Object System.Windows.Forms.SaveFileDialog
 $dialog.FileName = 'coucou-image.png'; $dialog.Filter = 'PNG image|*.png'; $dialog.OverwritePrompt = $true
 try { if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { [Console]::Out.Write($dialog.FileName) } } finally { $dialog.Dispose() }
 exit
}
function Point($p) {
 if ($null -eq $p.x -or $null -eq $p.y -or $p.x -lt 0 -or $p.y -lt 0 -or $p.x -ge $bounds.Width -or $p.y -ge $bounds.Height) { throw 'Invalid coordinates' }
 if (![CoucouInput]::IsTarget([int]$p.x,[int]$p.y,$target.MainWindowHandle)) { throw 'Coordinates target another application' }
 [CoucouInput]::SetCursorPos([int]$p.x,[int]$p.y) | Out-Null
}
if ($action.type -eq 'screenshot') {
 $bitmap = New-Object System.Drawing.Bitmap($bounds.Width,$bounds.Height)
 $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
 $stream = New-Object System.IO.MemoryStream
 try {
  $graphics.CopyFromScreen($bounds.X,$bounds.Y,0,0,$bitmap.Size)
  $bitmap.Save($stream,[System.Drawing.Imaging.ImageFormat]::Png)
  if ($stream.Length -gt 20000000) { throw 'Capture too large' }
  [Console]::Out.Write([Convert]::ToBase64String($stream.ToArray()))
 } finally { $stream.Dispose(); $graphics.Dispose(); $bitmap.Dispose() }
 exit
}
if ($action.type -eq 'wait') { Start-Sleep -Milliseconds 500; exit }
if (@('msedge','chrome','firefox') -notcontains $request.target) { throw 'Target not allowed' }
$target = Get-Process -Name $request.target | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (!$target) { throw 'Open configured browser first' }
[CoucouInput]::SetForegroundWindow($target.MainWindowHandle) | Out-Null
Start-Sleep -Milliseconds 350
if ([CoucouInput]::GetForegroundWindow() -ne $target.MainWindowHandle) { throw 'Target focus changed' }
$focused = [System.Windows.Automation.AutomationElement]::FocusedElement
if ($focused -and $focused.Current.IsPassword) { throw 'Password fields blocked' }
switch ($action.type) {
 'move' { Point $action }
 'click' { Point $action; if ($action.button -and @('left','right') -notcontains $action.button) { throw 'Unsupported button' }; $down=2; $up=4; if ($action.button -eq 'right') { $down=8; $up=16 }; [CoucouInput]::MouseEvent($down); [CoucouInput]::MouseEvent($up) }
 'double_click' { Point $action; for ($i=0;$i -lt 2;$i++) { [CoucouInput]::MouseEvent(2); [CoucouInput]::MouseEvent(4); Start-Sleep -Milliseconds 60 } }
 'type' { foreach ($c in $action.text.ToCharArray()) { [CoucouInput]::Key(0,[uint16]$c,4); [CoucouInput]::Key(0,[uint16]$c,6) } }
 'keypress' { $map=@{ENTER=13;TAB=9;ESC=27;ESCAPE=27;BACKSPACE=8;ARROWUP=38;ARROWDOWN=40;ARROWLEFT=37;ARROWRIGHT=39}; foreach ($key in $action.keys) { $vk=$map[$key.ToUpper()]; if (!$vk) { throw 'Unknown key' }; [CoucouInput]::Key($vk,0,0); [CoucouInput]::Key($vk,0,2) } }
 'scroll' { Point $action; $dy=[Math]::Max(-2000,[Math]::Min(2000,[int]$action.scroll_y)); $dx=[Math]::Max(-2000,[Math]::Min(2000,[int]$action.scroll_x)); [CoucouInput]::MouseEvent(2048,-$dy); [CoucouInput]::MouseEvent(4096,-$dx) }
 'drag' { if ($action.path.Count -lt 2 -or $action.path.Count -gt 50) { throw 'Invalid drag' }; foreach ($p in $action.path) { if ($p.x -lt 0 -or $p.y -lt 0 -or $p.x -ge $bounds.Width -or $p.y -ge $bounds.Height) { throw 'Invalid path' } }; Point $action.path[0]; [CoucouInput]::MouseEvent(2); try { foreach ($p in $action.path) { Point $p } } finally { [CoucouInput]::MouseEvent(4) } }
 default { throw 'Unsupported action' }
}
