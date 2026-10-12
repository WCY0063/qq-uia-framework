# =============================================================================
# selectors.psd1 - QQ control selector registry (single source of truth).
# Authority: docs/FRAMEWORK-DESIGN.md section 7
# Fact basis: README-QQNT-UIA.md section 3 (legacy doc, not in this repo)
# Verified against: QQNT 9.9.35-52892
#
# When a QQ upgrade moves a class name, edit ONLY this file. `doctor` probes
# every entry below and reports the misses as selectorHealth, so drift surfaces
# as a diagnosis instead of a silent wrong-target send.
#
# Matching semantics per entry:
#   Class  = .NET regex tested against AutomationElement.Current.ClassName
#            ('' means no class constraint).
#   Type   = .NET regex tested against ControlType.ProgrammaticName with the
#            'ControlType.' prefix removed. '' means any control type.
#   Stable = $false marks a selector observed to drift across QQ builds; such an
#            entry is probed and reported but never gates a task.
#
# ASCII-ONLY DATA. PowerShell 5.1 decodes a BOM-less file as ANSI, so any CJK
# character here (comments included) would corrupt parsing and silently break
# every selector. run-tests.ps1 enforces this rule for every shipped file.
# =============================================================================

@{
  Version    = '0.2.0'
  TargetApp  = 'QQNT 9.9.x'
  VerifiedOn = '9.9.35-52892'

  Window = @{
    Class       = 'Chrome_WidgetWin_1'
    ProcessName = 'QQ'
    # One QQ account can own several visible top-level windows (a 240x40 toast
    # next to the 2500x1500 main window). The main window is the only one that
    # carries the conversation UI, so the width floor separates them instead of
    # relying on EnumWindows order or on picking the largest window implicitly.
    MinWidth    = 400
  }

  # ---- account identity: multi-instance protection depends on these ----
  Identity = @{
    # Name carries '<nick><avatar-suffix>'; Get-QQAccountIdentity strips the suffix.
    Avatar       = @{ Class = 'user-avatar';      Type = 'Button'; Stable = $true;  Required = $true;  Note = 'Name = nick + avatar_suffix' }
    OnlineStatus = @{ Class = 'avatar__status';   Type = '';       Stable = $true;  Required = $false; Note = 'class contains icon-online when online' }
    AbnormalOnline = @{ Class = 'icon-electric';  Type = '';       Stable = $true;  Required = $false; Note = 'non-standard online state' }
    Nickname     = @{ Class = 'profile-nickname'; Type = 'Text';   Stable = $false; Required = $false; Note = 'fallback nickname source' }
    Signature    = @{ Class = 'profile_signature';Type = '';       Stable = $false; Required = $false; Note = 'Name carries a label prefix' }
  }

  # ---- navigation and search ----
  Nav = @{
    Sidebar     = @{ Class = 'sidebar-nav'; Type = '';   Stable = $true;  Required = $false }
    SearchWrap  = @{ Class = 'q-search';    Type = '';   Stable = $true;  Required = $false }
    # The only Edit control in the window; it carries a working ValuePattern.
    SearchInput = @{ Class = '';            Type = 'Edit'; Stable = $true; Required = $true; Note = 'ValuePattern write requires focus first' }
  }

  # ---- conversation list ----
  Sessions = @{
    List         = @{ Class = 'recent-contact-list';            Type = '';       Stable = $true;  Required = $true }
    Item         = @{ Class = 'recent-contact-item';            Type = '';       Stable = $true;  Required = $true }
    ItemSelected = @{ Class = 'recent-contact-item--selected';  Type = '';       Stable = $true;  Required = $false }
    ItemContent  = @{ Class = 'item__content';                  Type = '';       Stable = $true;  Required = $false }
    UnreadBadge  = @{ Class = 'q-badge';                        Type = '';       Stable = $true;  Required = $false; Note = 'Name = N + unread_suffix' }
    NoDisturb    = @{ Class = 'no-disturb-icon';                Type = '';       Stable = $true;  Required = $false }
  }

  # ---- search results ----
  Search = @{
    # Name: '<nick> (<QQ>) <source-label> ...' for contacts,
    #       '<group> (N<member-unit>) <contains-label> QQ' for groups,
    #       '<nick> N<records-label>' for chat history.
    # Anchored on purpose: the umbrella row's class ALSO contains
    # 'search-result-item' (it is 'global search-result-item'), so the unanchored
    # regex collected the umbrella row as if it were a hit and every consumer had
    # to filter it back out. With the anchor this selector yields real result rows
    # only; the umbrella row is collected through UmbrellaRow below and is STILL
    # filtered by its Name prefix through Test-QQComprehensiveSearchRow, so a build
    # that renames either class degrades to filter-by-name instead of losing the row.
    ResultItem  = @{ Class = '^search-result-item$'; Type = 'ListItem'; Stable = $true; Required = $false; Note = 'Name may be empty for the first contact row: match by position' }
    # The "search everything" row, the only row the 9.9.35 dropdown renders. Its own
    # selector because ResultItem is anchored and therefore cannot see it: without
    # this read there would be nothing to report in search.umbrellaEntry and nothing
    # for -Activate 1 to click. Required=$false: a build with real inline hits never
    # renders it, and a miss must not fail the check.
    UmbrellaRow = @{ Class = 'global search-result-item'; Type = 'ListItem'; Stable = $true; Required = $false; Note = 'the search-everything row; identified by the localized Name prefix as well' }
    # The comprehensive-search panel, opened by clicking the umbrella row. NOT
    # verified on 9.9.35: the tested keywords only ever rendered the umbrella row,
    # so the panel never appeared. Stable=$false and Required=$false, which keeps
    # doctor reporting a miss as optionalMiss and keeps the panel out of any gate.
    # A guessed container class may exist in the window even without a search
    # (hence the read is only ever used after the umbrella click, and the dismissal
    # check judges result rows, never the container).
    Panel       = @{ Class = 'search-panel|global-search-panel|q-search-panel'; Type = ''; Stable = $false; Required = $false; Note = 'unverified container of the comprehensive search panel (9.9.35 renders no panel); a miss must fall back to the dropdown rows' }
    # The panel reuses the dropdown's result-row class family; both known spellings
    # are listed because the panel's exact one is unverified. Rows are always read
    # scoped to the Panel container, so the dropdown's rows cannot leak in.
    PanelItem   = @{ Class = 'list-item search-result-item|global search-result-item'; Type = 'ListItem'; Stable = $false; Required = $false; Note = 'result row inside the comprehensive search panel: same class family as the dropdown row, scoped by its container; unverified' }
  }

  # ---- chat pane ----
  Chat = @{
    Header       = @{ Class = 'chat-header__contact-name'; Type = ''; Stable = $true;  Required = $true;  Note = 'the ONLY reliable answer to which chat is open' }
    MsgArea      = @{ Class = 'ml-area';                   Type = ''; Stable = $true;  Required = $true }
    MsgScroller  = @{ Class = 'ml-container';              Type = ''; Stable = $true;  Required = $false }
    Message      = @{ Class = '^message$';                 Type = ''; Stable = $true;  Required = $true }
    MsgSelf      = @{ Class = 'container--self|message-container--self';     Type = ''; Stable = $true; Required = $false; Note = '9.9.35 carries container--self, not the older message-container--self' }
    MsgOthers    = @{ Class = 'container--others|message-container--others'; Type = ''; Stable = $true; Required = $false }
    MsgContent   = @{ Class = 'msg-content-container';     Type = ''; Stable = $true;  Required = $false }
    MsgMeta      = @{ Class = 'avatar-span|message-container__name|message__user-name'; Type = ''; Stable = $true; Required = $false; Note = 'sender name and level badge: metadata, never message content' }
    MsgReplyQuote = @{ Class = 'reply-element';            Type = ''; Stable = $true;  Required = $false; Note = 'quoted text of a reply' }
    MsgTimestamp = @{ Class = 'message__timestamp';        Type = ''; Stable = $true;  Required = $false; Note = 'Name = time text' }
    SenderLabel  = @{ Class = 'avatar-span';               Type = ''; Stable = $true;  Required = $false; Note = 'Name = sender nick' }
    GroupMembers = @{ Class = 'group-member-list';         Type = ''; Stable = $true;  Required = $false; Note = 'presence alone means this is a group chat' }
    FuncBar      = @{ Class = 'chat-func-bar';             Type = ''; Stable = $false; Required = $false }
  }

  # ---- input and send ----
  Editor = @{
    MsgInputWrap  = @{ Class = 'msg-input';              Type = '';       Stable = $true; Required = $false }
    Editor        = @{ Class = 'ExEditor-qq-msg-editor'; Type = '';       Stable = $true; Required = $true;  Note = 'contenteditable: TextPattern only, no ValuePattern' }
    EditorFocused = @{ Class = 'ProseMirror-focused';    Type = '';       Stable = $true; Required = $false }
    EditorEmpty   = @{ Class = 'is-empty';               Type = '';       Stable = $true; Required = $false }
    SendButton    = @{ Class = 'send-msg';               Type = 'Button'; Stable = $true; Required = $true;  Note = 'Name = send_button_label' }
  }

  # ---- message kinds, read path only. First match wins, so order matters. ----
  # Matched against the classes inside a message's content box.
  MessageKinds = @(
    @{ Kind = 'image';       Match = 'mix-message__container--pic|pic-element'; Stable = $false; Note = 'the inner img class is randomized per build; the pic-element wrapper is what we match' }
    @{ Kind = 'reply';       Match = 'reply-message__container';               Stable = $true }
    @{ Kind = 'file';        Match = 'file-message|file-element|normal-file';  Stable = $true }
    @{ Kind = 'market-face'; Match = 'market-face';                            Stable = $true }
    @{ Kind = 'face';        Match = 'face-element';                           Stable = $true }
    @{ Kind = 'video';       Match = 'video-element|video-message';            Stable = $false }
    @{ Kind = 'voice';       Match = 'voice-element|ptt-element';              Stable = $false }
    @{ Kind = 'card';        Match = 'ark-msg|ark-element';                    Stable = $true }
    @{ Kind = 'system';      Match = 'gray-tip';                               Stable = $true }
    @{ Kind = 'text';        Match = 'msg-content-container|text-element|mix-message'; Stable = $true }
  )
}
