Mailroom = Mailroom or {}
local m = Mailroom

-- Mailroom needs ClassicAPI loaded; without it nothing below runs.
if type( CLASSIC_API_VERSION ) ~= "number" then
  DEFAULT_CHAT_FRAME:AddMessage( "|cffabd473Mailroom|r: requires ClassicAPI. Mailroom is turned off." )
  return
end


local ATTACHMENTS_MAX = 21
local ATTACHMENTS_PER_ROW_SEND = 7
local ATTACHMENTS_MAX_ROWS_SEND = 3

-- The attachment buttons (MailAttachment1 to 21), each looked up by name once.
local attachment_button = setmetatable( {}, { __index = function( t, i )
  local btn = _G[ "MailAttachment" .. i ]
  t[ i ] = btn
  return btn
end } )

-- Regions looked up by name once, at load: the seven inbox rows and the
-- autocomplete buttons.
local inbox_rows, complete_buttons = {}, {}
local AUTOCOMPLETE_BUTTONS = 5

local EVENTS = { "ADDON_LOADED", "PLAYER_LOGIN", "UI_ERROR_MESSAGE", "BAG_UPDATE_DELAYED", "UPDATE_PENDING_MAIL", "MAIL_SHOW", "MAIL_CLOSED", "MAIL_SEND_SUCCESS", "MAIL_FAILED", "MAIL_INBOX_UPDATE" }

-- Battleground marks counted in the inbox title. Extend the list to track
-- other items.
local MARKS = {
  { name = "Alterac Valley Mark of Honor", short = "AV" },
  { name = "Warsong Gulch Mark of Honor", short = "WSG" },
  { name = "Arathi Basin Mark of Honor", short = "AB" },
}
local MARK_SHORT = {}
for _, mark in ipairs( MARKS ) do
  MARK_SHORT[ mark.name ] = mark.short
end


-- Seconds between inbox fetches while a delete waits for the server.
Mailroom.DELETE_RETRY_INTERVAL = 3

-- Names ClassicAPI completes: group, guild, friends and whispers. Not Online:
-- offline players get mail too.
local AUTOCOMPLETE_FLAGS = Enum.AutoCompleteEntryFlag.InGroup + Enum.AutoCompleteEntryFlag.InGuild
    + Enum.AutoCompleteEntryFlag.Friend + Enum.AutoCompleteEntryFlag.InteractedWith

-- ClassicAPI's client-side lock greys a queued attachment in every bag addon.
-- It is only a look: the hooks below still keep queued items in place.
local location = {}
local function lock_item( item )
  location.bagID, location.slotIndex = item[ 1 ], item[ 2 ]
  C_Item.LockItem( location )
end
local function unlock_item( item )
  location.bagID, location.slotIndex = item[ 1 ], item[ 2 ]
  C_Item.UnlockItem( location )
end
Mailroom.orig = {}
Mailroom.hooks = {}
Mailroom.hook = setmetatable( {}, { __newindex = function( _, k, v ) m.hooks[ k ] = v end } )

-- Drop an autocomplete name once it has gone unseen this long.
Mailroom.AUTOCOMPLETE_MAX_AGE = 60 * 60 * 24 * 30

function Mailroom:init()
  self.update_frame = CreateFrame( "Frame", "MailroomFrame", MailFrame )

  self.update_frame:SetScript( "OnEvent", function() self[ event ]() end )
  for _, event in ipairs( EVENTS ) do
    self.update_frame:RegisterEvent( event )
  end

  Mailroom_AutoCompleteNames = {}

  -- inbox indices queued for deletion once the server confirms their take
  self.delete_queue = {}
end

---@param args string
function Mailroom.slash_command( args )
  if string.lower( args or "" ) == "clear names" then
    m.info( "Recipient autocomplete names have been cleared." )
    Mailroom_AutoCompleteNames[ m.names_key ] = {}
    m.sorted_names = nil
  else
    DEFAULT_CHAT_FRAME:AddMessage( "|cffabd473Mailroom commands|r" )
    DEFAULT_CHAT_FRAME:AddMessage( "|cffabd473/mr clear names|r Forget saved autocomplete names" )
  end
end

-- Work that must wait for the next frame (send queue, Open All) sets its flag
-- and calls wake(); on_update runs until none is left.
function Mailroom.wake()
  m.update_frame:SetScript( "OnUpdate", m.on_update )
end

function Mailroom.on_update()
  if not MailFrame:IsVisible() then return end

  if m.sendmail_update then
    m.sendmail_update = nil
    if m.sendmail_sending then
      m.sendmail_send()
    end
  end

  if m.inbox_update then
    m.inbox_update = false
    local _, _, _, _, _, COD, _, _, _, _, _, _, isGM = GetInboxHeaderInfo( m.inbox_index )
    if m.inbox_index > GetInboxNumItems() then
      if m.money_received > 0 then
        m.info( m.format_money( m.money_received ) .. " collected." )
      end
      if m.marks_received_total > 0 then
        local parts = {} -- vanillaforge-ignore: D2 (once, when Open All ends)
        for _, mark in ipairs( MARKS ) do
          if m.marks_received[ mark.name ] then
            table.insert( parts, m.marks_received[ mark.name ] .. "x " .. mark.name )
          end
        end
        m.info( "Collected " .. table.concat( parts, ", " ) .. "." )
      end
      m.inbox_abort()
      -- the server sends 50 mails at most; ask for the rest
      CheckInbox()
    elseif m.inbox_skip or COD > 0 or isGM then
      m.inbox_skip = false
      m.inbox_index = m.inbox_index + 1
      m.inbox_update = true
    else
      m.inbox_open( m.inbox_index )
    end
  end

  if not (m.sendmail_update or m.inbox_update) then
    m.update_frame:SetScript( "OnUpdate", nil )
  end
end

-- A delete waits for the server to confirm its take. While one waits, the
-- inbox is fetched again now and then, in case that update was missed.
function Mailroom.watch_deletes()
  if #m.delete_queue > 0 and not m.delete_ticker then
    m.delete_ticker = C_Timer.NewTicker( m.DELETE_RETRY_INTERVAL, m.inbox_refresh )
  end
end

function Mailroom.stop_watching_deletes()
  if m.delete_ticker then
    m.delete_ticker:Cancel()
    m.delete_ticker = nil
  end
end

function Mailroom.inbox_refresh()
  if #m.delete_queue == 0 then return m.stop_watching_deletes() end
  if not m.inbox_opening and MailFrame:IsVisible() then
    m.inbox_delete_pending()
    CheckInbox()
  end
end

-- New mail while the mailbox is open.
-- UNVERIFIED: test in game that UPDATE_PENDING_MAIL fires at an open mailbox
-- when mail arrives (have an alt mail you).
function Mailroom.UPDATE_PENDING_MAIL()
  if MailFrame:IsVisible() and not m.inbox_opening then
    CheckInbox()
  end
end

-- The bag item last picked up, while it is still on the cursor: the client
-- locks a picked-up item until it is put down.
function Mailroom.get_cursor_item()
  local item = m.cursorItem
  if item and CursorHasItem() and select( 3, GetContainerItemInfo( item[ 1 ], item[ 2 ] ) ) then
    return item
  end
end

---@param item table
function Mailroom.set_cursor_item( item )
  m.cursorItem = item
end

-- ClassicAPI fires this once per frame after any bag change. None on the
-- Inbox tab: switching to Send Mail refreshes it anyway.
function Mailroom.BAG_UPDATE_DELAYED()
  if SendMailFrame:IsVisible() then
    SendMailFrame_Update()
  end
end

function Mailroom.MAIL_SHOW()
  if not m.first_show then
    m.first_show = true
    local background = SendMailPackageButton:GetRegions()
    background:Hide()
    local count = select( 3, SendMailPackageButton:GetRegions() )
    count:Hide()
    SendMailPackageButton:Disable()
    SendMailPackageButton:SetScript( "OnReceiveDrag", nil )
    SendMailPackageButton:SetScript( "OnDragStart", nil )
  end

  m.money_received = 0
  m.update_money( 0 )
  m.marks_received, m.marks_received_total = {}, 0
  MailroomMarksReceived:Hide()
end

function Mailroom.MAIL_CLOSED()
  m.stop_watching_deletes()
  m.inbox_abort()
  m.delete_queue = {}
  m.sendmail_abort()
  StaticPopup_Hide( "MAILROOM_SEND_MONEY" )
  m.sendmail_clear()
  SendMailNameEditBox:ClearFocus()
end

function Mailroom.UI_ERROR_MESSAGE()
  if m.inbox_opening then
    if arg1 == ERR_INV_FULL then
      m.inbox_abort()
    elseif arg1 == ERR_ITEM_MAX_COUNT then
      m.inbox_skip = true
    end
  elseif m.sendmail_sending and (arg1 == ERR_MAIL_TO_SELF or arg1 == ERR_PLAYER_WRONG_FACTION or arg1 == ERR_MAIL_TARGET_NOT_FOUND or arg1 == ERR_MAIL_REACHED_CAP) then
    m.sendmail_abort()
  end
end

-- The native handler re-enables SendMailMailButton, which sendmail_load
-- replaced with a dummy, so the queue and the real button are released here.
-- Only a mail awaiting its result can fail; MAIL_FAILED from a send slot
-- click between mails must not cancel the rest of the queue.
function Mailroom.MAIL_FAILED()
  if m.sendmail_pending then
    m.sendmail_abort()
  else
    SendMailFrame_CanSend()
  end
end

function Mailroom.ADDON_LOADED()
  if arg1 ~= "Mailroom" then return end

  -- the mailbox and the friends list open side by side
  UIPanelWindows[ "MailFrame" ].pushable = 1
  UIPanelWindows[ "FriendsFrame" ].pushable = 2

  MailFrame:SetClampedToScreen( true )

  m.inbox_load()
  m.sendmail_load()
end

function Mailroom.PLAYER_LOGIN()
  for k, v in pairs( m.hooks ) do
    m.orig[ k ] = _G[ k ]
    _G[ k ] = v
  end
  -- autocomplete names are shared per realm and faction
  m.names_key = GetCVar( "realmName" ) .. "|" .. UnitFactionGroup( "player" )
  local key = m.names_key
  Mailroom_AutoCompleteNames[ key ] = Mailroom_AutoCompleteNames[ key ] or {}
  -- names unseen for 30 days are dropped (stamps are time(), so this works
  -- across sessions)
  local now = time()
  for char, last_seen in pairs( Mailroom_AutoCompleteNames[ key ] ) do
    if now - last_seen > m.AUTOCOMPLETE_MAX_AGE then
      Mailroom_AutoCompleteNames[ key ][ char ] = nil
    end
  end

  m.add_auto_complete_name( UnitName( "player" ) )

  SLASH_MAILROOM1 = "/mailroom"
  SLASH_MAILROOM2 = "/mr"
  SlashCmdList[ "MAILROOM" ] = m.slash_command
end

function Mailroom.MAIL_SEND_SUCCESS()
  m.sendmail_pending = nil
  if m.sendmail_state then
    m.add_auto_complete_name( m.sendmail_state.to, true )
  end
  if m.sendmail_sending then
    m.sendmail_update = true
    m.wake()
  end
end

function Mailroom.MAIL_INBOX_UPDATE()
  -- senders that can be answered become autocomplete names
  for i = 1, GetInboxNumItems() do
    local _, _, sender, _, _, _, _, _, _, _, _, can_reply = GetInboxHeaderInfo( i )
    if sender and can_reply then
      m.add_auto_complete_name( sender )
    end
  end
  m.inbox_delete_pending()
  if m.inbox_opening then
    m.inbox_update = true
    m.wake()
  end
end

---@param subject string?
---@return string? kind "Sold", "Removed", "Expired", "Won" or "Outbid"
function Mailroom.auction_kind( subject )
  if not subject then return nil end
  if not m.auction_subjects then
    m.auction_subjects = {}
    for kind, text in pairs( { Sold = AUCTION_SOLD_MAIL_SUBJECT, Removed = AUCTION_REMOVED_MAIL_SUBJECT, Expired = AUCTION_EXPIRED_MAIL_SUBJECT, Won = AUCTION_WON_MAIL_SUBJECT, Outbid = AUCTION_OUTBID_MAIL_SUBJECT } ) do
      m.auction_subjects[ kind ] = string.gsub( text, "%%s", "" )
    end
  end
  for kind, prefix in pairs( m.auction_subjects ) do
    if string.find( subject, prefix, 1, true ) then return kind end
  end
end

-- Auction House and returned markers, and the attachment stack counts, for
-- the rows on the current page.
function Mailroom.inbox_update_icons()
  local num_items = GetInboxNumItems()
  for i = 1, 7 do
    local row = inbox_rows[ i ]
    local index = i + (InboxFrame.pageNum - 1) * 7
    local auction, returned, count
    if index <= num_items then
      local _, _, sender, subject, _, _, _, _, _, was_returned = GetInboxHeaderInfo( index )
      -- every Auction House signs as "<name> Auction House"
      auction = (sender and string.find( sender, "Auction House$" )) or m.auction_kind( subject )
      returned = was_returned
      local _, _, stack = GetInboxItem( index, 1 )
      count = stack
    end
    if auction then row.auction:Show() else row.auction:Hide() end
    if returned then row.returned:Show() else row.returned:Hide() end
    local badge = row.count
    if count and count > 0 then
      badge:SetText( count )
      badge:Show()
    else
      badge:Hide()
    end
  end
end

-- Seen now (time(), so the 30 day expiry survives a logout). The list is
-- sorted again for a new name, or for one just mailed (recent).
---@param name string
---@param recent boolean?
function Mailroom.add_auto_complete_name( name, recent )
  local names = Mailroom_AutoCompleteNames[ m.names_key ]
  if recent or not names[ name ] then m.sorted_names = nil end
  names[ name ] = time()
end

function Mailroom.inbox_load()
  InboxFrame:EnableMouse( false )
  local btn = CreateFrame( "Button", "MailroomOpenMailButton", InboxFrame, "UIPanelButtonTemplate" )
  btn:SetPoint( "BOTTOM", -10, 90 )
  btn:SetText( OPENMAIL )
  btn:SetWidth( math.max( 120, 30 + btn:GetRegions():GetStringWidth() ) )
  btn:SetHeight( 25 )
  btn:SetScript( "OnClick", m.inbox_open_all )

  for i = 1, 7 do
    _G[ "MailroomAuctionIcon" .. i .. "Texture" ]:SetVertexColor( NORMAL_FONT_COLOR.r, NORMAL_FONT_COLOR.g, NORMAL_FONT_COLOR.b )
    _G[ "MailroomReturnedArrow" .. i .. "Texture" ]:SetVertexColor( NORMAL_FONT_COLOR.r, NORMAL_FONT_COLOR.g, NORMAL_FONT_COLOR.b )
    inbox_rows[ i ] = {
      button = _G[ "MailItem" .. i .. "Button" ],
      icon = _G[ "MailItem" .. i .. "ButtonIcon" ],
      auction = _G[ "MailroomAuctionIcon" .. i ],
      returned = _G[ "MailroomReturnedArrow" .. i ],
    }
  end

  local received = InboxFrame:CreateFontString( "MailroomMarksReceived", "ARTWORK", "GameFontNormal" )
  received:SetJustifyH( "LEFT" )
  received:SetPoint( "TOPLEFT", InboxTitleText, "BOTTOMLEFT", 0, -19 )
  received:Hide()

  -- Stack count badge on every attachment icon, the way bags show it: a mail
  -- holding three marks reads "3" without having to open it.
  for i = 1, 7 do
    local row = inbox_rows[ i ]
    local badge = row.button:CreateFontString( "MailroomItemCount" .. i, "OVERLAY", "NumberFontNormalSmall" )
    badge:SetJustifyH( "RIGHT" )
    badge:SetPoint( "BOTTOMRIGHT", row.icon, "BOTTOMRIGHT", -1, 1 )
    badge:Hide()
    row.count = badge
  end
end

function Mailroom.inbox_open_all()
  m.inbox_opening = true
  m.inbox_update_lock()
  m.inbox_skip = false
  m.inbox_index = 1
  m.inbox_update = true
  m.wake()
end

function Mailroom.inbox_abort()
  m.inbox_opening = false
  m.inbox_update_lock()
  m.inbox_update = false
end

-- "C.O.D. Amount:" becomes "C.O.D. each mail:" or "C.O.D. 1st mail:".
local cod_each, cod_first
function Mailroom.set_cod_text()
  if not cod_each then
    local text = string.match( string.sub( COD_AMOUNT, 1, #COD_AMOUNT - 1 ), "^(.-)%s+%S+$" )
    cod_each, cod_first = text .. " each mail:", text .. " 1st mail:"
  end
  SendMailMoneyText:SetText( SendMailCODAllButton:GetChecked() and cod_each or cod_first )
end

Mailroom.format_money = GetCoinTextureString

---@param money number
function Mailroom.update_money( money )
  m.money_received = m.money_received + money
  MoneyReceived:SetText( "Money received: " .. m.format_money( m.money_received ) )

  if m.money_received > 0 then
    MoneyReceived:Show()
  else
    MoneyReceived:Hide()
  end
end

-- Marks ---------------------------------------------------------------------

-- Name and stack count of a tracked mark attached to mail index, or nil.
-- GetInboxItem reports the attachment's stack size directly, so a mail with
-- three marks counts as three, without opening it.
function Mailroom.inbox_item_marks( index )
  local name, _, count = GetInboxItem( index, 1 )
  if not MARK_SHORT[ name ] then return nil end
  return name, count
end

-- Every tracked mark currently sitting in the mailbox, and their total.
function Mailroom.inbox_marks_tally()
  local tally, total = {}, 0
  for i = 1, GetInboxNumItems() do
    local name, count = m.inbox_item_marks( i )
    if name then
      tally[ name ] = ( tally[ name ] or 0 ) + count
      total = total + count
    end
  end
  return tally, total
end

-- The marks suffix for the inbox title, "" when the mailbox holds none.
function Mailroom.marks_title()
  local tally, total = m.inbox_marks_tally()
  if total == 0 then return "" end

  local parts = {}
  for _, mark in ipairs( MARKS ) do
    if tally[ mark.name ] then
      table.insert( parts, mark.short .. " " .. tally[ mark.name ] )
    end
  end
  local breakdown = #parts > 1 and ( " (" .. table.concat( parts, ", " ) .. ")" ) or ""
  return " - " .. total .. ( total == 1 and " mark" or " marks" ) .. breakdown
end

-- Running total of marks taken this visit, shown like the money counter.
function Mailroom.update_marks( name, count )
  m.marks_received[ name ] = ( m.marks_received[ name ] or 0 ) + count
  m.marks_received_total = m.marks_received_total + count
  MailroomMarksReceived:SetText( "Marks received: " .. m.marks_received_total )
  MailroomMarksReceived:Show()
end

---@param i number
---@param manual boolean?
function Mailroom.inbox_open( i, manual )
  local _, _, sender, subject, money, _, _, has_item, read = GetInboxHeaderInfo( i )

  if has_item then
    local name, count = m.inbox_item_marks( i )
    if name then
      m.update_marks( name, count )
    end
  end

  if money > 0 and ((read and not has_item) or manual) then
    m.update_money( money )
  end

  GetInboxText( i )
  TakeInboxMoney( i )
  TakeInboxItem( i )

  -- The server declines a delete sent while the takes above are still in
  -- flight, which used to leave the emptied mail behind. Mail that had
  -- nothing to take goes right away; the rest is queued and deleted once an
  -- inbox update confirms it reads back empty.
  -- Open All takes from a mail again on each inbox update until it reads
  -- back empty, so a mail already queued is not queued again.
  if money == 0 and not has_item then
    DeleteInboxItem( i )
  else
    sender, subject = sender or "", subject or ""
    for _, p in ipairs( m.delete_queue ) do
      if p.index == i and p.sender == sender and p.subject == subject then return end
    end
    table.insert( m.delete_queue, { index = i, sender = sender, subject = subject } )
    m.watch_deletes()
  end
end

-- Delete the mail of a finished take. Sender and subject must still match so
-- a mail that already left the inbox (shifting the rest down) is never
-- confused with the mail that took its place.
function Mailroom.inbox_delete_pending()
  for n = #m.delete_queue, 1, -1 do
    local p = m.delete_queue[ n ]
    local _, _, sender, subject, money, _, _, has_item = GetInboxHeaderInfo( p.index )
    if not sender then
      -- the mail already left the inbox on its own
      table.remove( m.delete_queue, n )
    elseif sender == p.sender and subject == p.subject and money == 0 and not has_item then
      DeleteInboxItem( p.index )
      table.remove( m.delete_queue, n )
    end
  end
end

function Mailroom.inbox_update_lock()
  for i = 1, 7 do
    local row = inbox_rows[ i ]
    row.icon:SetDesaturated( m.inbox_opening )
    if m.inbox_opening then
      row.button:SetChecked( nil )
    end
  end
end

function Mailroom.hook.OpenMail_Reply( ... )
  Mailroom_To = nil
  return m.orig.OpenMail_Reply( ... )
end

function Mailroom.hook.InboxFrame_Update()
  m.orig.InboxFrame_Update()
  -- a row's tooltip that is up shows the row's new mail
  for i = 1, 7 do
    local button = inbox_rows[ i ].button
    if GameTooltip:IsOwned( button ) then
      local previous = this
      this = button
      InboxFrameItem_OnEnter()
      this = previous
    end
  end

  local currentPage = InboxFrame.pageNum
  local totalPages = math.ceil( GetInboxNumItems() / INBOXITEMS_TO_DISPLAY )
  local text = totalPages > 0 and (currentPage .. "/" .. totalPages) or EMPTY
  InboxTitleText:SetText( INBOX .. " [" .. text .. "]" .. m.marks_title() )

  m.inbox_update_icons()
  m.inbox_update_lock()
end

---@param i number
function Mailroom.hook.InboxFrame_OnClick( i )
  if m.inbox_opening or arg1 == "RightButton" and select( 6, GetInboxHeaderInfo( i ) ) > 0 then
    this:SetChecked( nil )
  elseif arg1 == "RightButton" then
    m.inbox_open( i, true )
  else
    return m.orig.InboxFrame_OnClick( i )
  end
end

function Mailroom.hook.InboxFrameItem_OnEnter()
  m.orig.InboxFrameItem_OnEnter()
  if GetInboxItem( this.index ) then
    GameTooltip:AddLine( ITEM_OPENABLE, "", 0, 1, 0 )
    GameTooltip:Show()
  end
end

function Mailroom.hook.SendMailFrame_Update()
  local last = m.sendmail_num_attachments()

  for i = 1, ATTACHMENTS_MAX do
    local btn = attachment_button[ i ]

    local texture, count
    if btn.item then
      texture, count = GetContainerItemInfo( unpack( btn.item ) )
    end
    if not texture then
      btn:SetNormalTexture( nil )
      btn.countText:Hide()
      if btn.item then unlock_item( btn.item ) end
      btn.item = nil
    else
      btn:SetNormalTexture( texture )
      if count > 1 then
        btn.countText:SetText( count )
        btn.countText:Show()
      else
        btn.countText:Hide()
      end
    end
  end

  local attached = m.sendmail_num_attachments()
  if attached > 0 then
    SendMailCODButton:Enable()
    SendMailCODButtonText:SetTextColor( NORMAL_FONT_COLOR.r, NORMAL_FONT_COLOR.g, NORMAL_FONT_COLOR.b )
    if attached > 1 and SendMailCODButton:GetChecked() then
      SendMailCODAllButton:Enable()
      SendMailCODAllButtonText:SetTextColor( NORMAL_FONT_COLOR.r, NORMAL_FONT_COLOR.g, NORMAL_FONT_COLOR.b )
      m.set_cod_text()
    else
      SendMailCODAllButton:Disable()
      SendMailCODAllButtonText:SetTextColor( GRAY_FONT_COLOR.r, GRAY_FONT_COLOR.g, GRAY_FONT_COLOR.b )
      SendMailMoneyText:SetText( AMOUNT_TO_SEND )
    end
  else
    SendMailSendMoneyButton:SetChecked( 1 )
    SendMailCODButton:SetChecked( nil )
    SendMailMoneyText:SetText( AMOUNT_TO_SEND )
    SendMailCODButton:Disable()
    SendMailCODButtonText:SetTextColor( GRAY_FONT_COLOR.r, GRAY_FONT_COLOR.g, GRAY_FONT_COLOR.b )
    SendMailCODAllButton:Disable()
    SendMailCODAllButtonText:SetTextColor( GRAY_FONT_COLOR.r, GRAY_FONT_COLOR.g, GRAY_FONT_COLOR.b )
  end

  MoneyFrame_Update( "SendMailCostMoneyFrame", GetSendMailPrice() * math.max( 1, attached ) )

  -- Determine how many rows of attachments to show
  local itemRowCount = 1
  local temp = last
  while temp > ATTACHMENTS_PER_ROW_SEND and itemRowCount < ATTACHMENTS_MAX_ROWS_SEND do
    itemRowCount = itemRowCount + 1
    temp = temp - ATTACHMENTS_PER_ROW_SEND
  end

  if temp == ATTACHMENTS_PER_ROW_SEND and itemRowCount < ATTACHMENTS_MAX_ROWS_SEND then
    itemRowCount = itemRowCount + 1
  end
  if SendMailFrame.maxRowsShown and last > 0 and itemRowCount < SendMailFrame.maxRowsShown then
    itemRowCount = SendMailFrame.maxRowsShown
  else
    SendMailFrame.maxRowsShown = itemRowCount
  end

  -- The slots and the letter are laid out again only when the rows change.
  if itemRowCount ~= m.layout_rows then
    m.layout_rows = itemRowCount
    m.sendmail_layout( itemRowCount )
  end

  SendMailFrame_CanSend()
end

function Mailroom.sendmail_layout( itemRowCount )
  -- Compute sizes
  local cursorx = 0
  local cursory = itemRowCount - 1
  local marginxl = 8 + 6
  local marginxr = 40 + 6
  local areax = SendMailFrame:GetWidth() - marginxl - marginxr
  local iconx = MailAttachment1:GetWidth() + 2
  local icony = MailAttachment1:GetHeight() + 2
  local gapx1 = floor( (areax - (iconx * ATTACHMENTS_PER_ROW_SEND)) / (ATTACHMENTS_PER_ROW_SEND - 1) )
  local gapx2 = floor( (areax - (iconx * ATTACHMENTS_PER_ROW_SEND) - (gapx1 * (ATTACHMENTS_PER_ROW_SEND - 1))) / 2 )
  local gapy1 = 5
  local gapy2 = 6
  local areay = (gapy2 * 2) + (gapy1 * (itemRowCount - 1)) + (icony * itemRowCount)
  local indentx = marginxl + gapx2 + 17
  local indenty = 170 + gapy2 + icony - 13
  local tabx = (iconx + gapx1) - 3 --this magic number changes the attachment spacing
  local taby = (icony + gapy1)
  local scrollHeight = 249 - areay

  MailHorizontalBarLeft:SetPoint( "TOPLEFT", SendMailFrame, "BOTTOMLEFT", 2 + 15, 184 + areay - 14 )

  SendMailScrollFrame:SetHeight( scrollHeight )
  SendMailScrollChildFrame:SetHeight( scrollHeight )

  local SendMailScrollFrameTop = select( 3, SendMailScrollFrame:GetRegions() )
  SendMailScrollFrameTop:SetHeight( scrollHeight )
  SendMailScrollFrameTop:SetTexCoord( 0, .484375, 0, scrollHeight / 256 )

  StationeryBackgroundLeft:SetHeight( scrollHeight )
  StationeryBackgroundLeft:SetTexCoord( 0, 1, 0, scrollHeight / 256 )


  StationeryBackgroundRight:SetHeight( scrollHeight )
  StationeryBackgroundRight:SetTexCoord( 0, 1, 0, scrollHeight / 256 )

  -- Set Items
  for i = 1, ATTACHMENTS_MAX do
    if cursory >= 0 then
      attachment_button[ i ]:Enable()
      attachment_button[ i ]:Show()
      attachment_button[ i ]:SetPoint( "TOPLEFT", "SendMailFrame", "BOTTOMLEFT", indentx + (tabx * cursorx),
        indenty + (taby * cursory) )

      cursorx = cursorx + 1
      if cursorx >= ATTACHMENTS_PER_ROW_SEND then
        cursory = cursory - 1
        cursorx = 0
      end
    else
      attachment_button[ i ]:Hide()
    end
  end
end

function Mailroom.hook.SendMailRadioButton_OnClick( index )
  if (index == 1) then
    SendMailSendMoneyButton:SetChecked( 1 );
    SendMailCODButton:SetChecked( nil );
    SendMailMoneyText:SetText( AMOUNT_TO_SEND );
    SendMailCODAllButton:Disable()
    SendMailCODAllButtonText:SetTextColor( GRAY_FONT_COLOR.r, GRAY_FONT_COLOR.g, GRAY_FONT_COLOR.b )
  else
    SendMailSendMoneyButton:SetChecked( nil );
    SendMailCODButton:SetChecked( 1 );
    SendMailMoneyText:SetText( COD_AMOUNT );

    if m.sendmail_num_attachments() > 1 then
      SendMailCODAllButton:Enable()
      SendMailCODAllButtonText:SetTextColor( NORMAL_FONT_COLOR.r, NORMAL_FONT_COLOR.g, NORMAL_FONT_COLOR.b )
      m.set_cod_text()
    end
  end
  PlaySound( "igMainMenuOptionCheckBoxOn" );
end

function Mailroom.hook.ClickSendMailItemButton()
  m.sendmail_set_attachment( m.get_cursor_item() )
end

function Mailroom.hook.PickupContainerItem( bag, slot )
  if m.sendmail_attached( bag, slot ) then
    if arg1 == "RightButton" and MailFrame:IsVisible() then
      return m.sendmail_remove_attachment( { bag, slot } )
    end
    return m.orig.PickupContainerItem( bag, slot )
  end

  if GetContainerItemInfo( bag, slot ) then
    if arg1 == "RightButton" and MailFrame:IsVisible() then
      MailFrameTab_OnClick( 2 )
      m.sendmail_set_attachment( { bag, slot } )
      return
    else
      m.set_cursor_item( { bag, slot } )
    end
  end
  return m.orig.PickupContainerItem( bag, slot )
end

function Mailroom.hook.SplitContainerItem( bag, slot, amount )
  if m.sendmail_attached( bag, slot ) then return end
  return m.orig.SplitContainerItem( bag, slot, amount )
end

function Mailroom.hook.UseContainerItem( bag, slot, onself )
  if m.sendmail_attached( bag, slot ) then return end
  if IsShiftKeyDown() or IsControlKeyDown() or IsAltKeyDown() then
    return m.orig.UseContainerItem( bag, slot, onself )
  elseif MailFrame:IsVisible() then
    MailFrameTab_OnClick( 2 )
    m.sendmail_set_attachment( { bag, slot } )
  elseif TradeFrame:IsVisible() then
    for i = 1, 6 do
      if not GetTradePlayerItemLink( i ) then
        m.orig.PickupContainerItem( bag, slot )
        ClickTradeButton( i )
        return
      end
    end
  else
    return m.orig.UseContainerItem( bag, slot, onself )
  end
end

function Mailroom.hook.SendMailFrame_CanSend()
  local cod_too_high = SendMailCODButton:GetChecked() and MoneyInputFrame_GetCopper( SendMailMoney ) > MAX_COD_AMOUNT * COPPER_PER_GOLD
  if cod_too_high then
    SendMailErrorText:Show()
    SendMailErrorCoin:Show()
  else
    SendMailErrorText:Hide()
    SendMailErrorCoin:Hide()
  end

  if not m.sendmail_sending and not cod_too_high and #(SendMailNameEditBox:GetText()) > 0 and (SendMailSendMoneyButton:GetChecked() and MoneyInputFrame_GetCopper( SendMailMoney ) or 0) + GetSendMailPrice() * math.max( 1, m.sendmail_num_attachments() ) <= GetMoney() then
    MailMailButton:Enable()
  else
    MailMailButton:Disable()
  end
end

function Mailroom.send_mail_button_onclick()
  MailAutoCompleteBox:Hide()

  if SendMailSendMoneyButton:GetChecked() and MoneyInputFrame_GetCopper( SendMailMoney ) > 0 then
    StaticPopup_Show( "MAILROOM_SEND_MONEY", SendMailNameEditBox:GetText() )
  else
    m.sendmail_start()
  end
end

function Mailroom.sendmail_start()
  Mailroom_To = SendMailNameEditBox:GetText()
  SendMailNameEditBox:HighlightText()

  m.sendmail_state = {
    to = Mailroom_To,
    subject = MailSubjectEditBox:GetText(),
    body = SendMailBodyEditBox:GetText(),
    money = MoneyInputFrame_GetCopper( SendMailMoney ),
    cod_checked = SendMailCODButton:GetChecked(),
    attachments = m.sendmail_attachments(),
    numMessages = math.max( 1, m.sendmail_num_attachments() ),
  }

  m.sendmail_sending = true
  m.sendmail_clear()
  m.sendmail_send()
end

function Mailroom.sendmail_load()
  SendMailFrame:EnableMouse( false )
  for i = 1, ATTACHMENTS_MAX do
    attachment_button[ i ].countText = _G[ "MailAttachment" .. i .. "Count" ]
  end
  for i = 1, AUTOCOMPLETE_BUTTONS do
    complete_buttons[ i ] = _G[ "MailAutoCompleteButton" .. i ]
  end

  -- Same confirmation as the native SEND_MONEY popup, but it starts Mailroom's queue.
  StaticPopupDialogs[ "MAILROOM_SEND_MONEY" ] = {
    text = SEND_MONEY_CONFIRMATION,
    button1 = ACCEPT,
    button2 = CANCEL,
    OnAccept = function()
      m.sendmail_start()
    end,
    OnShow = function()
      MoneyFrame_Update( this:GetName() .. "MoneyFrame", MoneyInputFrame_GetCopper( SendMailMoney ) )
    end,
    hasMoneyFrame = 1,
    hideOnEscape = 1
  }

  SendMailFrame:CreateTexture( "MailHorizontalBarLeft", "BACKGROUND" )
  MailHorizontalBarLeft:SetTexture( "Interface\\ClassTrainerFrame\\UI-ClassTrainer-HorizontalBar" )
  MailHorizontalBarLeft:SetWidth( 256 )
  MailHorizontalBarLeft:SetHeight( 16 )
  MailHorizontalBarLeft:SetTexCoord( 0, 1, 0, .25 )

  SendMailFrame:CreateTexture( "MailHorizontalBarRight", "BACKGROUND" )
  MailHorizontalBarRight:SetTexture( "Interface\\ClassTrainerFrame\\UI-ClassTrainer-HorizontalBar" )
  MailHorizontalBarRight:SetWidth( 75 )
  MailHorizontalBarRight:SetHeight( 16 )
  MailHorizontalBarRight:SetTexCoord( 0, .29296875, .25, .5 )
  MailHorizontalBarRight:SetPoint( "LEFT", MailHorizontalBarLeft, "RIGHT" )

  SendMailMoneyText:SetJustifyH( "LEFT" )
  SendMailMoneyText:SetPoint( "TOPLEFT", 0, 0 )
  SendMailMoney:ClearAllPoints()
  SendMailMoney:SetPoint( "TOPLEFT", SendMailMoneyText, "BOTTOMLEFT", 5, -5 )
  SendMailMoneyGoldRight:SetPoint( "RIGHT", 20, 0 )
  select( 9, SendMailMoneyGold:GetRegions() ):SetDrawLayer( "BORDER" )
  SendMailMoneyGold:SetMaxLetters( 7 )
  SendMailMoneyGold:SetWidth( 50 )
  SendMailMoneySilverRight:SetPoint( "RIGHT", 10, 0 )
  select( 9, SendMailMoneySilver:GetRegions() ):SetDrawLayer( "BORDER" )
  SendMailMoneySilver:SetWidth( 28 )
  SendMailMoneySilver:SetPoint( "LEFT", SendMailMoneyGold, "RIGHT", 30, 0 )
  SendMailMoneyCopperRight:SetPoint( "RIGHT", 10, 0 )
  select( 9, SendMailMoneyCopper:GetRegions() ):SetDrawLayer( "BORDER" )
  SendMailMoneyCopper:SetWidth( 28 )
  SendMailMoneyCopper:SetPoint( "LEFT", SendMailMoneySilver, "RIGHT", 20, 0 )
  SendMailSendMoneyButton:SetPoint( "TOPLEFT", SendMailMoney, "TOPRIGHT", 0, 12 )

  -- hack to avoid automatic subject setting and button disabling from weird blizzard code
  MailMailButton = SendMailMailButton
  SendMailMailButton = setmetatable( {}, { __index = function() return function() end end } )
  SendMailMailButton_OnClick = m.send_mail_button_onclick
  MailSubjectEditBox = SendMailSubjectEditBox
  SendMailSubjectEditBox = setmetatable( {}, {
    __index = function( _, key )
      return function( _, ... )
        return MailSubjectEditBox[ key ]( MailSubjectEditBox, ... )
      end
    end,
  } )

  SendMailNameEditBox._SetText = SendMailNameEditBox.SetText
  function SendMailNameEditBox:SetText( ... )
    if not Mailroom_To then
      return self:_SetText( ... )
    end
  end

  SendMailNameEditBox:SetScript( "OnShow", function()
    if Mailroom_To then
      this:_SetText( Mailroom_To )
    end
  end )
  SendMailNameEditBox:SetScript( "OnChar", function()
    Mailroom_To = nil
    m.get_suggestions()
  end )
  SendMailNameEditBox:SetScript( "OnTabPressed", function()
    if MailAutoCompleteBox:IsVisible() then
      if IsShiftKeyDown() then
        m.previous_match()
      else
        m.next_match()
      end
    else
      MailSubjectEditBox:SetFocus()
    end
  end )
  SendMailNameEditBox:SetScript( "OnEnterPressed", function()
    if MailAutoCompleteBox:IsVisible() then
      MailAutoCompleteBox:Hide()
      this:HighlightText( 0, 0 )
    else
      MailSubjectEditBox:SetFocus()
    end
  end )
  SendMailNameEditBox:SetScript( "OnEscapePressed", function()
    if MailAutoCompleteBox:IsVisible() then
      MailAutoCompleteBox:Hide()
    else
      this:ClearFocus()
    end
  end )
  function SendMailNameEditBox.focusLoss()
    MailAutoCompleteBox:Hide()
  end

  SendMailCODAllButtonText:SetText( "  All mails" )
  SendMailCODAllButton:SetScript( "OnClick", m.set_cod_text )

  do
    local orig_script = SendMailNameEditBox:GetScript( "OnTextChanged" )
    SendMailNameEditBox:SetScript( "OnTextChanged", function()
      local text = this:GetText()
      local formatted = string.gsub( string.lower( text ), "^%l", string.upper )
      if text ~= formatted then
        this:SetText( formatted )
      end
      return orig_script()
    end )
  end

  for _, editBox in ipairs( { SendMailNameEditBox, SendMailSubjectEditBox } ) do
    editBox:SetScript( "OnEditFocusGained", function()
      this:HighlightText()
    end )
    editBox:SetScript( "OnEditFocusLost", function()
      (this.focusLoss or function() end)()
      this:HighlightText( 0, 0 )
    end )
    do
      -- a double click selects all, on the next frame (after the click places
      -- the cursor)
      local last_t, last_x, last_y = 0
      local function select_all()
        this:HighlightText()
        this:SetScript( "OnUpdate", nil )
      end
      editBox:SetScript( "OnMouseDown", function()
        local x, y = GetCursorPosition()
        if GetTime() - last_t < .5 and x == last_x and y == last_y then
          this:SetScript( "OnUpdate", select_all )
        end
        last_t, last_x, last_y = GetTime(), x, y
      end )
    end
  end
end

--@param bag number
--@param slot number
function Mailroom.sendmail_attached( bag, slot )
  if not MailFrame:IsVisible() then return false end
  for i = 1, ATTACHMENTS_MAX do
    local btn = attachment_button[ i ]
    if btn.item and btn.item[ 1 ] == bag and btn.item[ 2 ] == slot then
      return true
    end
  end
  if m.sendmail_state then
    for _, attachment in ipairs( m.sendmail_state.attachments ) do
      if attachment[ 1 ] == bag and attachment[ 2 ] == slot then
        return true
      end
    end
  end
end

function Mailroom.attachment_button_on_click()
  local attachedItem = this.item
  local cursorItem = m.get_cursor_item()
  if m.sendmail_set_attachment( cursorItem, this ) then
    if attachedItem then
      if arg1 == "LeftButton" then m.set_cursor_item( attachedItem ) end
      m.orig.PickupContainerItem( unpack( attachedItem ) )
      if arg1 ~= "LeftButton" then ClearCursor() end -- for the lock changed event
    end
  end
end

function Mailroom.sendmail_remove_attachment( item )
  for i = 1, ATTACHMENTS_MAX do
    local btn = attachment_button[ i ]
    if btn.item and btn.item[ 1 ] == item[ 1 ] and btn.item[ 2 ] == item[ 2 ] then
      btn.item = nil
      unlock_item( item )
      SendMailFrame_Update()
      return
    end
  end
end

-- requires an item lock changed event for a proper update
---@param item table
---@param slot number?
function Mailroom.sendmail_set_attachment( item, slot )
  if item and not m.sendmail_pickup_mailable( item ) then
    ClearCursor()
    return
  elseif not slot then
    for i = 1, ATTACHMENTS_MAX do
      if not attachment_button[ i ].item then
        slot = attachment_button[ i ]
        break
      end
    end
  end
  if slot then
    if not (item or slot.item) then return true end
    if slot.item then unlock_item( slot.item ) end
    slot.item = item
    if item then lock_item( item ) end
    ClearCursor()
    SendMailFrame_Update()
    return true
  end
end

---@param item table
function Mailroom.sendmail_pickup_mailable( item )
  ClearCursor()
  m.orig.ClickSendMailItemButton()
  ClearCursor()
  m.orig.PickupContainerItem( unpack( item ) )
  m.orig.ClickSendMailItemButton()
  local mailable = GetSendMailItem() and true or false
  m.orig.ClickSendMailItemButton()
  return mailable
end

function Mailroom.sendmail_num_attachments()
  local x = 0
  for i = 1, ATTACHMENTS_MAX do
    if attachment_button[ i ].item then
      x = x + 1
    end
  end
  return x
end

function Mailroom.sendmail_attachments()
  local t = {}
  for i = 1, ATTACHMENTS_MAX do
    local btn = attachment_button[ i ]
    if btn.item then
      table.insert( t, btn.item )
    end
  end
  return t
end

-- Empties the form. Attachments that go on to the send queue stay locked.
function Mailroom.sendmail_clear()
  for i = 1, ATTACHMENTS_MAX do
    local btn = attachment_button[ i ]
    if btn.item and not (m.sendmail_state and m.sendmail_sending) then unlock_item( btn.item ) end
    btn.item = nil
  end
  MailMailButton:Disable()
  SendMailNameEditBox:SetText ""
  SendMailNameEditBox:SetFocus()
  MailSubjectEditBox:SetText ""
  SendMailBodyEditBox:SetText ""
  MoneyInputFrame_ResetMoney( SendMailMoney )
  SendMailRadioButton_OnClick( 1 )

  SendMailFrame_Update()
end

function Mailroom.sendmail_abort()
  if m.sendmail_state then
    for _, item in ipairs( m.sendmail_state.attachments ) do unlock_item( item ) end
  end
  m.sendmail_sending = false
  m.sendmail_pending = nil
  m.sendmail_update = nil
  m.sendmail_state = nil
  if GetSendMailItem() then
    ClearCursor()
    m.orig.ClickSendMailItemButton()
    ClearCursor()
  end
  SendMailFrame_Update()
end

function Mailroom.sendmail_send()
  local item = table.remove( m.sendmail_state.attachments, 1 )
  if item then
    unlock_item( item )
    ClearCursor()
    if GetSendMailItem() then
      m.orig.ClickSendMailItemButton()
      ClearCursor()
    end
    m.orig.PickupContainerItem( unpack( item ) )
    m.orig.ClickSendMailItemButton()

    if not GetSendMailItem() then
      DEFAULT_CHAT_FRAME:AddMessage( "|cffabd473Mailroom|r: " .. ERROR_CAPS, 1, 0, 0 )
      m.sendmail_abort()
      return
    end
  end

  local amount = m.sendmail_state.money

  if amount > 0 then
    if not SendMailCODAllButton:GetChecked() then
      m.sendmail_state.money = 0
    end
    if m.sendmail_state.cod_checked then
      SetSendMailCOD( amount )
    else
      m.sendmail_state.money = 0
      SetSendMailMoney( amount )
    end
  end

  local subject = m.sendmail_state.subject
  if subject == "" then
    if item then
      local item_name, _, stack_count = GetSendMailItem()
      subject = item_name .. (stack_count > 1 and " (" .. stack_count .. ")" or "")
    else
      subject = "<" .. NO_ATTACHMENTS .. ">"
    end
  elseif m.sendmail_state.numMessages > 1 then
    subject = subject .. string.format( " [%d/%d]", m.sendmail_state.numMessages - #m.sendmail_state.attachments,
      m.sendmail_state.numMessages )
  end

  m.sendmail_pending = true
  SendMail( m.sendmail_state.to, subject, m.sendmail_state.body )

  if #m.sendmail_state.attachments == 0 then
    m.sendmail_sending = false
  end
end

do
  local inputLength
  local matches = {}
  local index

  local function complete()
    SendMailNameEditBox:SetText( matches[ index ] )
    SendMailNameEditBox:HighlightText( inputLength, -1 )
    for i = 1, AUTOCOMPLETE_BUTTONS do
      local button = complete_buttons[ i ]
      if i == index then
        button:LockHighlight()
      else
        button:UnlockHighlight()
      end
    end
  end

  function Mailroom.previous_match()
    if index then
      index = index > 1 and index - 1 or #matches
      complete()
    end
  end

  function Mailroom.next_match()
    if index then
      index = index % #matches + 1
      complete()
    end
  end

  function Mailroom.select_match( i )
    index = i
    complete()
    MailAutoCompleteBox:Hide()
    SendMailNameEditBox:HighlightText( 0, 0 )
  end

  function Mailroom.get_suggestions()
    local input = SendMailNameEditBox:GetText()
    inputLength = #input

    table.wipe( matches )
    index = nil

    -- most recent first; rebuilt only after a name is added or cleared
    if not m.sorted_names then
      m.sorted_names = {}
      for name, seen in pairs( Mailroom_AutoCompleteNames[ m.names_key ] ) do
        table.insert( m.sorted_names, { name = name, time = seen } )
      end
      table.sort( m.sorted_names, function( a, b ) return b.time < a.time end )
    end
    local autoCompleteNames = m.sorted_names

    local typed = string.upper( input )
    local me = UnitName( "player" )
    for _, t in ipairs( autoCompleteNames ) do
      if #matches == AUTOCOMPLETE_BUTTONS then break end
      if t.name ~= me and string.find( string.upper( t.name ), typed, 1, true ) == 1 then
        table.insert( matches, t.name )
      end
    end
    -- then ClassicAPI's known names: whispered (most recent first), the rest
    -- by name. It never offers the player.
    local known = C_AutoComplete.GetAutoCompleteResults( input, AUTOCOMPLETE_BUTTONS, 0, true, AUTOCOMPLETE_FLAGS, 0 )
    for i = 1, #known do
      if #matches == AUTOCOMPLETE_BUTTONS then break end
      local name, seen = known[ i ].name, false
      for j = 1, #matches do
        if matches[ j ] == name then seen = true; break end
      end
      if not seen then table.insert( matches, name ) end
    end

    if #matches > 0 and (#matches > 1 or input ~= matches[ 1 ]) then
      for i = 1, AUTOCOMPLETE_BUTTONS do
        local button = complete_buttons[ i ]
        if i <= #matches then
          button:SetText( matches[ i ] )
          button:GetFontString():SetPoint( "LEFT", button, "LEFT", 15, 0 )
          button:Show()
        else
          button:Hide()
        end
      end
      MailAutoCompleteBox:SetHeight( #matches * complete_buttons[ 1 ]:GetHeight() + 35 )
      MailAutoCompleteBox:SetWidth( 120 )
      MailAutoCompleteBox:Show()
      index = 1
      complete()
    else
      MailAutoCompleteBox:Hide()
    end
  end
end

function Mailroom.info( message )
  DEFAULT_CHAT_FRAME:AddMessage( string.format( "|cffabd473Mailroom|r: %s", message ) )
end

Mailroom:init()
