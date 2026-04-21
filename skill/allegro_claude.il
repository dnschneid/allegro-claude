; SPDX-FileCopyrightText: (C) 2026 Meta Platforms Inc.
; SPDX-License-Identifier: Apache-2.0
;
; allegro_claude.il -- SKILL Claude integration
;
; Architecture:
;   A long-lived `claude` process is spawned via ipcBeginProcess with
;   --input-format stream-json and --output-format stream-json.
;   SKILL writes JSON user messages to claude's stdin and parses
;   streaming JSON responses from stdout via the async dataHandler.
;

; ============================================================
; 1. JSON Parser
;
; Minimal recursive-descent parser returning native SKILL types:
;   JSON objects  -> alist:  ((key1 val1) (key2 val2) ...)
;   JSON arrays   -> list:   (val1 val2 ...)
;   JSON strings  -> string
;   JSON numbers  -> number (int or float)
;   true/false    -> t / nil
;   null          -> nil
;
; Each parse function takes (str pos) and returns (value . newPos)
; or nil on error.  Positions are 1-based per SKILL convention.
; ============================================================

procedure(ACL_jIsWS(c) and(c nindex(" \t\n\r" c)))
procedure(ACL_jIsDigit(c) and(c nindex("0123456789" c)))

procedure(ACL_jSkipWS(str pos)
  while(ACL_jIsWS(substring(str pos 1))
    pos++)
  pos)

procedure(ACL_jParse(str @optional (pos 1))
  let((c)
    pos = ACL_jSkipWS(str pos)
    c = substring(str pos 1)
    cond(
      (c == "\""  ACL_jParseStr(str pos))
      (c == "{"   ACL_jParseObj(str pos))
      (c == "["   ACL_jParseArr(str pos))
      (c == "t"   ACL_jParseLit(str pos "true" t))
      (c == "f"   ACL_jParseLit(str pos "false" nil))
      (c == "n"   ACL_jParseLit(str pos "null" nil))
      (or(c == "-" ACL_jIsDigit(c))
        ACL_jParseNum(str pos)))))

procedure(ACL_jParseStr(str pos)
  prog((start len c esc)
    pos++  ; skip opening "
    start = pos
    len = strlen(str)
    esc = nil
    while(pos <= len
      c = substring(str pos 1)
      cond(
        (esc   esc = nil  pos++)
        (c == "\\"  esc = t  pos++)
        (c == "\""
          let((raw)
            raw = substring(str start pos - start)
            return(list(
              if(nindex(raw "\\") ACL_jUnescape(raw) raw)
              pos + 1))))
        (t  pos++)))
    nil))

procedure(ACL_jUnescape(s)
  ; Replace JSON escape sequences.  Called only when s contains "\\".
  let((out pos bsPos next rest)
    out = ""
    pos = 1
    rest = s
    while(rest
      bsPos = nindex(rest "\\")
      if(bsPos then
        ; Append everything before the backslash
        when(bsPos > 1
          out = strcat(out substring(rest 1 bsPos - 1)))
        ; Decode the escape
        next = substring(rest (bsPos + 1) 1)
        out = strcat(out cond(
          (next == "n" "\n")  (next == "t" "\t")  (next == "r" "\r")
          (next == "\"" "\"") (next == "\\" "\\") (next == "/" "/")
          (t next)))
        rest = substring(rest (bsPos + 2))
      else
        ; No more escapes, append the remainder
        out = strcat(out rest)
        rest = nil))
    out))

procedure(ACL_jParseNum(str pos)
  let((start c)
    start = pos
    ; A JSON number ends at whitespace or a structural character.
    c = substring(str pos 1)
    while(and(c null(nindex(" \t\n\r,]}" c)))
      pos++
      c = substring(str pos 1))
    when(pos > start
      list(evalstring(substring(str start pos - start)) pos))))

procedure(ACL_jParseLit(str pos word value)
  when(substring(str pos strlen(word)) == word
    list(value pos + strlen(word))))

procedure(ACL_jParseObj(str pos)
  prog((entries key val c)
    pos = ACL_jSkipWS(str pos + 1)
    when(substring(str pos 1) == "}"
      return(list(nil pos + 1)))
    while(pos <= strlen(str)
      key = ACL_jParseStr(str pos)
      unless(key return(nil))
      pos = ACL_jSkipWS(str cadr(key))
      unless(substring(str pos 1) == ":" return(nil))
      pos = ACL_jSkipWS(str pos + 1)
      val = ACL_jParse(str pos)
      unless(val return(nil))
      entries = cons(list(car(key) car(val)) entries)
      pos = ACL_jSkipWS(str cadr(val))
      c = substring(str pos 1)
      cond(
        (c == ","  pos = ACL_jSkipWS(str pos + 1))
        (c == "}"  return(list(reverse(entries) pos + 1)))
        (t return(nil))))
    nil))

procedure(ACL_jParseArr(str pos)
  prog((items val c)
    pos = ACL_jSkipWS(str pos + 1)
    when(substring(str pos 1) == "]"
      return(list(nil pos + 1)))
    while(pos <= strlen(str)
      val = ACL_jParse(str pos)
      unless(val return(nil))
      items = cons(car(val) items)
      pos = ACL_jSkipWS(str cadr(val))
      c = substring(str pos 1)
      cond(
        (c == ","  pos = ACL_jSkipWS(str pos + 1))
        (c == "]"  return(list(reverse(items) pos + 1)))
        (t return(nil))))
    nil))

procedure(ACL_jGet(obj key)
  cadr(assoc(key obj)))

; ============================================================
; 2. JSON Writer
; ============================================================

procedure(ACL_jsonEscStr(s)
  let((out i c len)
    out = "\""
    for(i 1 strlen(s)
      c = substring(s i 1)
      out = strcat(out cond(
        (c == "\""  "\\\"")  (c == "\\"  "\\\\")
        (c == "\n"  "\\n")   (c == "\r"  "\\r")  (c == "\t" "\\t")
        (t c))))
    strcat(out "\"")))

procedure(ACL_jsonVal(v)
  cond(
    (stringp(v) ACL_jsonEscStr(v))
    (numberp(v) sprintf(nil "%L" v))
    (v == t     "true")
    (null(v)    "null")
    (listp(v)
      if(and(car(v) listp(car(v)))
        strcat("{" buildString(
          mapcar(lambda((pair)
            strcat(ACL_jsonEscStr(car(pair)) ":" ACL_jsonVal(cadr(pair))))
            v) ",") "}")
        strcat("[" buildString(mapcar('ACL_jsonVal v) ",") "]")))))

procedure(ACL_jsonObj(@rest pairs)
  strcat("{" buildString(
    mapcar(lambda((p)
      strcat(ACL_jsonEscStr(car(p)) ":" ACL_jsonVal(cadr(p))))
      pairs) ",") "}"))

; ============================================================
; 3. Global State
; ============================================================

; Clean up any existing process from a previous load
when(and(boundp('ACL_claude) ACL_claude)
  when(ipcIsAliveProcess(ACL_claude)
    printf("ACL: stopping previous claude process\n")
    ipcSignalProcess(ACL_claude 'TERM))
  ACL_claude = nil)

defvar(ACL_claude nil)
defvar(ACL_form nil)
defvar(ACL_logContent "")          ; accumulated log text
defvar(ACL_logTruncLimit 12500)    ; max chars shown in form field
defvar(ACL_logFile nil)            ; temp file for full log viewer
defvar(ACL_logCodeLimit 250)       ; max chars for each code preview
defvar(ACL_sessionId nil)
defvar(ACL_sessionSaved nil)       ; true after first successful reply
defvar(ACL_mode "auto")
defvar(ACL_effort "medium")
defvar(ACL_lineBuf "")
defvar(ACL_responseBuf "")
defvar(ACL_displayBuf "")
defvar(ACL_inExecBlock nil)
defvar(ACL_pendingBatch nil)
defvar(ACL_lastCmdTime 0)
defvar(ACL_toolUseRounds 0)
defvar(ACL_toolUseMax 100)
defvar(ACL_recording nil)
defvar(ACL_journalFile nil)
defvar(ACL_cmdSeq 0)
defvar(ACL_gotText nil)          ; set to t when any text arrives
defvar(ACL_isReady nil)          ; set to t when response is complete with no more blocks
defvar(ACL_hadToolUse nil)       ; true if tool_use occurred since last text block
defvar(ACL_execQueue nil)        ; queued exec blocks for deferred execution

defvar(ACL_tagOpen "<allegro_execute>")
defvar(ACL_tagClose "</allegro_execute>")

defvar(ACL_approveRe pcreCompile("^\\s*approve\\s*$" pcreGenCompileOptBits(?caseLess t)))
defvar(ACL_rejectRe  pcreCompile("^\\s*reject\\s*$"  pcreGenCompileOptBits(?caseLess t)))

defvar(ACL_homeDir      strcat(getShellEnvVar("HOME") "/.allegro_claude"))
defvar(ACL_sessionsFile strcat(ACL_homeDir "/sessions.json"))
defvar(ACL_logDir       strcat(ACL_homeDir "/logs"))

defvar(ACL_scriptDir
  pcreReplace(pcreCompile("[^/\\\\]+$")
    simplifyFilename(get_filename(piport)) "" 0))

; ============================================================
; 4. Utilities
; ============================================================

procedure(ACL_readFile(path)
  prog((fp text line)
    fp = infile(path)
    unless(fp return(""))
    text = ""
    while(gets(line fp) text = strcat(text line))
    close(fp)
    return(text)))

procedure(ACL_appendChat(text)
  ; Append text with a newline (for distinct messages)
  ACL_logWrite(strcat(text "\n")))

procedure(ACL_appendChatRaw(text)
  ; Append text without newline (for streaming chunks)
  ACL_logWrite(text))

procedure(ACL_logWrite(text)
  ACL_logContent = strcat(ACL_logContent text)
  ; Write to backing file (full history)
  when(ACL_logFile
    let((fp)
      fp = outfile(ACL_logFile "a")
      when(fp fprintf(fp "%s" text) close(fp))))
  ; Update form field (truncated to last N chars)
  when(ACL_form
    let((display)
      if(strlen(ACL_logContent) > ACL_logTruncLimit then
        display = strcat("...\n"
          substring(ACL_logContent
            (strlen(ACL_logContent) - ACL_logTruncLimit + 5)))
      else
        display = ACL_logContent)
      axlFormSetField(ACL_form "chatlog" display))))

procedure(ACL_logReset()
  ACL_logContent = ""
  when(ACL_form axlFormSetField(ACL_form "chatlog" ""))
  when(ACL_logFile
    let((fp) fp = outfile(ACL_logFile) when(fp close(fp)))))

procedure(ACL_showFullLog()
  ; Write full log to file and open in a viewer window
  unless(ACL_logFile
    ACL_logFile = sprintf(nil "%s/acl_log.txt" getTempDir()))
  let((fp)
    fp = outfile(ACL_logFile)
    when(fp
      fprintf(fp "%s" ACL_logContent)
      close(fp)))
  axlUIViewFileCreate(ACL_logFile "Claude - Full Log" nil '(50 120) nil ACL_form))

procedure(ACL_setStatus(text)
  when(ACL_form
    axlFormSetField(ACL_form "statuslabel" text)))

procedure(ACL_buildSystemPrompt()
  ; Read the PROMPT.md template, substitute {{CADENCE_DOC_PATH}} and
  ; {{CADENCE_EXAMPLES_PATH}} with actual Cadence directories, and
  ; return the result.
  let((template installRoot re)
    template = ACL_readFile(strcat(ACL_scriptDir "PROMPT.md"))
    re = pcreCompile("\\{\\{ALLEGRO_CLAUDE_PATH\\}\\}")
    template = pcreReplace(re template ACL_scriptDir 0)
    ; Inject Cadence paths from allegro_install_root
    installRoot = axlGetVariable("allegro_install_root")
    re = pcreCompile("\\{\\{CADENCE_DOC_PATH\\}\\}")
    template = pcreReplace(re template strcat(installRoot "/doc") 0)
    re = pcreCompile("\\{\\{CADENCE_EXAMPLES_PATH\\}\\}")
    pcreReplace(re template strcat(installRoot "/share/pcb/examples") 0)))

procedure(ACL_shellQuote(s)
  ; Wrap s in single quotes for safe shell argument passing.
  ; Escapes embedded single quotes as '\'' (end quote, escaped quote,
  ; reopen quote).
  strcat("'" pcreReplace(pcreCompile("'") s "'\\''" 0) "'"))

; ============================================================
; 5. Session Management
; ============================================================

procedure(ACL_loadSessions()
  let((text parsed)
    text = ACL_readFile(ACL_sessionsFile)
    when(strlen(text) > 0
      parsed = ACL_jParse(text)
      when(parsed car(parsed)))))

procedure(ACL_saveSessions(sessions)
  let((tmp fp)
    createDir(ACL_homeDir)
    tmp = sprintf(nil "%s.tmp.%d" ACL_sessionsFile stringToTime(getCurrentTime()))
    fp = outfile(tmp)
    when(fp
      fprintf(fp "%s\n" ACL_jsonVal(sessions))
      close(fp)
      renameFile(tmp ACL_sessionsFile))))

procedure(ACL_addSession(sid info)
  let((sessions)
    sessions = or(ACL_loadSessions() nil)
    sessions = cons(list(sid info) remove(assoc(sid sessions) sessions))
    ACL_saveSessions(sessions)))

procedure(ACL_getSession(sid)
  cadr(assoc(sid or(ACL_loadSessions() nil))))

procedure(ACL_getBoardSessions(boardPath)
  setof(pair or(ACL_loadSessions() nil)
    ACL_jGet(cadr(pair) "board") == boardPath))

; ============================================================
; 6. Claude Process Management
; ============================================================

procedure(ACL_startClaude(@optional resumeId fork)
  let((cmd promptFile fp)
    ACL_stopClaude()
    ; Write system prompt to a temp file to avoid shell escaping issues
    promptFile = sprintf(nil "%s/acl_prompt.md" getTempDir())
    fp = outfile(promptFile)
    when(fp
      fprintf(fp "%s" ACL_buildSystemPrompt())
      close(fp))
    cmd = strcat(
      "env -u LD_LIBRARY_PATH claude -p"
      " --verbose"
      " --input-format stream-json"
      " --output-format stream-json"
      " --include-partial-messages"
      " --append-system-prompt-file " promptFile
      " --effort " ACL_effort)
    when(resumeId
      cmd = sprintf(nil "%s --resume %s" cmd resumeId)
      when(fork cmd = strcat(cmd " --fork-session")))
    ACL_lineBuf = ""
    ACL_responseBuf = ""
    ACL_displayBuf = ""
    ACL_inExecBlock = nil
    ACL_claude = ipcBeginProcess(cmd ""
      'ACL_claudeDataHandler
      lambda((id data)
        foreach(d parseString(data "\n") printf("claude: %s\n" d))
        axlFlushDisplay()))
    ipcWaitForProcess(ACL_claude)
    unless(and(ACL_claude ipcIsAliveProcess(ACL_claude))
      ACL_setStatus("Failed to start Claude")
      printf("*Error* ACL: claude process failed to start. Command: %s\n" cmd))))

procedure(ACL_stopClaude()
  when(and(ACL_claude ipcIsAliveProcess(ACL_claude))
    ipcSignalProcess(ACL_claude 'TERM))
  ACL_claude = nil)

procedure(ACL_ensureClaude()
  when(and(ACL_claude null(ipcIsAliveProcess(ACL_claude)))
    printf("*Warning* ACL: claude process died (exit status: %L)\n"
      ACL_claude->exitStatus)
    ACL_claude = nil)
  unless(ACL_claude
    ACL_startClaude(ACL_sessionId)))

procedure(ACL_sendToClaude(text)
  ACL_ensureClaude()
  when(ACL_claude
    ipcWriteProcess(ACL_claude strcat(
      ACL_jsonObj(
        list("type" "user")
        list("message" list(
          list("role" "user")
          list("content" text))))
      "\n"))))

; ============================================================
; 7. Stream Event Processing
; ============================================================

procedure(ACL_claudeDataHandler(id data)
  let((pos line)
    ACL_lineBuf = strcat(ACL_lineBuf data)
    pos = nindex(ACL_lineBuf "\n")
    while(pos
      line = substring(ACL_lineBuf 1 (pos - 1))
      ACL_lineBuf = or(substring(ACL_lineBuf (pos + 1)) "")
      when(and(line strlen(line) > 0)
        errset(ACL_processStreamLine(line)))
      pos = nindex(ACL_lineBuf "\n"))))

procedure(ACL_processStreamLine(line)
  prog((parsed etype subtype sid event evtype delta text cblock)
    parsed = ACL_jParse(line)
    unless(parsed return(nil))
    parsed = car(parsed)
    etype = ACL_jGet(parsed "type")
    ; Capture session ID from any event
    ; Capture session ID from any event
    sid = ACL_jGet(parsed "session_id")
    when(and(sid sid != ACL_sessionId)
      ACL_sessionId = sid)
    cond(
      ; System events (init, api_retry, etc.)
      (etype == "system"
        subtype = ACL_jGet(parsed "subtype")
        cond(
          (subtype == "init"
            ACL_setStatus("Connected"))
          (subtype == "status"
            ACL_setStatus("Thinking..."))))
      ; Stream events (text deltas, tool use, etc.)
      (etype == "stream_event"
        event = ACL_jGet(parsed "event")
        when(event
          evtype = ACL_jGet(event "type")
          cond(
            (evtype == "message_start"
              ACL_setStatus("Responding..."))
            (evtype == "content_block_delta"
              delta = ACL_jGet(event "delta")
              when(delta
                cond(
                  (ACL_jGet(delta "type") == "text_delta"
                    text = ACL_jGet(delta "text")
                    when(text
                      ACL_responseBuf = strcat(ACL_responseBuf text)
                      ACL_streamToDisplay(text)
                      ; Save session on first text
                      when(and(null(ACL_sessionSaved) ACL_sessionId
                               axlGetDrawingName())
                        ACL_addSession(ACL_sessionId list(
                          list("board" axlGetDrawingName())
                          list("time" sprintf(nil "%d"
                            stringToTime(getCurrentTime())))))
                        ACL_sessionSaved = t))))))
            (evtype == "content_block_start"
              cblock = ACL_jGet(event "content_block")
              cond(
                (and(cblock ACL_jGet(cblock "type") == "tool_use")
                  ; Force-flush ALL pending display text before tool execution
                  when(and(ACL_displayBuf strlen(ACL_displayBuf) > 0
                           null(ACL_inExecBlock))
                    ACL_appendChatRaw(ACL_displayBuf)
                    ACL_displayBuf = "")
                  ACL_hadToolUse = t
                  ACL_setStatus(sprintf(nil "Using %s..."
                    or(ACL_jGet(cblock "name") "tool"))))
                (and(cblock ACL_jGet(cblock "type") == "text")
                  ; Add separator only if a tool_use occurred since last text
                  when(ACL_hadToolUse
                    ACL_appendChatRaw("\n")
                    ACL_hadToolUse = nil))))
            (evtype == "content_block_stop"
              ACL_setStatus("Thinking...")))))
      ; Assistant message (complete, non-streaming)
      (etype == "assistant"
        let((content block)
          content = ACL_jGet(parsed "content")
          when(content
            foreach(block content
              when(and(block ACL_jGet(block "type") == "text")
                text = ACL_jGet(block "text")
                when(text
                  ACL_responseBuf = strcat(ACL_responseBuf text)
                  ACL_streamToDisplay(text)))))))
      ; Result (response complete)
      (etype == "result"
        ACL_flushDisplay()
        ACL_onResponseComplete()))))

; ============================================================
; 8. Display Streaming
; ============================================================

procedure(ACL_streamToDisplay(text)
  ACL_gotText = t
  ACL_displayBuf = strcat(ACL_displayBuf text)
  ACL_drainDisplayBuf())

procedure(ACL_drainDisplayBuf()
  prog((pos safe)
    while(and(ACL_displayBuf strlen(ACL_displayBuf) > 0)
      if(ACL_inExecBlock then
        pos = nindex(ACL_displayBuf ACL_tagClose)
        unless(pos return(nil))
        ACL_displayBuf = substring(ACL_displayBuf (pos + strlen(ACL_tagClose)))
        ACL_inExecBlock = nil
      else
        pos = nindex(ACL_displayBuf ACL_tagOpen)
        if(pos then
          when(pos > 1
            ACL_appendChatRaw(substring(ACL_displayBuf 1 (pos - 1))))
          ACL_displayBuf = substring(ACL_displayBuf (pos + strlen(ACL_tagOpen)))
          ACL_inExecBlock = t
        else
          safe = strlen(ACL_displayBuf) - strlen(ACL_tagOpen) + 1
          when(safe > 0
            ACL_appendChatRaw(substring(ACL_displayBuf 1 safe))
            ACL_displayBuf = substring(ACL_displayBuf (safe + 1)))
          return(nil))))))

procedure(ACL_flushDisplay()
  when(and(ACL_displayBuf strlen(ACL_displayBuf) > 0 null(ACL_inExecBlock))
    ACL_appendChatRaw(ACL_displayBuf))
  ACL_displayBuf = ""
  ACL_inExecBlock = nil)

; ============================================================
; 9. Execute Block Extraction & Execution
; ============================================================

procedure(ACL_extractExecBlocks(text)
  ; Find all <allegro_execute>...</allegro_execute> blocks in text.
  prog((blocks openLen closeLen rest openPos closePos code)
    openLen = strlen(ACL_tagOpen)
    closeLen = strlen(ACL_tagClose)
    rest = text
    while(and(rest strlen(rest) > 0)
      openPos = nindex(rest ACL_tagOpen)
      unless(openPos return(reverse(blocks)))
      rest = substring(rest (openPos + openLen))
      closePos = nindex(rest ACL_tagClose)
      unless(closePos return(reverse(blocks)))
      code = substring(rest 1 (closePos - 1))
      when(and(code strlen(code) > 0)
        blocks = cons(code blocks))
      rest = substring(rest (closePos + closeLen)))
    return(reverse(blocks))))

procedure(ACL_execBlock(code)
  ; Execute one SKILL block with error handling.
  ; Returns result string including any printed output.
  prog((result err preview output port warnings)
    ; Strip leading/trailing whitespace from code
    while(and(code strlen(code) > 0 ACL_jIsWS(substring(code 1 1)))
      code = substring(code 2))
    while(and(code strlen(code) > 0 ACL_jIsWS(substring(code strlen(code) 1)))
      code = substring(code 1 (strlen(code) - 1)))
    when(or(null(code) strlen(code) == 0)
      return("(empty block)"))
    ACL_setStatus("Executing SKILL...")
    ACL_logCmd(code)
    preview = if(strlen(code) > ACL_logCodeLimit
      strcat(substring(code 1 (ACL_logCodeLimit - 3)) "...")
      code)
    ACL_appendChatRaw(sprintf(nil "[exec: %s]\n" preview))
    ; Execute with:
    ;   poport redirect to capture printf output
    ;   muffleWarnings to capture warnings
    ;   errsetstring to capture errors as strings (nil=suppress console)
    port = outstring()
    err = muffleWarnings(let(((poport port))
      errsetstring(code nil)))
    output = getOutstring(port)
    close(port)
    warnings = getMuffleWarnings()
    ; err is list(result) on success, nil on error
    if(err then
      result = car(err)
    else
      result = sprintf(nil "*error* %L" or(errset.errset "unknown error")))
    ACL_lastCmdTime = stringToTime(getCurrentTime())
    ; Check if axl* functions used are defined
    let((docWarning)
      docWarning = ACL_checkFuncDocs(code)
      return(strcat(
        if(docWarning sprintf(nil "WARNING: %s\n" docWarning) "")
        if(and(warnings length(warnings) > 0)
          sprintf(nil "Warnings:\n%s\n" buildString(warnings "\n")) "")
        if(and(output strlen(output) > 0)
          sprintf(nil "Output:\n%s\n" output) "")
        sprintf(nil "Result: %L" result))))))

procedure(ACL_checkFuncDocs(code)
  ; Check if axl* function names used in code are actually defined.
  ; Returns a warning string if any are undefined, nil if all ok.
  let((missing found pos rest name)
    rest = code
    pos = nindex(rest "axl")
    while(pos
      let((start end)
        start = pos
        end = (pos + 3)
        while(and(end <= strlen(rest)
                  let(((c substring(rest end 1)))
                    nindex("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_" c)))
          end++)
        name = substring(rest start (end - start))
        when(and(name strlen(name) > 3)
          unless(member(name found)
            found = cons(name found)
            unless(fboundp(stringToSymbol(name))
              missing = cons(name missing))))
        rest = substring(rest end))
      pos = when(rest nindex(rest "axl")))
    when(missing
      sprintf(nil "Undefined functions: %s. These do not exist. Read algroskill/algroskill.json to find correct function names."
        buildString(missing ", ")))))
procedure(ACL_logCmd(code)
  ; Log command to file for reference.
  when(ACL_sessionId
    errset(let((logDir fp)
      ACL_cmdSeq++
      logDir = strcat(ACL_logDir "/" ACL_sessionId)
      createDir(ACL_logDir)
      createDir(logDir)
      fp = outfile(sprintf(nil "%s/cmd_%06d.il" logDir ACL_cmdSeq))
      when(fp fprintf(fp "%s\n" code) close(fp))))))

; ============================================================
; 10. Response Complete Handler
; ============================================================

procedure(ACL_formatNumbered(items @optional (prefix ""))
  ; Format list items as numbered lines.
  let((i) i = 0
    mapcar(lambda((item) i++ sprintf(nil "%s%d. %s" prefix i item))
      items)))

procedure(ACL_onResponseComplete()
  let((blocks)
    blocks = ACL_extractExecBlocks(ACL_responseBuf)
    ACL_responseBuf = ""
    cond(
      (and(ACL_mode == "batch" blocks ACL_toolUseRounds == 0)
        ACL_pendingBatch = blocks
        ACL_appendChat(strcat("Proposed commands:\n"
          buildString(ACL_formatNumbered(blocks "  ") "\n")
          "\n\nType 'approve' or 'reject' in the chat input."))
        ACL_setStatus("Awaiting approval..."))
      (blocks
        when(and(ACL_toolUseMax ACL_toolUseRounds >= ACL_toolUseMax)
          ACL_appendChat("(Tool-use loop limit reached.)")
          ACL_setStatus("Ready")
          ACL_isReady = t
          return(nil))
        ; Queue blocks for deferred execution at top level.
        ; evalstring can't run inside a dataHandler -- it needs
        ; the top-level interpreter.
        ACL_execQueue = blocks
        ACL_setStatus("Queued SKILL execution...")
        ; Use a one-shot timer to execute at top level without console output.
        ; axlUIWTimerAdd callback return values are ignored (unlike axlShellPost).
        defvar(ACL_execTimer nil)
        ACL_execTimer = axlUIWTimerAdd(nil 1 t 'ACL_executeQueued))
      (t
        ACL_setStatus("Ready")
        ACL_isReady = t
        ACL_toolUseRounds = 0))))

procedure(ACL_executeQueued(@rest args)
  ; Called by axlUIWTimerAdd (args: window timerId elapsedTime).
  ; Executes queued blocks and sends results back to Claude.
  let((blocks results)
    blocks = ACL_execQueue
    ACL_execQueue = nil
    when(blocks
      results = mapcar('ACL_execBlock blocks)
      ACL_toolUseRounds++
      ACL_setStatus("Thinking...")
      ACL_sendToClaude(strcat("Execution results:\n"
        buildString(ACL_formatNumbered(results "Result ") "\n")
        "\n\nContinue if more commands are needed, "
        "or summarize the outcome.")))))

; ============================================================
; 11. Form Callback
; ============================================================

procedure(ACL_formCB(form)
  prog((field val text)
    field = form->curField
    val = form->curValue
    when(form->doneState == 3  ACL_form = nil  return(t))
    cond(
      (field == "send"
        ACL_doSend(form))
      (field == "mode"
        ACL_mode = val
        ACL_setStatus(sprintf(nil "Mode: %s" val)))
      (field == "effort"
        ACL_effort = val
        when(and(ACL_claude ipcIsAliveProcess(ACL_claude))
          ACL_sendToClaude(sprintf(nil "/effort %s" val)))
        ACL_setStatus(sprintf(nil "Effort: %s" val)))
      (field == "record"
        ACL_toggleRecording(form))
      (field == "context"
        ACL_sendToClaude("/compact"))
      (field == "fulllog"
        ACL_showFullLog())
      (field == "session"
        ACL_handleSessionPick()))))

procedure(ACL_doSend(form)
  let((text)
    text = axlFormGetField(form "userinput")
    when(and(text strlen(text) > 0)
      cond(
        (pcreMatchp(ACL_approveRe text)  ACL_handleApprove())
        (pcreMatchp(ACL_rejectRe text)   ACL_handleReject())
        (t  ACL_appendChat(sprintf(nil "\nYou: %s\n" text))
              ACL_handleUserMessage(text)))
      axlFormSetField(form "userinput" "")
      axlFormSetActiveField(form "userinput"))))

procedure(ACL_toggleRecording(form)
  if(ACL_recording then
    axlJournal("")  ; empty string stops recording
    ACL_recording = nil
    axlFormSetField(form "record" "Record")
    ACL_setStatus("Processing recording...")
    let((contents)
      contents = ACL_readFile(ACL_journalFile)
      when(strlen(contents) > 0
        ACL_handleJournal(contents)))
  else
    ACL_journalFile = sprintf(nil "%s/acl_journal.scr" getTempDir())
    axlJournal(ACL_journalFile)
    ACL_recording = t
    axlFormSetField(form "record" "Done")
    ACL_appendChat(
      "Recording... Perform the action in Allegro, then click Done.")
    ACL_setStatus("Recording macro...")))

; ============================================================
; 12. Message Handlers
; ============================================================

procedure(ACL_handleUserMessage(text)
  ACL_setStatus("Thinking...")
  ACL_responseBuf = ""
  ACL_toolUseRounds = 0
  let((elapsed prefix)
    elapsed = stringToTime(getCurrentTime()) - ACL_lastCmdTime
    prefix = if(and(ACL_lastCmdTime elapsed > 60)
      "[The board may have been edited. Re-query the design instead of relying on memory.] "
      "")
    ACL_sendToClaude(strcat(prefix
      "[ALWAYS CHECK CADENCE DOCUMENTATION BEFORE EXECUTING OR REPLYING] "
      text
      if(ACL_mode == "batch"
        "\n\n[BATCH MODE: List all commands you would execute as <allegro_execute> blocks. I will review and approve first.]"
        "")))))

procedure(ACL_handleApprove()
  when(ACL_pendingBatch
    ACL_setStatus("Executing batch...")
    let((n results i)
      n = length(ACL_pendingBatch)
      i = 0
      results = mapcar(lambda((code)
        i++
        ACL_setStatus(sprintf(nil "Batch %d/%d..." i n))
        let((err result port output)
          ACL_logCmd(code)
          port = outstring()
          err = errset(let(((poport port))
            result = evalstring(code)))
          output = getOutstring(port)
          close(port)
          sprintf(nil "%d. %s%L" i
            if(and(output strlen(output) > 0)
              strcat(output "\n") "")
            if(err result "*error*"))))
        ACL_pendingBatch)
      ACL_appendChat(strcat("Batch results:\n"
        buildString(results "\n")))
      ACL_pendingBatch = nil
      ACL_setStatus("Ready"))))

procedure(ACL_handleReject()
  ACL_pendingBatch = nil
  ACL_appendChat("Batch rejected.")
  ACL_setStatus("Ready"))

procedure(ACL_handleJournal(contents)
  ACL_setStatus("Analyzing recording...")
  ACL_responseBuf = ""
  ACL_sendToClaude(strcat(
    "The user recorded this Allegro macro/journal:\n\n```\n"
    contents "\n```\n\n"
    "Analyze the commands. Explain what the user did step by step. "
    "Generate a reusable SKILL procedure that replicates this action "
    "with parameterized inputs where appropriate.")))

; ============================================================
; 13. Session Management UI
; ============================================================

procedure(ACL_handleSessionPick()
  let((sessions labels sids choice sid board)
    unless(axlGetDrawingName()
      ACL_appendChat("No board file loaded.")
      return(nil))
    sessions = or(ACL_loadSessions() nil)
    unless(sessions
      ACL_appendChat("No previous sessions. Starting new session.")
      ACL_handleNewSession()
      return(nil))
    ; Build parallel lists of labels and session IDs
    sids = mapcar('car sessions)
    labels = mapcar(lambda((entry)
      let((info board time)
        info = cadr(entry)
        board = or(ACL_jGet(info "board") "?")
        time = ACL_jGet(info "time")
        when(and(time numberp(atoi(time)))
          time = timeToString(atoi(time)))
        sprintf(nil "%s  [%s]  (%s)" car(entry) board or(time "?"))))
      sessions)
    labels = cons("New session" labels)
    choice = axlUIMultipleChoice("Select a session" labels "Claude Sessions")
    when(choice
      if(choice == 0 then
        ACL_handleNewSession()
      else
        sid = nth((choice - 1) sids)
        board = or(ACL_jGet(ACL_getSession(sid) "board") "")
        if(board == axlGetDrawingName()
          ACL_handleRestoreSession(sid)
          ACL_handleForkSession(sid))))))

procedure(ACL_handleNewSession()
  ACL_sessionId = nil
  ACL_sessionSaved = nil
  ACL_logReset()
  ACL_startClaude()
  ACL_appendChat("Starting new session...")
  ACL_setStatus("Ready"))

procedure(ACL_handleRestoreSession(sid)
  let((info logDir files)
    info = ACL_getSession(sid)
    if(info then
      ACL_sessionId = sid
      ; Find highest existing command sequence number
      logDir = strcat(ACL_logDir "/" sid)
      ACL_cmdSeq = 0
      files = errset(getDirFiles(logDir))
      when(and(files car(files))
        foreach(f car(files)
          let((m)
            m = errset(atoi(pcreReplace(pcreCompile("^cmd_0*") f "" 0)))
            when(and(m car(m) car(m) > ACL_cmdSeq)
              ACL_cmdSeq = car(m)))))
      ACL_logReset()
      ACL_startClaude(sid)
      ACL_appendChat(sprintf(nil "Restored session: %s" sid))
      ACL_setStatus("Ready")
    else
      ACL_appendChat(sprintf(nil "Session not found: %s" sid)))))

procedure(ACL_handleForkSession(sid)
  prog((info oldBoard)
    info = ACL_getSession(sid)
    unless(info
      ACL_appendChat(sprintf(nil "Session not found: %s" sid))
      return(nil))
    oldBoard = or(ACL_jGet(info "board") "unknown")
    ACL_startClaude(sid t)
    ACL_responseBuf = ""
    ACL_sendToClaude(sprintf(nil
      "The target board has changed from \"%s\" to \"%s\". Disregard any previous design-specific information and re-query the new design as needed."
      oldBoard axlGetDrawingName()))
    ACL_appendChat(sprintf(nil "Forked from session: %s" sid))))

; ============================================================
; 14. Open Panel & Registration
; ============================================================

procedure(ACL_openPanel()
  prog((formFile)
    when(and(ACL_form errset(axlFormDisplay(ACL_form)))
      return(t))
    formFile = strcat(ACL_scriptDir "allegro_claude.form")
    ACL_form = axlFormCreate('ACL_form formFile nil 'ACL_formCB t t)
    when(ACL_form
      axlFormDefaultButton(ACL_form "send")
      axlFormSetField(ACL_form "mode" "auto")
      axlFormSetField(ACL_form "effort" "medium")
      axlFormSetField(ACL_form "statuslabel" "Starting...")
      axlFormDisplay(ACL_form)
      if(ACL_sessionId then
        ACL_ensureClaude()
      else
        let((sessions board)
          board = axlGetDrawingName()
          sessions = when(board ACL_getBoardSessions(board))
          ; FIXME: session loading is janky right now, so bypass
          ;if(sessions then
            ACL_handleSessionPick()
          ;else
          ;  ACL_handleNewSession())
        )))))

axlCmdRegister("claude" 'ACL_openPanel ?cmdType "general")
regExitBefore('ACL_stopClaude)

; ============================================================
; 15. Tests  --  run with:  ACL_runTests()
; ============================================================

defvar(ACL_testPass 0)
defvar(ACL_testFail 0)

procedure(ACL_check(name got expected)
  if(equal(got expected) then
    ACL_testPass++
    printf("  PASS: %s\n" name)
  else
    ACL_testFail++
    printf("  FAIL: %s\n    got:      %L\n    expected: %L\n" name got expected)))

procedure(ACL_runTests()
  ACL_testPass = 0
  ACL_testFail = 0

  printf("\n--- JSON Parser ---\n")
  ; Primitives
  ACL_check("string"       car(ACL_jParse("\"hello\""))        "hello")
  ACL_check("string pos"   cadr(ACL_jParse("\"hello\""))        8)
  ACL_check("empty string" car(ACL_jParse("\"\""))             "")
  ACL_check("escaped str"  car(ACL_jParse("\"a\\nb\\tc\""))    "a\nb\tc")
  ACL_check("escaped quote" car(ACL_jParse("\"say \\\"hi\\\"\"")) "say \"hi\"")
  ACL_check("escaped backslash" car(ACL_jParse("\"a\\\\b\""))  "a\\b")
  ACL_check("integer"      car(ACL_jParse("42"))               42)
  ACL_check("negative"     car(ACL_jParse("-7"))               -7)
  ACL_check("float"        car(ACL_jParse("3.14"))             3.14)
  ACL_check("true"         car(ACL_jParse("true"))             t)
  ACL_check("false"        car(ACL_jParse("false"))            nil)
  ACL_check("null"         car(ACL_jParse("null"))             nil)
  ACL_check("whitespace"   car(ACL_jParse("  42  "))           42)

  ; Objects
  ACL_check("empty obj"    car(ACL_jParse("{}"))               nil)
  ACL_check("simple obj"   ACL_jGet(car(ACL_jParse("{\"a\":1}")) "a")  1)
  let((o)
    o = car(ACL_jParse("{\"x\":10,\"y\":20}"))
    ACL_check("multi obj"  list(ACL_jGet(o "x") ACL_jGet(o "y"))  list(10 20)))
  ACL_check("nested obj"
    ACL_jGet(ACL_jGet(car(ACL_jParse("{\"a\":{\"b\":99}}")) "a") "b")
    99)

  ; Arrays
  ACL_check("empty arr"    car(ACL_jParse("[]"))               nil)
  ACL_check("simple arr"   car(ACL_jParse("[1,2,3]"))          '(1 2 3))
  ACL_check("string arr"   car(ACL_jParse("[\"a\",\"b\"]"))    '("a" "b"))
  ACL_check("nested arr"   car(ACL_jParse("[[1],[2]]"))        '((1) (2)))

  ; Edge cases
  ACL_check("end of str"   ACL_jParse("")                      nil)
  ACL_check("just ws"      ACL_jParse("   ")                   nil)

  printf("\n--- JSON Writer ---\n")
  ACL_check("esc str"      ACL_jsonEscStr("hello")             "\"hello\"")
  ACL_check("esc newline"  ACL_jsonEscStr("a\nb")              "\"a\\nb\"")
  ACL_check("esc quote"    ACL_jsonEscStr("say \"hi\"")        "\"say \\\"hi\\\"\"")
  ACL_check("val string"   ACL_jsonVal("hi")                   "\"hi\"")
  ACL_check("val int"      ACL_jsonVal(42)                     "42")
  ACL_check("val true"     ACL_jsonVal(t)                      "true")
  ACL_check("val nil"      ACL_jsonVal(nil)                    "null")
  ACL_check("val array"    ACL_jsonVal('(1 2 3))               "[1,2,3]")
  ACL_check("jsonObj"
    ACL_jsonObj(list("type" "msg") list("n" 1))
    "{\"type\":\"msg\",\"n\":1}")

  printf("\n--- JSON Roundtrip ---\n")
  let((orig parsed)
    orig = ACL_jsonObj(list("type" "user_message")
                       list("content" "hello\nworld"))
    parsed = car(ACL_jParse(orig))
    ACL_check("rt type"    ACL_jGet(parsed "type")     "user_message")
    ACL_check("rt content" ACL_jGet(parsed "content")  "hello\nworld"))

  printf("\n--- Execute Block Extraction ---\n")
  ACL_check("no blocks"
    ACL_extractExecBlocks("just text")
    nil)
  ACL_check("one block"
    ACL_extractExecBlocks("text<allegro_execute>code1</allegro_execute>more")
    '("code1"))
  ACL_check("nindex close"
    nindex("a</allegro_execute>rest" "</allegro_execute>")
    2)
  ACL_check("substr after close"
    substring("a</allegro_execute>mid" (2 + strlen("</allegro_execute>")))
    "mid")
  ACL_check("extract one"
    ACL_extractExecBlocks("<allegro_execute>a</allegro_execute>")
    '("a"))
  ACL_check("extract one+tail"
    ACL_extractExecBlocks("<allegro_execute>a</allegro_execute>mid")
    '("a"))
  ACL_check("two blocks"
    ACL_extractExecBlocks(
      "<allegro_execute>a</allegro_execute>mid<allegro_execute>b</allegro_execute>")
    '("a" "b"))
  ACL_check("multiline block"
    ACL_extractExecBlocks(
      "<allegro_execute>line1\nline2</allegro_execute>")
    '("line1\nline2"))
  ACL_check("unclosed"
    ACL_extractExecBlocks("text<allegro_execute>dangling")
    nil)

  printf("\n--- SKILL Execution ---\n")
  let(((savedForm ACL_form))
    ACL_form = nil
    ACL_check("exec simple"
      ACL_execBlock("(plus 40 2)")
      "Result: 42")
    ACL_check("exec empty"
      ACL_execBlock("  ")
      "(empty block)")
    ACL_check("exec with output"
      ACL_execBlock("printf(\"hello\\n\") 99")
      "Output:\nhello\n\nResult: 99")
    let((errResult)
      errResult = ACL_execBlock("(undefined_function_xyz)")
      ACL_check("exec error"
        and(nindex(errResult "*error*") t)
        t))
    ACL_form = savedForm)

  printf("\n--- Display Streaming ---\n")
  let(((savedForm ACL_form))
    ACL_form = nil  ; disable log writes for this test
    ACL_displayBuf = ""
    ACL_inExecBlock = nil
    ACL_streamToDisplay("hello world")
    ACL_check("plain text buf" ACL_displayBuf "hello world")
    ACL_displayBuf = ""
    ACL_inExecBlock = nil
    ACL_streamToDisplay("before<allegro_execute>secret</allegro_execute>after")
    ACL_check("after exec strip" ACL_displayBuf "after")
    ACL_displayBuf = ""
    ACL_inExecBlock = nil
    ACL_streamToDisplay("text<allegro_ex")
    ACL_streamToDisplay("ecute>hidden</allegro_execute>end")
    ACL_check("cross-chunk" ACL_displayBuf "end")
    ACL_form = savedForm)

  printf("\n--- Form File ---\n")
  let((formPath formHandle)
    formPath = strcat(ACL_scriptDir "allegro_claude.form")
    formHandle = axlFormCreate('ACL_testForm formPath nil nil nil)
    ACL_check("form parse" and(formHandle t) t)
    when(formHandle axlFormClose(formHandle)))

  printf("\n--- IPC ---\n")
  let((proc buf ready)
    buf = ""
    ready = nil
    ; Spawn a simple echo process to verify IPC round-trip
    proc = ipcBeginProcess("cat" ""
      lambda((id data) buf = strcat(buf data)  ready = t)
      lambda((id data) printf("ipc err: %s\n" data)))
    ipcWaitForProcess(proc)
    ACL_check("ipc spawn" and(proc ipcIsAliveProcess(proc) t) t)
    ; Write and read back
    ipcWriteProcess(proc "hello\n")
    ; Give dataHandler time to fire (may need a brief pause)
    for(i 1 10 unless(ready ipcSleep(1)))
    ACL_check("ipc echo" buf "hello\n")
    ipcKillProcess(proc))

  printf("\n--- Claude Process ---\n")
  let((claudeExists savedEffort)
    claudeExists = errset(system("env -u LD_LIBRARY_PATH which claude > /dev/null 2>&1"))
    if(and(claudeExists car(claudeExists) == 0) then
      ; Use sonnet for faster test response
      savedEffort = ACL_effort
      ACL_effort = "low"
      ACL_startClaude()
      ACL_effort = savedEffort
      ACL_check("claude start" and(ACL_claude ipcIsAliveProcess(ACL_claude) t) t)
      ; End-to-end: send message and wait for response via ipcSleep
      ; ipcSleep processes handlers while waiting
      printf("  Sending hello to Claude...\n")
      ACL_responseBuf = ""
      ACL_sendToClaude("Say exactly: HELLO_TEST_OK")
      ; Wait for response (ipcSleep processes handlers)
      ACL_gotText = nil
      for(i 1 120
        unless(ACL_gotText ipcSleep(1)))
      ACL_check("claude response" ACL_gotText t)
      ; SKILL execution round-trip test:
      ; Ask Claude to use <allegro_execute> to run a SKILL expression
      printf("  Testing SKILL execution round-trip...\n")
      ACL_responseBuf = ""
      ACL_gotText = nil
      ACL_sendToClaude("Execute this SKILL expression using <allegro_execute> tags and report the result: (plus 40 2)")
      for(i 1 120
        unless(ACL_gotText ipcSleep(1)))
      ACL_check("skill exec response" ACL_gotText t)
      ; The response should contain 42 somewhere (from evalstring of (plus 40 2))
      when(ACL_gotText
        printf("  SKILL exec result received\n"))
      ACL_stopClaude()
      ACL_check("claude stop" ACL_claude nil)
    else
      printf("  SKIP: claude not in PATH\n")))

  printf("\n=== Results: %d passed, %d failed ===\n\n" ACL_testPass ACL_testFail))

procedure(ACL_checkTestResponse()
  ; Call this after ACL_runTests() to verify Claude responded.
  ; The dataHandler needs time to process the response.
  printf("\n--- Claude Response Check ---\n")
  printf("  Session ID: %L\n" ACL_sessionId)
  printf("  Response buffer length: %d\n" strlen(ACL_responseBuf))
  printf("  Claude alive: %L\n"
    and(ACL_claude ipcIsAliveProcess(ACL_claude)))
  when(strlen(ACL_responseBuf) > 0
    printf("  Response: %s\n"
      if(strlen(ACL_responseBuf) > 500
        strcat(substring(ACL_responseBuf 1 500) "...")
        ACL_responseBuf)))
  printf("  %s\n"
    if(strlen(ACL_responseBuf) > 0 "PASS" "FAIL (no response yet)")))
