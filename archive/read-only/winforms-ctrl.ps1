Add-Type -AssemblyName System.Windows.Forms
$f = New-Object System.Windows.Forms.Form
$f.Text = 'DSH-CTRL2'; $f.Width = 400; $f.Height = 200; $f.StartPosition='Manual'; $f.Left=40; $f.Top=40
$b = New-Object System.Windows.Forms.Button
$b.Text = 'CTRL2-BUTTON'; $b.Left = 20; $b.Top = 20; $b.Width = 200; $b.Height = 50
$b.Add_Click({ $f.Text = 'DSH-CTRL2-CLICKED' })
$t = New-Object System.Windows.Forms.TextBox
$t.Text = 'ctrl-textbox'; $t.Left = 20; $t.Top = 90; $t.Width = 250
$f.Controls.Add($b); $f.Controls.Add($t)
$f.Show()
[System.Windows.Forms.Application]::Run($f)
