# Non-invasive structural extraction from the live QQ UI tree (Chromium accessibility bridge).
# Reads class names / roles / patterns only. Launches or stops nothing.
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

function Dump-Structure {
  param([int]$PidTarget, [string]$Tag)
  $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $PidTarget)
  $wins = [System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)
  foreach ($w in $wins) {
    $all = $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    if ($all.Count -lt 50) { continue }
    Write-Host "`n############ $Tag (pid $PidTarget) $($all.Count) nodes ############" -ForegroundColor Magenta

    Write-Host "`n-- MESSAGE-RELATED nodes (raw class / type / name) --" -ForegroundColor Cyan
    $msgCls = 'message$|^message |message-container|msg-content-container|ml-area|ml-container|chat-msg-area|pic-element|file-element|normal-file|file-message|market-face|face-element|ark-msg|mix-message|image-element|video-element|voice|bubble|gray-tip'
    $all | Where-Object { $_.Current.ClassName -match $msgCls } | Select-Object -First 60 | ForEach-Object {
      $t = $_.Current.ControlType.ProgrammaticName.Replace('ControlType.','')
      $nm = $_.Current.Name; if ($nm.Length -gt 52) { $nm = $nm.Substring(0,52) + '..' }
      $ok = ''
      try { $ok = [int]$_.Current.BoundingRectangle.Width } catch { $ok = '?' }
      Write-Host ("  [{0,-9}] cls={1,-58} name=`"{2}`" w={3}" -f $t, $_.Current.ClassName, $nm, $ok)
    }

    Write-Host "`n-- IMAGE elements with non-trivial names --" -ForegroundColor Cyan
    $all | Where-Object { $_.Current.ControlType.ProgrammaticName -match 'Image' -and $_.Current.Name -ne '' } | Select-Object -First 15 | ForEach-Object {
      Write-Host ("  cls={0,-45} name=`"{1}`"" -f $_.Current.ClassName, $_.Current.Name)
    }

    Write-Host "`n-- '戳一戳' / gray-tip / hyperlink structure --" -ForegroundColor Cyan
    $all | Where-Object { $_.Current.Name -match '戳|揉了揉|拍了拍|的猫耳朵|的脑袋|的呆毛|的FPGA' -or $_.Current.ClassName -match 'gray-tip' } | Select-Object -First 25 | ForEach-Object {
      $t = $_.Current.ControlType.ProgrammaticName.Replace('ControlType.','')
      Write-Host ("  [{0,-9}] cls={1,-45} name=`"{2}`"" -f $t, $_.Current.ClassName, $_.Current.Name)
    }

    Write-Host "`n-- input / editor area --" -ForegroundColor Cyan
    $all | Where-Object { $_.Current.ClassName -match 'ExEditor|ProseMirror|msg-input|send-msg|operation|q-search' -or $_.Current.ControlType.ProgrammaticName -match 'Edit' } | Select-Object -First 15 | ForEach-Object {
      $t = $_.Current.ControlType.ProgrammaticName.Replace('ControlType.','')
      $vp = ''
      try { $o=$null; if ($_.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern,[ref]$o)) { $vp='Value' } } catch {}
      $tp = ''
      try { $o=$null; if ($_.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern,[ref]$o)) { $tp='Text' } } catch {}
      Write-Host ("  [{0,-9}] cls={1,-50} name=`"{2}`" [{3}{4}]" -f $t, $_.Current.ClassName, $_.Current.Name, $vp, $tp)
    }

    Write-Host "`n-- conversation list items --" -ForegroundColor Cyan
    $li = @($all | Where-Object { $_.Current.ClassName -match 'recent-contact-item|group-user' })
    Write-Host ("  count: {0}" -f $li.Count)
    $li | Select-Object -First 4 | ForEach-Object {
      $kids = @()
      try {
        $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
        $c = $walker.GetFirstChild($_)
        while ($c -ne $null -and $kids.Count -lt 8) { if ($c.Current.Name) { $kids += "$($c.Current.ControlType.ProgrammaticName.Replace('ControlType.','')):$($c.Current.Name)" }; $c = $walker.GetNextSibling($c) }
      } catch {}
      Write-Host ("    cls={0} selected={1}" -f $_.Current.ClassName, ($_.Current.ClassName -match 'selected'))
      Write-Host ("      children: {0}" -f ($kids -join ' | '))
    }
  }
}

Dump-Structure -PidTarget 11004 -Tag 'USER INSTANCE (main, logged in)'
