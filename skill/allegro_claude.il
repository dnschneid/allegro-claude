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
;   Claude has an allegro_execute skill that uses a minimal python MCP
;   server to exchange SKILL commands and output via files.

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
  let((start c numStr)
    start = pos
    c = substring(str pos 1)
    while(and(c null(nindex(" \t\n\r,]}" c)))
      pos++
      c = substring(str pos 1))
    when(pos > start
      numStr = substring(str start pos - start)
      when(pcreMatchp(ACL_bignumRe numStr)
        numStr = strcat(numStr ".0"))
      list(evalstring(numStr) pos))))

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

procedure(ACL_assocStr(key alist)
  ; Like assoc but uses equal (string-safe) instead of eq
  prog((rest)
    rest = alist
    while(rest
      when(equal(key caar(rest)) return(car(rest)))
      rest = cdr(rest))))

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
    (v == t      "true")
    (v == 'false "false")
    (null(v)     "null")
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
defvar(ACL_isWindows (getShellEnvVar("OS") == "Windows_NT"))

procedure(ACL_normPath(path)
  if(and(stringp(path) ACL_isWindows)
    pcreReplace(pcreCompile("\\\\") path "/" 0)
    path))

defvar(ACL_fast nil)                ; set to t to skip preloading Allegro docs
defvar(ACL_claudeArgs "")            ; extra flags appended to claude CLI invocation
defvar(ACL_enableRawLog nil)       ; helps with debugging streams
defvar(ACL_form nil)
defvar(ACL_logContent nil)          ; accumulated log chunks (newest first)
defvar(ACL_logTruncLimit 12500)    ; max chars shown in form field
defvar(ACL_resultTruncLimit 150)   ; max chars shown for results in manual mode
defvar(ACL_statusTruncLimit 16)    ; max chars for the status bar to avoid weirdness
defvar(ACL_logLineLimit 50)        ; max lines shown in form field
defvar(ACL_logFile nil)            ; temp file for full log viewer
defvar(ACL_logCodeLimit 250)       ; max chars for each code preview
defvar(ACL_sessionId nil)
defvar(ACL_sessionSaved nil)       ; true after first successful reply
defvar(ACL_mode "auto")
defvar(ACL_lineBuf "")
defvar(ACL_streamErrorCount 0)   ; increments when ACL_processStreamLine throws
defvar(ACL_responseBuf "")
defvar(ACL_lastCmdTime 0)
defvar(ACL_recording nil)
defvar(ACL_journalFile nil)
defvar(ACL_gotText nil)          ; set to t when any text arrives
defvar(ACL_streamingMsgId nil)    ; message ID currently being streamed
defvar(ACL_streamedMsgLen nil)    ; alist of (msgId . textLen) for streamed messages
defvar(ACL_hadToolUse nil)       ; true if tool_use occurred since last text block
defvar(ACL_promptId 1)            ; counter for message UUIDs (combined with launch epoch)
defvar(ACL_uuidEpoch 0)           ; per-launch component to keep uuids unique across restarts
defvar(ACL_resumeIsFork nil)      ; t if the current launch was --fork-session (skip session migrate)
defvar(ACL_synthId 0)             ; counter for synthetic message UUIDs
defvar(ACL_pendingInput nil)      ; text being sent (nil = not queued)
defvar(ACL_autoUpdateInput nil)   ; t to enable auto-polling of input edits

defvar(ACL_approveRe pcreCompile("^\\s*approve\\s*$" pcreGenCompileOptBits(?caseLess t)))
defvar(ACL_rejectRe  pcreCompile("^\\s*reject\\s*$"  pcreGenCompileOptBits(?caseLess t)))
; "No conversation found with session ID: <uuid>" -- claude prints this
; to stderr and exits when --resume is given a session it doesn't have.
defvar(ACL_noSessionRe pcreCompile(
  "No conversation found with session ID: ([0-9a-f-]+)"))
defvar(ACL_bignumRe  pcreCompile("^-?\\d{10,}$"))

defvar(ACL_homeDir  ; use ~/.local/share to help with sandboxing
  strcat(or(getShellEnvVar("XDG_DATA_HOME")
            strcat(or(getShellEnvVar("USERPROFILE") getShellEnvVar("HOME"))
                   "/.local/share"))
         "/allegro_claude"))
defvar(ACL_notesDir       strcat(ACL_homeDir "/notes"))
defvar(ACL_sessionsFile strcat(ACL_homeDir "/sessions.json"))
defvar(ACL_settingsFile strcat(ACL_homeDir "/settings.json"))
defvar(ACL_logDir       strcat(ACL_homeDir "/logs"))
defvar(ACL_sessionLogDir ACL_logDir)

defvar(ACL_scriptDir
  ACL_normPath(pcreReplace(pcreCompile("[^/\\\\]+$")
    simplifyFilename(get_filename(piport)) "" 0)))

; ============================================================
; 4. Utilities
; ============================================================

procedure(ACL_renameOver(src dst)
  ; renameFile fails on Windows if dst exists. Atomic on POSIX.
  when(and(ACL_isWindows isFile(dst)) errset(deleteFile(dst)))
  renameFile(src dst))

procedure(ACL_createDirP(path)
  ; mkdir -p: createDir doesn't recurse, so walk parents first.
  when(and(strlen(path) > 0 null(isDir(path)))
    ACL_createDirP(pcreReplace(pcreCompile("/[^/]+$") path "" 0))
    createDir(path)))

procedure(ACL_readFile(path)
  prog((fp text line)
    fp = infile(path)
    unless(fp return(""))
    text = ""
    while(gets(line fp) text = strcat(text line))
    close(fp)
    return(text)))

procedure(ACL_appendChat(text)
  ACL_logWrite(strcat(text "\n")))

procedure(ACL_logWrite(text)
  ; Stores one line per list entry. Partial lines appended via rplaca.
  ; Suppresses consecutive blank lines.
  let((rest nlPos pre partial)
    rest = text
    while(and(rest strlen(rest) > 0)
      partial = and(ACL_logContent
                    substring(car(ACL_logContent) strlen(car(ACL_logContent)) 1) != "\n")
      nlPos = nindex(rest "\n")
      if(nlPos then
        pre = substring(rest 1 nlPos)
        cond(
          (partial
            rplaca(ACL_logContent strcat(car(ACL_logContent) pre)))
          (or(pre != "\n" car(ACL_logContent) != "\n")
            ACL_logContent = cons(pre ACL_logContent)))
        rest = substring(rest (nlPos + 1))
      else
        if(partial then
          rplaca(ACL_logContent strcat(car(ACL_logContent) rest))
        else
          ACL_logContent = cons(rest ACL_logContent))
        rest = nil)))
  when(ACL_form
    axlFormSetField(ACL_form "chatlog" ACL_logTail(ACL_logLineLimit))))

procedure(ACL_logString()
  buildString(reverse(ACL_logContent) ""))

procedure(ACL_logTail(n)
  prog((lines count result chunk)
    lines = ACL_logContent
    count = 0
    result = ""
    while(and(lines count < n)
      chunk = car(lines)
      when(strlen(result) + strlen(chunk) > ACL_logTruncLimit
        return(strcat("...\n" result)))
      result = strcat(chunk result)
      when(substring(chunk strlen(chunk) 1) == "\n"
        count++)
      lines = cdr(lines))
    return(if(lines strcat("...\n" result) result))))

procedure(ACL_logReset()
  ACL_logContent = nil
  when(ACL_form axlFormSetField(ACL_form "chatlog" "")))

procedure(ACL_showFullLog()
  ; Write full log to file and open in a viewer window
  let((logfile fp)
    logfile = strcat(ACL_sessionLogDir "/log.txt")
    fp = outfile(logfile)
    when(fp
      fprintf(fp "%s" ACL_logString())
      close(fp)
    axlUIViewFileCreate(logfile "Claude - Full Log" nil '(50 120) nil ACL_form))))

procedure(ACL_setStatus(text)
  when(ACL_form
    axlFormSetField(ACL_form "statuslabel"
      if((strlen(text) > ACL_statusTruncLimit)
        strcat(substring(text 1 ACL_statusTruncLimit-3) "...")
        text))))

procedure(ACL_buildSystemPrompt()
  ; Read the PROMPT.md template, substitute $ALLEGRO_INSTALL_ROOT and
  ; $ALLEGRO_CLAUDE_PATH with actual directories, and return the result.
  let((template installRoot re)
    template = ACL_readFile(strcat(ACL_scriptDir "PROMPT.md"))
    template = strcat(template "\n\n" ACL_readFile(strcat(ACL_scriptDir "LESSONS.md")))
    when(isFile(strcat(ACL_notesDir "/LESSONS.md"))
      template = strcat(template "\n\n" ACL_readFile(strcat(ACL_notesDir "/LESSONS.md"))))
    ; Inject paths
    re = pcreCompile("[$]ALLEGRO_CLAUDE_NOTES")
    template = pcreReplace(re template ACL_notesDir 0)
    re = pcreCompile("[$]ALLEGRO_INSTALL_ROOT")
    installRoot = ACL_normPath(axlGetVariable("allegro_install_root"))
    template = pcreReplace(re template installRoot 0)
    ; Platform-specific
    when(ACL_isWindows
      template = strcat(template "\n\n"
        "## Output Encoding\n\n"
        "**Only use ASCII characters in responses.** Do not use Unicode "
        "characters such as curly quotes, em dashes, bullets, or other "
        "non-ASCII glyphs. Use straight quotes, `--`, and `*` instead."))
    template))

procedure(ACL_shellQuote(s)
  if(ACL_isWindows
    strcat("\"" pcreReplace(pcreCompile("\"") s "\\\"" 0) "\"")
    strcat("'" pcreReplace(pcreCompile("'") s "'\\''" 0) "'")))

; ============================================================
; 4b. Settings Persistence
; ============================================================

procedure(ACL_loadSettings(path)
  let((text parsed)
    text = ACL_readFile(path)
    when(strlen(text) > 0
      parsed = ACL_jParse(text)
      when(parsed car(parsed)))))

procedure(ACL_saveSettings(path settings)
  let((tmp fp)
    tmp = sprintf(nil "%s.tmp.%d" path stringToTime(getCurrentTime()))
    fp = outfile(tmp)
    when(fp
      fprintf(fp "%s\n" ACL_jsonVal(settings))
      close(fp)
      ACL_renameOver(tmp path))))

procedure(ACL_currentSettings()
  list(list("mode" ACL_mode)
       list("fast" or(ACL_fast 'false))
       list("claudeArgs" or(ACL_claudeArgs ""))))

procedure(ACL_applySettings(settings)
  let((val)
    val = ACL_jGet(settings "mode")
    when(val
      ACL_mode = val
      when(ACL_form axlFormSetField(ACL_form "mode" val))))
  ACL_fast = ACL_jGet(settings "fast")
  let((ca)
    ca = ACL_jGet(settings "claudeArgs")
    when(stringp(ca) ACL_claudeArgs = ca))
)

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
    tmp = sprintf(nil "%s.tmp.%d" ACL_sessionsFile stringToTime(getCurrentTime()))
    fp = outfile(tmp)
    when(fp
      fprintf(fp "%s\n" ACL_jsonVal(sessions))
      close(fp)
      ACL_renameOver(tmp ACL_sessionsFile))))

procedure(ACL_addSession(sid info)
  let((sessions)
    sessions = or(ACL_loadSessions() nil)
    sessions = cons(list(sid info) remove(assoc(sid sessions) sessions))
    ACL_saveSessions(sessions)))

procedure(ACL_removeSession(sid)
  let((sessions)
    sessions = or(ACL_loadSessions() nil)
    sessions = remove(assoc(sid sessions) sessions)
    ACL_saveSessions(sessions)))

procedure(ACL_handleStaleSession(stderrLine)
  ; Called from the stderr handler when claude reports an unknown
  ; --resume id. Strip the id from sessions.json so we don't try to
  ; restore it next time, and clear ACL_sessionId so the next
  ; ACL_ensureClaude starts fresh instead of looping on the bad id.
  when(pcreMatchp(ACL_noSessionRe stderrLine)
    let((sid)
      sid = pcreSubstitute(ACL_noSessionRe "\\1")
      when(and(stringp(sid) strlen(sid) > 0)
        printf("ACL: removing stale session id %s from sessions.json\n" sid)
        ACL_removeSession(sid)
        when(ACL_sessionId == sid
          ACL_sessionId = nil)))))

procedure(ACL_getSession(sid)
  cadr(assoc(sid or(ACL_loadSessions() nil))))

procedure(ACL_getBoardSessions(boardPath)
  let((normBoard)
    normBoard = ACL_normPath(boardPath)
    setof(pair or(ACL_loadSessions() nil)
      ACL_normPath(ACL_jGet(cadr(pair) "board")) == normBoard)))

procedure(ACL_sortSessionsByTime(sessions)
  ; Sort session entries newest-first by their "time" field.
  ; Each entry is (sid info-alist); time is a string-encoded epoch second.
  sort(copy(sessions)
    lambda((a b)
      let((ta tb)
        ta = atoi(or(ACL_jGet(cadr(a) "time") "0"))
        tb = atoi(or(ACL_jGet(cadr(b) "time") "0"))
        ta > tb))))

; ============================================================
; 6. Claude Process Management
; ============================================================

procedure(ACL_startClaude(@optional resumeId fork)
  let((cmd promptFile fp installRoot projectDir args mcpConfigFile)
    ACL_stopClaude()
    ACL_createDirP(ACL_homeDir)
    createDir(ACL_notesDir)
    createDir(ACL_logDir)
    ACL_mcpPending = nil
    ACL_mcpCmdSeq = 0
    ; Write MCP config for Claude CLI. Pass the base log dir; the MCP
    ; server discovers its session UUID from CLAUDE_LAUNCHER_SESSION_FILE
    ; and constructs the same per-session subdirectory.
    mcpConfigFile = ACL_normPath(strcat(ACL_homeDir "/mcp_config.json"))
    fp = outfile(mcpConfigFile)
    when(fp
      fprintf(fp "%s" ACL_jsonObj(list("mcpServers"
        list(list("allegro" list(
          list("command" if(ACL_isWindows "python" "python3"))
          list("args" list(ACL_normPath(strcat(ACL_scriptDir "allegro_mcp.py"))))
          list("env" list(list("ALLEGRO_MCP_DIR" ACL_normPath(ACL_logDir))))))))))
      close(fp))
    promptFile = ACL_normPath(strcat(ACL_homeDir "/PROMPT.md"))
    fp = outfile(promptFile)
    when(fp
      fprintf(fp "%s" ACL_buildSystemPrompt())
      ; Claude only honors the LAST --append-system-prompt-file flag,
      ; so the cached docs (if any) get concatenated onto our own
      ; prompt and passed via a single flag.
      unless(ACL_fast
        let((doc)
          doc = ACL_findOrPlanDocs()
          when(isFile(doc)
            fprintf(fp "\n\n%s" ACL_readFile(doc)))))
      close(fp))
    installRoot = ACL_normPath(axlGetVariable("allegro_install_root"))
    siteDir = ACL_normPath(axlGetVariable("allegro_site"))
    pcbenvDir = or(ACL_normPath(axlGetVariable("allegro_pcbenv"))
                   strcat(or(getShellEnvVar("HOME")
                             getShellEnvVar("USERPROFILE")) "/pcbenv"))
    projectDir = ACL_normPath(pcreReplace(pcreCompile("[^/\\\\]+$")
      simplifyFilename(axlGetDrawingName()) "" 0))
    args = list(
      if(ACL_isWindows "claude -p" "env -u LD_LIBRARY_PATH claude -p")
      "--verbose"
      "--input-format stream-json"
      "--output-format stream-json"
      "--include-partial-messages"
      "--replay-user-messages"
      "--append-system-prompt-file" ACL_shellQuote(promptFile)
      "--mcp-config" ACL_shellQuote(mcpConfigFile)
      "--add-dir" ACL_shellQuote(installRoot)
      "--add-dir" ACL_shellQuote(ACL_homeDir)
      "--add-dir" ACL_shellQuote(ACL_scriptDir)
      "--add-dir" ACL_shellQuote(siteDir)
      "--add-dir" ACL_shellQuote(pcbenvDir)
      "--add-dir" ACL_shellQuote(projectDir)
      "--allowedTools" ACL_shellQuote(strcat(
        "Edit(" ACL_notesDir "/*),mcp__allegro__allegro_execute"))
      "--disallowedTools" "AskUserQuestion"
      "--model" "opus[1m]"
      "--effort" "max")
    ACL_resumeIsFork = and(resumeId fork t)
    when(resumeId
      args = append1(args "--resume")
      args = append1(args resumeId)
      when(fork args = append1(args "--fork-session")))
    cmd = buildString(args " ")
    when(and(stringp(ACL_claudeArgs) strlen(ACL_claudeArgs) > 0)
      cmd = strcat(cmd " " ACL_claudeArgs))
    let((fp) fp = outfile(strcat(ACL_homeDir "/raw.log") "a")
      when(fp fprintf(fp "\n--- %s ---\n" getCurrentTime()) close(fp)))
    ACL_lineBuf = ""
    ACL_responseBuf = ""
    ACL_streamingMsgId = nil
    ACL_streamedMsgLen = nil
    ACL_promptId = 1
    ACL_uuidEpoch = stringToTime(getCurrentTime())
    ACL_pendingInput = nil
    ACL_claude = ipcBeginProcess(cmd ""
      'ACL_claudeDataHandler
      lambda((id data)
        foreach(d parseString(data "\n")
          printf("claude: %s\n" d)
          ACL_handleStaleSession(d))
        axlFlushDisplay()))
    ipcWaitForProcess(ACL_claude)
    unless(and(ACL_claude ipcIsAliveProcess(ACL_claude))
      ACL_setStatus("Failed to initialize!")
      printf("*Error* ACL: claude process failed to start. Command: %s\n" cmd))))

procedure(ACL_stopClaude()
  when(and(ACL_claude ipcIsAliveProcess(ACL_claude))
    ipcSignalProcess(ACL_claude 'TERM))
  ACL_claude = nil
  ACL_pendingInput = nil
  when(ACL_form axlFormSetField(ACL_form "send" "Send")))

procedure(ACL_ensureClaude()
  when(and(ACL_claude null(ipcIsAliveProcess(ACL_claude)))
    printf("*Warning* ACL: claude process died (exit status: %L)\n"
      ACL_claude->exitStatus)
    ACL_claude = nil)
  unless(ACL_claude
    ACL_startClaude(ACL_sessionId)))

procedure(ACL_sendMessage(text @key (uuid nil) (isSynthetic nil) (noQuery nil))
  ACL_ensureClaude()
  when(ACL_claude
    let((pairs)
      pairs = list(
        list("type" "user")
        list("message" list(
          list("role" "user")
          list("content" text))))
      when(and(isSynthetic null(uuid))
        ACL_synthId++
        uuid = sprintf(nil "synth%d" ACL_synthId))
      when(uuid pairs = append(pairs list(list("uuid" uuid))))
      when(isSynthetic pairs = append(pairs list(list("isSynthetic" t))))
      when(noQuery pairs = append(pairs list(list("shouldQuery" 'false))))
      ipcWriteProcess(ACL_claude strcat(ACL_jsonVal(pairs) "\n")))))

; ============================================================
; 6b. MCP File IPC
;
; SKILL extracts the code from claude's tool_use stream block, runs it
; locally, and writes the result to a file the Python MCP server polls.
; cmd_NNN.il / cmd_NNN.out files in ACL_sessionLogDir form a readable
; per-session log of every executed command.
; ============================================================

; Pending tool calls captured from the stream, waiting for top-level
; execution. Each entry: (tool_use_id code seq).
defvar(ACL_mcpPending nil)
defvar(ACL_mcpExecTimer nil)
defvar(ACL_mcpCmdSeq 0)

procedure(ACL_handleToolCall(block)
  ; Called from the stream handler when a complete tool_use block for
  ; our allegro_execute tool arrives. Logs the command and queues it
  ; for top-level execution -- we can't run ACL_execBlock here because
  ; evalstring inside a dataHandler deadlocks.
  ;
  ; The cmd_<seq>.il file is written here in stream context (which is
  ; single-threaded with respect to other stream events), so the
  ; readable log can't get interleaved oddly even if execution hangs.
  let((toolId input code seq)
    toolId = ACL_jGet(block "id")
    input = ACL_jGet(block "input")
    code = when(input ACL_jGet(input "code"))
    when(and(stringp(toolId) stringp(code))
      ACL_mcpCmdSeq = ACL_mcpCmdSeq + 1
      seq = ACL_mcpCmdSeq
      when(ACL_mode != "quiet"
        ACL_logWrite(sprintf(nil "\n\n[exec: %s]\n\n"
          if(and(ACL_mode != "verbose"
                 strlen(code) > ACL_logCodeLimit)
            strcat(substring(code 1 (ACL_logCodeLimit - 3)) "...")
            code))))
      when(ACL_sessionLogDir
        ACL_mcpWriteFile(sprintf(nil "%s/cmd_%d.il" ACL_sessionLogDir seq) code))
      ACL_mcpPending = append(ACL_mcpPending list(list(toolId code seq)))
      unless(ACL_mcpExecTimer
        ACL_mcpExecTimer = axlUIWTimerAdd(nil 1 t 'ACL_mcpDrainPending)))))

procedure(ACL_mcpDrainPending(@rest args)
  ACL_mcpExecTimer = nil
  let((pending)
    pending = ACL_mcpPending
    ACL_mcpPending = nil
    foreach(entry pending
      let((toolId code seq result ipcOutPath)
        toolId = car(entry)
        code = cadr(entry)
        seq = caddr(entry)
        result = errset(ACL_execBlock(code))
        result = if(result car(result)
          "*error* SKILL execution failed unexpectedly")
        when(ACL_sessionLogDir
          ACL_mcpWriteFile(sprintf(nil "%s/cmd_%d.out" ACL_sessionLogDir seq) result)
          ; The IPC file the Python MCP server polls for: keyed by
          ; tool_use_id. Atomic publish via temp + rename.
          ipcOutPath = sprintf(nil "%s/tool_%s.out" ACL_sessionLogDir toolId)
          ACL_mcpWriteFile(strcat(ipcOutPath ".tmp") result)
          ACL_renameOver(strcat(ipcOutPath ".tmp") ipcOutPath))))))

procedure(ACL_mcpWriteFile(path content)
  let((fp)
    fp = outfile(path)
    when(fp
      fprintf(fp "%s" content)
      close(fp))))

procedure(ACL_copyDirFiles(srcDir dstDir)
  ; Copy regular files (skip dotfiles like . and ..) from srcDir into
  ; dstDir, which must already exist. Used when forking a session so
  ; the fork inherits the parent's readable cmd_<n>.il / .out logs
  ; without stealing them.
  let((files in out line)
    files = errset(getDirFiles(srcDir))
    when(and(files car(files))
      foreach(f car(files)
        when(and(f f != "." f != "..")
          in = infile(strcat(srcDir "/" f))
          out = outfile(strcat(dstDir "/" f))
          when(and(in out)
            while(gets(line in) fprintf(out "%s" line))
            close(in) close(out)))))))

procedure(ACL_mcpScanMaxSeq(dir)
  ; Find the highest N from cmd_<N>.il files in dir, so a restored
  ; session continues numbering instead of overwriting prior logs.
  let((files high re m n)
    high = 0
    re = pcreCompile("^cmd_(\\d+)\\.il$")
    files = errset(getDirFiles(dir))
    when(and(files car(files))
      foreach(f car(files)
        when(pcreMatchp(re f)
          m = pcreSubstitute(re "\\1")
          n = atoi(m)
          when(and(n n > high) high = n))))
    high))

; ============================================================
; 7. Stream Event Processing
; ============================================================

procedure(ACL_claudeDataHandler(id data)
  let((pos line)
    when(ACL_enableRawLog
      let((fp)
        fp = outfile(strcat(ACL_homeDir "/raw.log") "a")
        when(fp fprintf(fp "%s" data) close(fp))))
    ACL_lineBuf = strcat(ACL_lineBuf data)
    pos = nindex(ACL_lineBuf "\n")
    while(pos
      line = substring(ACL_lineBuf 1 (pos - 1))
      ACL_lineBuf = or(substring(ACL_lineBuf (pos + 1)) "")
      when(and(line strlen(line) > 0)
        unless(errset(ACL_processStreamLine(line))
          ACL_streamErrorCount++
          printf("*Warning* ACL: stream error: %L\n" errset.errset)
          axlFlushDisplay()))
      pos = nindex(ACL_lineBuf "\n"))))

procedure(ACL_processStreamLine(line)
  prog((parsed etype subtype sid event evtype delta text cblock)
    parsed = ACL_jParse(line)
    unless(parsed return(nil))
    parsed = car(parsed)
    etype = ACL_jGet(parsed "type")
    subtype = ACL_jGet(parsed "subtype")
    ; Capture the session id from the `system/init` event. Other
    ; events either don't carry a sid (stream events) or carry a
    ; transient per-hook id (SessionStart hook events) that would
    ; trip the new-session branch below spuriously.
    sid = when(and(etype == "system" subtype == "init")
      ACL_jGet(parsed "session_id"))
    when(sid
      ; New sid (fresh session or fork) -- set up the log dir, copying
      ; parent files for forks. Same sid (resume) -- nothing to do
      ; here, the dir already exists.
      when(sid != ACL_sessionId
        let((newDir oldDir)
          newDir = strcat(ACL_logDir "/" sid)
          oldDir = when(ACL_sessionId strcat(ACL_logDir "/" ACL_sessionId))
          ACL_sessionId = sid
          createDir(ACL_logDir)
          createDir(newDir)
          ; Fork (--fork-session): claude assigns a fresh sid distinct
          ; from the parent. Copy parent log files into the fork's dir
          ; so the new session inherits the readable history. The
          ; parent's sessions.json entry is left alone; the fork
          ; registers itself on its first text response under the
          ; CURRENT board (handleForkSession reset ACL_sessionSaved).
          when(and(ACL_resumeIsFork oldDir isDir(oldDir))
            ACL_copyDirFiles(oldDir newDir))
          ACL_sessionLogDir = newDir))
      ; Always seed cmd seq from existing files: critical for resume
      ; (sid didn't change so the block above is a no-op) and harmless
      ; for fresh sessions (dir is empty). Forks land here too after
      ; the parent files were copied.
      ACL_mcpCmdSeq = ACL_mcpScanMaxSeq(ACL_sessionLogDir))
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
              let((msg msgId)
                msg = ACL_jGet(event "message")
                msgId = when(msg ACL_jGet(msg "id"))
                ACL_streamingMsgId = msgId
                when(and(msgId null(ACL_assocStr(msgId ACL_streamedMsgLen)))
                  ACL_streamedMsgLen = cons(list(msgId 0) ACL_streamedMsgLen)))
              ACL_setStatus("Responding..."))
            (evtype == "content_block_delta"
              delta = ACL_jGet(event "delta")
              when(delta
                cond(
                  (ACL_jGet(delta "type") == "text_delta"
                    text = ACL_jGet(delta "text")
                    when(text
                      ; Track streamed text length per message
                      when(ACL_streamingMsgId
                        let((entry)
                          entry = assoc(ACL_streamingMsgId ACL_streamedMsgLen)
                          when(entry
                            rplaca(cdr(entry) (cadr(entry) + strlen(text))))))
                      ACL_responseBuf = strcat(ACL_responseBuf text)
                      ACL_streamToDisplay(text)
                      ; Save session on first text
                      when(and(null(ACL_sessionSaved) ACL_sessionId
                               axlGetDrawingName())
                        ACL_addSession(ACL_sessionId list(
                          list("board" ACL_normPath(axlGetDrawingName()))
                          list("time" sprintf(nil "%d"
                            stringToTime(getCurrentTime())))))
                        ACL_sessionSaved = t
                        ; Tell claude where its prior commands live so it
                        ; can grep them instead of re-running discovery.
                        ACL_sendMessage(sprintf(nil
                          "[Your past SKILL commands and outputs from this session live in %s. Each cmd_<n>.il has a matching cmd_<n>.out. Grep these instead of re-running discovery.]"
                          ACL_sessionLogDir)
                          ?isSynthetic t ?noQuery t)))))))
            (evtype == "content_block_start"
              cblock = ACL_jGet(event "content_block")
              cond(
                (and(cblock ACL_jGet(cblock "type") == "tool_use")
                  ACL_hadToolUse = t
                  ACL_setStatus(sprintf(nil "Using %s..."
                    pcreReplace(pcreCompile("^.*__")
                      or(ACL_jGet(cblock "name") "tool") "" 0))))
                (and(cblock ACL_jGet(cblock "type") == "text")
                  ; Add separator only if a tool_use occurred since last text
                  when(ACL_hadToolUse
                    ACL_logWrite("\n")
                    ACL_hadToolUse = nil))))
            (evtype == "content_block_stop"
              ACL_setStatus("Thinking...")))))
      ; Assistant message (complete, non-streaming). Skip text already
      ; received via streaming; only display new content beyond what
      ; was streamed for this message ID.
      (etype == "assistant"
        let((msg content block msgId entry seenLen fullText newText)
          msg = ACL_jGet(parsed "message")
          msgId = when(msg ACL_jGet(msg "id"))
          entry = when(msgId ACL_assocStr(msgId ACL_streamedMsgLen))
          seenLen = if(entry cadr(entry) 0)
          content = when(msg ACL_jGet(msg "content"))
          when(content
            fullText = ""
            foreach(block content
              when(and(block ACL_jGet(block "type") == "text")
                text = ACL_jGet(block "text")
                when(text fullText = strcat(fullText text)))
              ; Tool calls for our allegro_execute MCP tool can be
              ; satisfied locally -- we extract the code from the
              ; stream and execute it ourselves, writing the result
              ; where the Python MCP server polls for it. This
              ; eliminates the SKILL queue-poll loop and the round
              ; trip through Python's queue/cmd file write.
              when(and(block ACL_jGet(block "type") == "tool_use"
                       ACL_jGet(block "name") == "mcp__allegro__allegro_execute")
                ACL_handleToolCall(block)))
            when(strlen(fullText) > seenLen
              newText = substring(fullText (seenLen + 1))
              when(and(newText strlen(newText) > 0)
                ACL_responseBuf = strcat(ACL_responseBuf newText)
                ACL_streamToDisplay(newText))
              when(entry
                rplaca(cdr(entry) strlen(fullText)))))))
      ; Replayed messages: skip synthetic, show everything else
      (etype == "user"
        let((uuid msg content)
          uuid = or(ACL_jGet(parsed "uuid") "")
          msg = ACL_jGet(parsed "message")
          content = when(msg ACL_jGet(msg "content"))
          when(and(content stringp(content))
            unless(substring(uuid 1 5) == "synth"
              cond(
                (and(ACL_autoUpdateInput substring(uuid 1 4) == "user")
                  ACL_promptId++
                  ACL_pendingInput = nil
                  when(ACL_form
                    axlFormSetField(ACL_form "userinput" "")
                    axlFormSetField(ACL_form "send" "Send")
                    axlFormSetActiveField(ACL_form "userinput"))
                  ACL_appendChat(sprintf(nil "\n\nYou: %s\n" content)))
                (substring(uuid 1 4) != "user"
                  let((stripped)
                    stripped = pcreReplace(
                      pcreCompile("<[^>]+>") content "" 0)
                    ACL_setStatus(stripped)
                    ACL_appendChat(sprintf(nil "\n[%s]" stripped)))))))))
      ; Result (response complete)
      (etype == "result"
        ACL_flushDisplay()
        ACL_onResponseComplete()))))

; ============================================================
; 8. Display Streaming
; ============================================================

procedure(ACL_streamToDisplay(text)
  ACL_gotText = t
  ACL_logWrite(text))

procedure(ACL_flushDisplay()
  nil)

; ============================================================
; 9. SKILL Execution
; ============================================================

procedure(ACL_stripWS(code)
  pcreReplace(pcreCompile("^\\s+|\\s+$") code "" 0))

procedure(ACL_execBlock(code)
  ; Execute one SKILL block with error handling.
  ; Returns result string including any printed output.
  prog((result errInfo errMsg output port warnings shellMsgs jfile)
    when(or(null(code) strlen(code) == 0)
      return("(empty block)"))
    ; Check if axl* functions used are defined
    let((docError)
      docError = ACL_checkFuncDocs(code)
      when(docError
        return(sprintf(nil "ERROR: %s" docError))))
    ACL_setStatus("Executing SKILL")
    ; Capture Allegro shell messages via a temporary journal. This is
    ; the only mechanism that catches errors from axlShell sub-commands
    ; AND axlMsgPut output (errport/poport/errset/muffleWarnings/
    ; axlMsgContext all miss them). Skip if the user has a recording
    ; active -- we can't have two journals.
    unless(ACL_recording
      jfile = strcat(ACL_sessionLogDir "/exec_journal.scr")
      errset(axlJournal(jfile)))
    ; Execute with:
    ;   poport redirect to capture printf output
    ;   muffleWarnings to capture warnings
    ;   errsetstring to capture errors as strings (nil=suppress console)
    ; CRITICAL: capture errset.errset before doing anything else --
    ; subsequent SKILL operations clobber it.
    port = outstring()
    result = muffleWarnings(let(((poport port))
      errsetstring(code nil)))
    errInfo = errset.errset
    output = getOutstring(port)
    close(port)
    warnings = getMuffleWarnings()
    ; Stop journal and parse messages
    when(jfile
      errset(axlJournal('close))
      shellMsgs = ACL_readJournalMsgs(jfile))
    ; result is list(result) on success, nil on error
    if(result then
      result = sprintf(nil "Result: %L" car(result))
    else
      ; errInfo format: ("funcName" lineNum t nil ("*Error* full message"))
      errMsg = if(and(errInfo listp(errInfo) length(errInfo) >= 5
                      listp(nth(4 errInfo)))
        car(nth(4 errInfo))
        "*error* unknown error")
      result = errMsg)
    ACL_lastCmdTime = stringToTime(getCurrentTime())
    return(strcat(
      if(and(shellMsgs strlen(shellMsgs) > 0)
        sprintf(nil "Allegro messages:\n%s\n" shellMsgs) "")
      if(and(warnings length(warnings) > 0)
        sprintf(nil "Warnings:\n%s\n" buildString(warnings "\n")) "")
      if(and(output strlen(output) > 0)
        sprintf(nil "Output:\n%s\n" output) "")
      result))))

procedure(ACL_readJournalMsgs(path)
  ; Pull message lines from an Allegro journal. Lines start with "\\t "
  ; (info: axlMsgPut output) or "\\e " (errors). Skip the journal
  ; header/footer (start/end markers, host info, version banner).
  let((fp line out msg trimmed)
    out = ""
    fp = infile(path)
    when(fp
      while(gets(line fp)
        when(or(substring(line 1 3) == "\\t " substring(line 1 3) == "\\e ")
          ; Strip "\t (HH:MM:SS) " or "\e (HH:MM:SS) " prefix
          msg = pcreReplace(pcreCompile("^\\\\[te] \\(\\d+:\\d+:\\d+\\) ?")
            line "" 0)
          trimmed = pcreReplace(pcreCompile("^\\s+|\\s+$") msg "" 0)
          ; Skip journal boilerplate lines
          unless(or(strlen(trimmed) == 0
                    pcreMatchp(pcreCompile("^(allegro [0-9]|Host=|CmdLine=|Journal (start|end))") trimmed))
            out = strcat(out trimmed "\n"))))
      close(fp))
    out))

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
      sprintf(nil "Undefined functions: %s. These do not exist. Check the Allegro documentation."
        buildString(missing ", ")))))

; ============================================================
; 10. Response Complete Handler
; ============================================================

procedure(ACL_onResponseComplete()
  ACL_responseBuf = ""
  ACL_setStatus("Ready"))

; ============================================================
; 11. Form Callback
; ============================================================

procedure(ACL_formCB(form)
  prog((field val)
    field = form->curField
    val = form->curValue
    when(form->doneState == 3  ACL_form = nil  return(t))
    cond(
      (field == "send"
        ACL_doSend(form))
      (field == "userinput"
        ; If queued and text changed, re-send with same UUID
        when(ACL_pendingInput
          when((val != ACL_pendingInput)
            ACL_pendingInput = val
            ACL_sendMessage(val ?uuid sprintf(nil "user%d-%d" ACL_uuidEpoch ACL_promptId)))))
      (field == "mode"
        ACL_mode = val
        ACL_saveSettings(ACL_settingsFile ACL_currentSettings())
        when(ACL_sessionLogDir
          ACL_saveSettings(strcat(ACL_sessionLogDir "/settings.json") ACL_currentSettings()))
        ACL_setStatus(sprintf(nil "Mode: %s" val)))
      (field == "record"
        ACL_toggleRecording(form))
      (field == "fulllog"
        ACL_showFullLog())
      (field == "loglines"
        let((n)
          n = atoi(val)
          when(and(n n > 0)
            ACL_logLineLimit = n
            ; Redisplay with new limit
            ACL_logWrite(""))))
      (field == "session"
        ACL_handleSessionPick()))))

procedure(ACL_doSend(form)
  let((text)
    text = axlFormGetField(form "userinput")
    when(and(text strlen(text) > 0)
      cond(
        (pcreMatchp(ACL_approveRe text)
          axlFormSetField(form "userinput" "")
          axlFormSetActiveField(form "userinput")
          ACL_handleApprove())
        (pcreMatchp(ACL_rejectRe text)
          axlFormSetField(form "userinput" "")
          axlFormSetActiveField(form "userinput")
          ACL_handleReject())
        ; Already queued - re-send if text changed
        (ACL_pendingInput
          unless(text == ACL_pendingInput
            ACL_pendingInput = text
            ACL_sendMessage(text ?uuid sprintf(nil "user%d-%d" ACL_uuidEpoch ACL_promptId))))
        ; New message - send (queue or echo depending on auto-update mode)
        (t
          if(ACL_autoUpdateInput then
            axlFormSetField(form "send" "Queued")
          else
            ACL_appendChat(sprintf(nil "\n\nYou: %s" text))
            axlFormSetField(form "userinput" "")
            axlFormSetActiveField(form "userinput"))
          ACL_handleUserMessage(text)
          unless(ACL_autoUpdateInput
            ACL_promptId++
            ACL_pendingInput = nil))))))

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
    ACL_journalFile = strcat(ACL_sessionLogDir "/journal.scr")
    axlJournal(ACL_journalFile)
    ACL_recording = t
    axlFormSetField(form "record" "Done")
    ACL_appendChat(
      "\n\nRecording... Perform the action in Allegro, then click Done.")
    ACL_setStatus("Recording macro...")))

; ============================================================
; 12. Input Polling (auto-update queued messages)
; ============================================================

procedure(ACL_startInputPoll()
  ; Schedule first poll after 500ms (one-shot, self-rescheduling)
  axlUIWTimerAdd(nil 30 t 'ACL_pollInput))

procedure(ACL_pollInput(@rest args)
  ; Timer callback: check if queued input text has changed.
  ; Self-terminates when ACL_pendingInput becomes nil.
  when(and(ACL_pendingInput ACL_form)
    let((text)
      text = axlFormGetField(ACL_form "userinput")
      when((text != ACL_pendingInput)
        ACL_pendingInput = text
        ACL_sendMessage(text ?uuid sprintf(nil "user%d-%d" ACL_uuidEpoch ACL_promptId))))
    ; Re-schedule while still queued
    ACL_startInputPoll()))

; ============================================================
; 13. Message Handlers
; ============================================================

procedure(ACL_handleUserMessage(text)
  ACL_setStatus("Thinking...")
  ACL_responseBuf = ""
  ACL_pendingInput = text
  let((elapsed prefix systemUuid userUuid)
    elapsed = stringToTime(getCurrentTime()) - ACL_lastCmdTime
    prefix = strcat(
      if(and(ACL_lastCmdTime elapsed > 60)
        "[The board may have been edited. Re-query the design instead of relying on memory.] "
        "")
      if(ACL_mode == "manual"
        " [MANUAL MODE: Describe what you would do and the SKILL code, but do NOT call allegro_execute yet. Wait for approval.]"
        ""))
    userUuid = sprintf(nil "user%d-%d" ACL_uuidEpoch ACL_promptId)
    ; Send system prefix as synthetic (not displayed, no response generated)
    (when (strlen(prefix) > 0)
      ACL_sendMessage(prefix ?isSynthetic t ?noQuery t))
    ; Send user's actual message
    ACL_sendMessage(text ?uuid userUuid)
    ; Start polling for input changes (if enabled)
    when(ACL_autoUpdateInput ACL_startInputPoll())))

procedure(ACL_handleApprove()
  ACL_appendChat("Approved.")
  ACL_setStatus("Executing...")
  ACL_sendMessage(
    "Approved. Go ahead and execute the proposed commands."
    ?isSynthetic t))

procedure(ACL_handleReject(@optional (notify t))
  ACL_appendChat("Rejected.")
  when(notify
    ACL_setStatus("Thinking...")
    ACL_sendMessage(
      "The user rejected the proposed commands. Ask what they'd like instead."
      ?isSynthetic t)))

procedure(ACL_handleJournal(contents)
  ACL_setStatus("Analyzing...")
  ACL_responseBuf = ""
  ACL_sendMessage(strcat(
    "The user recorded this Allegro macro/journal:\n\n```\n"
    contents "\n```\n\n"
    "Analyze the commands. Explain what the user did step by step. "
    "Generate a reusable SKILL procedure that replicates this action "
    "with parameterized inputs where appropriate.")
    ?isSynthetic t))

; ============================================================
; 14. Session Management UI
; ============================================================

procedure(ACL_handleSessionPick()
  prog((sessions labels sids choice sid board)
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
    when(and(choice choice >= 0)
      if(choice == 0 then
        ACL_handleNewSession()
      else
        sid = nth((choice - 1) sids)
        board = or(ACL_jGet(ACL_getSession(sid) "board") "")
        if(ACL_normPath(board) == ACL_normPath(axlGetDrawingName())
          ACL_handleRestoreSession(sid)
          ACL_handleForkSession(sid))))))

procedure(ACL_basename(path)
  ; Last path component of a "/"-or-"\"-separated path.
  pcreReplace(pcreCompile("^.*[/\\\\]") path "" 0))

procedure(ACL_findOrPlanDocs()
  ; Look for the cached Allegro docs file across known locations.
  ; Filename is "SPB<sanitized-version>.md". We try the exact version
  ; (with hotfix, e.g. SPB25_1_2025_S020.md) first across all dirs,
  ; then the version without the hotfix suffix (e.g. SPB25_1_2025.md).
  ; Returns the first match found. If nothing matches, returns the
  ; notes-dir path with the exact-version filename so the agent can
  ; create it there.
  let((exactName baseName dirs found)
    exactName = strcat("SPB"
      pcreReplace(pcreCompile("[^\\w]") axlVersion('fullVersion) "_" 0)
      ".md")
    ; Strip the hotfix suffix (trailing "_S<digits>" or "_HF<digits>")
    baseName = pcreReplace(pcreCompile("_(S|HF)\\d+\\.md$")
      exactName ".md" 0)
    dirs = list(ACL_notesDir
                ACL_normPath(axlGetVariable("allegro_pcbenv"))
                ACL_normPath(axlGetVariable("allegro_site"))
                ACL_scriptDir)
    ; Exact filename in any dir wins; then the less-specific (no hotfix).
    ; pcreReplace strips a trailing slash so the join is consistent.
    foreach(name list(exactName baseName)
      foreach(d dirs
        when(and(stringp(d) null(found))
          let((path)
            path = strcat(pcreReplace(pcreCompile("/$") d "" 0) "/" name)
            when(isFile(path) found = path)))))
    or(found strcat(ACL_notesDir "/" exactName))))

procedure(ACL_handleNewSession()
  ACL_sessionId = nil
  ACL_sessionSaved = nil
  ACL_logReset()
  ACL_startClaude()
  ACL_appendChat("Starting new session...")
  ACL_setStatus("Starting...")
  ; Documentation handling: the cached doc (if it exists) is loaded
  ; into the system prompt by ACL_startClaude via --append-system-prompt-file,
  ; so we don't need to ask claude to read it at runtime. If no cache
  ; exists, we offer to generate one.
  unless(ACL_fast let((doc choice)
    doc = ACL_findOrPlanDocs()
    unless(isFile(doc)
      ; No cache exists. Ask the user (Yes / No / Cancel = Never ask again)
      ; before kicking off the ~1hr documentation crawl.
      choice = axlUIYesNoCancel(strcat(
        "No Allegro documentation cache exists for this version.\n\n"
        "Generating it takes about an hour and >>100M tokens, but dramatically improves "
        "accuracy. The result is written to:\n  " doc "\n\n"
        "Generate the cache now?\n\n"
        "Yes      - generate (will be loaded automatically on next session)\n"
        "No       - skip this time (you will get tips on bringing in a cache)\n"
        "Cancel   - never ask again (sets fast mode)")
        "Allegro Claude: documentation cache" 'yes)
      cond(
        (choice == 1
          ; Yes -- proceed with generation
          ACL_appendChat(strcat(
            "Generating Allegro documentation cache. It'll take about an "
            "hour but is worth it. Please keep this window open. I can "
            "still help while this is going on, but I might be slower to "
            "respond. Once finished, restart claude (or open a new session) "
            "to pick up the documentation."))
          ACL_sendMessage(strcat(
            "[CRITICAL: Do the following steps exactly, giving only extremely succinct progress "
            "updates -- as little status output as possible to avoid confusing the conversation: "
            "1. Spawn sub-agents (aim for <25 functions each) to thoroughly read through *all* of the "
            "Allegro documentation you have access to and accumulate that knowledge into `" doc "` "
            "with extensive detail, sufficient to be able to reliably use every single API and interface "
            "on your first try, as well as understand and apply topics, concepts, and usages covered in "
            "more free-form documentation and examples. "
            "The agents should take extra time to ensure complete coverage of all of the interfaces "
            "enumerated in TOCs, and take special note of things that were omitted from the TOC. "
            "The agents should write incrementally to avoid timing out on large writes. "
            "This may take an hour and should result in a large file. "
            "2. Clean up any remaining sub-agent files. "
            "3. Tell the user the cache is ready and they should start a new session to use it. "
            "Until all this is complete, **be very careful to check documentation** manually before "
            "responding to queries, and warn the user that you haven't completed your survey yet.]")
            ?isSynthetic t ?noQuery t))
        (choice == 2
          ; Cancel -- never ask again, persist fast mode
          ACL_fast = t
          ACL_saveSettings(ACL_settingsFile ACL_currentSettings())
          ACL_appendChat(strcat(
            "Skipping documentation cache permanently (fast mode). "
            "Edit " ACL_settingsFile " to re-enable.")))
        (t
          ; No -- skip this session, but explain where the file is
          ; expected so the user can drop in a pre-built copy.
          ACL_appendChat(strcat(
            "Skipping documentation cache for this session. If you "
            "already have a cache file, place it at any of:\n"
            "  " ACL_notesDir "/\n"
            "  " ACL_normPath(axlGetVariable("allegro_pcbenv")) "/\n"
            "  " ACL_normPath(axlGetVariable("allegro_site")) "/\n"
            "  " ACL_scriptDir "\n"
            "named " ACL_basename(doc) " (or the version-without-hotfix "
            "equivalent).")))))))
  ACL_sendMessage(sprintf(nil "Current board: %L\nSay hello" axlGetDrawingName())
    ?isSynthetic t))

procedure(ACL_handleRestoreSession(sid)
  let((info)
    info = ACL_getSession(sid)
    if(null(info) then
      ; Session not in our sessions.json -- nothing to restore.
      ACL_handleNewSession()
    else
      ACL_sessionId = sid
      ACL_sessionLogDir = strcat(ACL_logDir "/" ACL_sessionId)
      ACL_sessionSaved = t
      ACL_logReset()
      ACL_applySettings(or(
        ACL_loadSettings(strcat(ACL_sessionLogDir "/settings.json"))
        ACL_loadSettings(ACL_settingsFile)
        nil))
      ACL_startClaude(sid)
      ; If claude rejected the --resume id, the stderr handler has
      ; already cleared ACL_sessionId. Recover into a fresh session
      ; instead of leaving the user staring at a blank dialog.
      if(null(ACL_sessionId) then
        ACL_handleNewSession()
      else
        ACL_appendChat(sprintf(nil "Restored session: %s" sid))
        ACL_setStatus("Ready")))))

procedure(ACL_handleForkSession(sid)
  prog((info oldBoard)
    info = ACL_getSession(sid)
    unless(info
      ACL_appendChat(sprintf(nil "Session not found: %s" sid))
      return(nil))
    oldBoard = or(ACL_jGet(info "board") "unknown")
    ; Reset save state so the fork registers itself with the CURRENT
    ; board (not the parent's) on its first text response.
    ACL_sessionId = nil
    ACL_sessionSaved = nil
    ACL_logReset()
    ACL_startClaude(sid t)
    ; If claude rejected the --resume id, fall through to a fresh
    ; session so the user isn't left staring at a dead dialog.
    if(null(ACL_sessionId) then
      ACL_handleNewSession()
    else
      ACL_responseBuf = ""
      ACL_sendMessage(sprintf(nil
        "The target board has changed from \"%s\" to \"%s\". Disregard any previous design-specific information and re-query the new design as needed."
        oldBoard axlGetDrawingName())
        ?isSynthetic t)
      ACL_appendChat(sprintf(nil "Forked from session: %s" sid)))))

; ============================================================
; 15. Open Panel & Registration
; ============================================================

procedure(ACL_openPanel()
  prog((formFile)
    when(and(ACL_form errset(axlFormDisplay(ACL_form)))
      return(t))
    formFile = strcat(ACL_scriptDir "allegro_claude.form")
    ACL_form = axlFormCreate('ACL_form formFile nil 'ACL_formCB t t)
    when(ACL_form
      axlFormDefaultButton(ACL_form "send")
      ACL_applySettings(or(ACL_loadSettings(ACL_settingsFile) nil))
      axlFormSetField(ACL_form "mode" ACL_mode)
      axlFormSetField(ACL_form "loglines" sprintf(nil "%d" ACL_logLineLimit))
      axlFormSetField(ACL_form "statuslabel" "Starting...")
      axlFormDisplay(ACL_form)
      axlFormSetActiveField(ACL_form "userinput")
      if(ACL_sessionId then
        ACL_ensureClaude()
        ; Redisplay existing log and status after window reopen
        when(ACL_logContent
          axlFormSetField(ACL_form "chatlog"
            ACL_logTail(ACL_logLineLimit)))
        ACL_setStatus(if(and(ACL_claude ipcIsAliveProcess(ACL_claude))
          "Ready" "Starting..."))
      else
        let((sessions board mostRecent)
          board = axlGetDrawingName()
          sessions = when(board ACL_getBoardSessions(board))
          ; Auto-resume the most recent session for this board, if any.
          ; If the session id is stale, the stderr handler clears it and
          ; the next user action starts fresh via ACL_ensureClaude.
          if(sessions then
            mostRecent = car(ACL_sortSessionsByTime(sessions))
            ACL_handleRestoreSession(car(mostRecent))
          else
            ACL_handleNewSession()))))))

axlCmdRegister("claude" 'ACL_openPanel ?cmdType "general")
regExitBefore('ACL_stopClaude)

; ============================================================
; 16. Tests  --  run with:  ACL_runTests()
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

  printf("\n--- SKILL Execution ---\n")
  let(((savedForm ACL_form))
    ACL_form = nil
    ACL_check("exec simple"
      ACL_execBlock("(plus 40 2)")
      "Result: 42")
    ACL_check("exec empty"
      ACL_execBlock("")
      "(empty block)")
    ACL_check("exec with output"
      ACL_execBlock("printf(\"hello\\n\") 99")
      "Output:\nhello\n\nResult: 99")
    let((errResult)
      errResult = ACL_execBlock("(undefined_function_xyz)")
      ACL_check("exec error"
        and(nindex(errResult "*Error*") t)
        t))
    ; Allegro shell errors should be captured via the journal
    let((shellResult)
      shellResult = ACL_execBlock("axlShell(\"zoom bogus\")")
      ACL_check("exec captures shell error"
        and(nindex(shellResult "Command not found") t)
        t))
    ; SKILL error() message text should survive
    let((errResult)
      errResult = ACL_execBlock("error(\"my custom error\")")
      ACL_check("exec preserves error msg"
        and(nindex(errResult "my custom error") t)
        t))
    ; axlMsgPut output should be captured (journal)
    let((msgResult)
      msgResult = ACL_execBlock("axlMsgPut(\"a logged note\")")
      ACL_check("exec captures axlMsgPut"
        and(nindex(msgResult "a logged note") t)
        t))
    ACL_form = savedForm)

  printf("\n--- Display Streaming ---\n")
  let(((savedForm ACL_form) (savedLog ACL_logContent))
    ACL_form = nil
    ; plain text goes straight to log
    ACL_logContent = nil
    ACL_streamToDisplay("hello world")
    ACL_check("plain flush"    ACL_logString() "hello world")
    ; partial line continuation via rplaca
    ACL_logContent = nil
    ACL_logWrite("hel")
    ACL_logWrite("lo\nwor")
    ACL_logWrite("ld")
    ACL_check("partial lines" ACL_logString() "hello\nworld")
    ; logTail with partial line
    ACL_check("tail partial" ACL_logTail(50) "hello\nworld")
    ; logTail truncation
    ACL_logContent = nil
    ACL_logWrite("a\nb\nc\nd\ne\n")
    ACL_check("tail trunc" ACL_logTail(3) "...\nc\nd\ne\n")
    ACL_form = savedForm
    ACL_logContent = savedLog)

  printf("\n--- MCP File IPC ---\n")
  let(((savedForm ACL_form) (savedSessionDir ACL_sessionLogDir)
       (savedSeq ACL_mcpCmdSeq) (savedPending ACL_mcpPending))
    ACL_form = nil
    ACL_sessionLogDir = strcat(ACL_homeDir "/mcp_test")
    ACL_mcpCmdSeq = 0
    ACL_mcpPending = nil
    createDir(ACL_sessionLogDir)
    ; Simulate a tool_use block arriving from claude. ACL_handleToolCall
    ; queues + arms a one-shot timer; we drain manually.
    ACL_handleToolCall(list(list("id" "toolu_test_42")
                            list("name" "mcp__allegro__allegro_execute")
                            list("input" list(list("code" "(plus 40 2)")))))
    ACL_check("queued one"
      length(ACL_mcpPending) 1)
    ACL_mcpDrainPending()
    ACL_check("pending cleared" ACL_mcpPending nil)
    ACL_check("seq advanced" ACL_mcpCmdSeq 1)
    ACL_check("cmd il written"
      and(isFile(strcat(ACL_sessionLogDir "/cmd_1.il")) t) t)
    ACL_check("cmd out written"
      and(isFile(strcat(ACL_sessionLogDir "/cmd_1.out")) t) t)
    ACL_check("ipc out written"
      and(isFile(strcat(ACL_sessionLogDir "/tool_toolu_test_42.out")) t) t)
    ACL_check("cmd il content"
      ACL_readFile(strcat(ACL_sessionLogDir "/cmd_1.il")) "(plus 40 2)")
    ACL_check("ipc out content"
      ACL_readFile(strcat(ACL_sessionLogDir "/tool_toolu_test_42.out"))
      "Result: 42")
    ; Multiple queued at once should all execute on one drain
    ACL_handleToolCall(list(list("id" "toolu_a") list("name" "mcp__allegro__allegro_execute")
                            list("input" list(list("code" "(plus 1 1)")))))
    ACL_handleToolCall(list(list("id" "toolu_b") list("name" "mcp__allegro__allegro_execute")
                            list("input" list(list("code" "(plus 2 2)")))))
    ACL_check("queued two" length(ACL_mcpPending) 2)
    ACL_mcpDrainPending()
    ACL_check("seq advanced again" ACL_mcpCmdSeq 3)
    ACL_check("ipc a" ACL_readFile(strcat(ACL_sessionLogDir "/tool_toolu_a.out"))
      "Result: 2")
    ACL_check("ipc b" ACL_readFile(strcat(ACL_sessionLogDir "/tool_toolu_b.out"))
      "Result: 4")
    ; Block missing required fields is ignored
    ACL_handleToolCall(list(list("name" "mcp__allegro__allegro_execute")
                            list("input" list(list("code" "(plus 9 9)")))))
    ACL_check("missing id ignored" ACL_mcpPending nil)
    ; ACL_mcpScanMaxSeq finds the highest existing N
    ACL_check("scan max seq sees existing"
      ACL_mcpScanMaxSeq(ACL_sessionLogDir) 3)
    ; Empty dir -> 0
    let((emptyDir)
      emptyDir = strcat(ACL_homeDir "/mcp_test_empty")
      createDir(emptyDir)
      ACL_check("scan max seq empty dir"
        ACL_mcpScanMaxSeq(emptyDir) 0)
      errset(deleteDir(emptyDir)))
    ; Nonexistent dir -> 0 (errset swallows)
    ACL_check("scan max seq nonexistent dir"
      ACL_mcpScanMaxSeq(strcat(ACL_homeDir "/no_such_dir_42")) 0)
    ; Clean up
    let((files)
      files = errset(getDirFiles(ACL_sessionLogDir))
      when(and(files car(files))
        foreach(f car(files)
          when(and(f f != "." f != "..")
            errset(deleteFile(strcat(ACL_sessionLogDir "/" f)))))))
    errset(deleteDir(ACL_sessionLogDir))
    ACL_sessionLogDir = savedSessionDir
    ACL_mcpCmdSeq = savedSeq
    ACL_mcpPending = savedPending
    ACL_form = savedForm)

  printf("\n--- Form File ---\n")
  let((formPath formHandle)
    formPath = strcat(ACL_scriptDir "allegro_claude.form")
    formHandle = axlFormCreate('ACL_testForm formPath nil nil nil)
    ACL_check("form parse" and(formHandle t) t)
    when(formHandle axlFormClose(formHandle)))

  printf("\n--- Doc Lookup ---\n")
  let(((savedNotes ACL_notesDir) (savedScript ACL_scriptDir)
       (savedSite axlGetVariable("allegro_site"))
       (savedPcb axlGetVariable("allegro_pcbenv"))
       doc exactName baseName notesDir pcbDir siteDir scriptDir)
    notesDir = strcat(ACL_homeDir "/doc_test_notes")
    pcbDir = strcat(ACL_homeDir "/doc_test_pcbenv")
    siteDir = strcat(ACL_homeDir "/doc_test_site")
    scriptDir = strcat(ACL_homeDir "/doc_test_script/")
    foreach(d list(notesDir pcbDir siteDir scriptDir) createDir(d))
    ACL_notesDir = notesDir
    ACL_scriptDir = scriptDir
    axlSetVariable("allegro_pcbenv" pcbDir)
    axlSetVariable("allegro_site" siteDir)
    exactName = strcat("SPB"
      pcreReplace(pcreCompile("[^\\w]") axlVersion('fullVersion) "_" 0) ".md")
    baseName = pcreReplace(pcreCompile("_(S|HF)\\d+\\.md$")
      exactName ".md" 0)
    ; Helper closures via let-bound functions aren't great in SKILL,
    ; so just inline a writer + cleaner.
    let((fp p)
      ; ---- 1. No files anywhere -> default to notesDir/exactName
      doc = ACL_findOrPlanDocs()
      ACL_check("doc default to notesDir"
        doc strcat(notesDir "/" exactName))

      ; ---- 2. Exact in scriptDir wins (alone)
      p = strcat(scriptDir exactName)
      fp = outfile(p) when(fp fprintf(fp "x") close(fp))
      ACL_check("doc exact in scriptDir" ACL_findOrPlanDocs() p)
      deleteFile(p)

      ; ---- 3. Exact in siteDir wins (alone)
      p = strcat(siteDir "/" exactName)
      fp = outfile(p) when(fp fprintf(fp "x") close(fp))
      ACL_check("doc exact in siteDir" ACL_findOrPlanDocs() p)
      deleteFile(p)

      ; ---- 4. Exact in pcbDir wins (alone)
      p = strcat(pcbDir "/" exactName)
      fp = outfile(p) when(fp fprintf(fp "x") close(fp))
      ACL_check("doc exact in pcbDir" ACL_findOrPlanDocs() p)
      deleteFile(p)

      ; ---- 5. Exact in notesDir wins (alone)
      p = strcat(notesDir "/" exactName)
      fp = outfile(p) when(fp fprintf(fp "x") close(fp))
      ACL_check("doc exact in notesDir" ACL_findOrPlanDocs() p)
      deleteFile(p)

      ; ---- 6. Dir priority: notesDir > pcbenv when both have exact
      let((pNotes pPcb)
        pNotes = strcat(notesDir "/" exactName)
        pPcb = strcat(pcbDir "/" exactName)
        fp = outfile(pNotes) when(fp fprintf(fp "n") close(fp))
        fp = outfile(pPcb) when(fp fprintf(fp "p") close(fp))
        ACL_check("doc notesDir beats pcbenv" ACL_findOrPlanDocs() pNotes)
        deleteFile(pNotes) deleteFile(pPcb))

      ; ---- 7. Dir priority: pcbenv > site
      let((pPcb pSite)
        pPcb = strcat(pcbDir "/" exactName)
        pSite = strcat(siteDir "/" exactName)
        fp = outfile(pPcb) when(fp fprintf(fp "p") close(fp))
        fp = outfile(pSite) when(fp fprintf(fp "s") close(fp))
        ACL_check("doc pcbenv beats site" ACL_findOrPlanDocs() pPcb)
        deleteFile(pPcb) deleteFile(pSite))

      ; ---- 8. Dir priority: site > scriptDir
      let((pSite pScript)
        pSite = strcat(siteDir "/" exactName)
        pScript = strcat(scriptDir exactName)
        fp = outfile(pSite) when(fp fprintf(fp "s") close(fp))
        fp = outfile(pScript) when(fp fprintf(fp "x") close(fp))
        ACL_check("doc site beats scriptDir" ACL_findOrPlanDocs() pSite)
        deleteFile(pSite) deleteFile(pScript))

      ; ---- 9. Exact in scriptDir beats base in notesDir
      let((pExact pBase)
        pExact = strcat(scriptDir exactName)
        pBase = strcat(notesDir "/" baseName)
        fp = outfile(pExact) when(fp fprintf(fp "e") close(fp))
        fp = outfile(pBase) when(fp fprintf(fp "b") close(fp))
        ACL_check("doc exact anywhere beats base in notes"
          ACL_findOrPlanDocs() pExact)
        deleteFile(pExact) deleteFile(pBase))

      ; ---- 10. Base name found in notesDir when no exact exists
      p = strcat(notesDir "/" baseName)
      fp = outfile(p) when(fp fprintf(fp "x") close(fp))
      ACL_check("doc base in notesDir" ACL_findOrPlanDocs() p)
      deleteFile(p)

      ; ---- 11. Base name found in scriptDir when nothing else
      p = strcat(scriptDir baseName)
      fp = outfile(p) when(fp fprintf(fp "x") close(fp))
      ACL_check("doc base in scriptDir" ACL_findOrPlanDocs() p)
      deleteFile(p)

      ; ---- 12. Base in notesDir beats base in pcbenv (priority within base)
      let((pNotes pPcb)
        pNotes = strcat(notesDir "/" baseName)
        pPcb = strcat(pcbDir "/" baseName)
        fp = outfile(pNotes) when(fp fprintf(fp "n") close(fp))
        fp = outfile(pPcb) when(fp fprintf(fp "p") close(fp))
        ACL_check("doc base priority" ACL_findOrPlanDocs() pNotes)
        deleteFile(pNotes) deleteFile(pPcb)))
    axlSetVariable("allegro_site" savedSite)
    axlSetVariable("allegro_pcbenv" savedPcb)
    ACL_scriptDir = savedScript
    ACL_notesDir = savedNotes
    ; Best-effort cleanup (no-op if dirs aren't empty).
    foreach(d list(notesDir pcbDir siteDir scriptDir)
      errset(deleteDir(d))))

  printf("\n--- Settings ---\n")
  let((tmpFile settings loaded (savedMode ACL_mode))
    tmpFile = strcat(ACL_sessionLogDir "/test_settings.json")
    ; Round-trip save/load
    settings = list(list("mode" "verbose"))
    ACL_saveSettings(tmpFile settings)
    loaded = ACL_loadSettings(tmpFile)
    ACL_check("settings roundtrip" loaded settings)
    ACL_check("settings get mode" ACL_jGet(loaded "mode") "verbose")
    ; currentSettings reflects ACL_mode
    ACL_mode = "quiet"
    ACL_check("currentSettings" ACL_currentSettings()
      list(list("mode" "quiet") list("fast" 'false) list("claudeArgs" "")))
    ; applySettings updates ACL_mode
    ACL_applySettings(list(list("mode" "manual")))
    ACL_check("applySettings" ACL_mode "manual")
    ; claudeArgs round-trips
    let(((savedClaudeArgs ACL_claudeArgs))
      ACL_applySettings(list(list("claudeArgs" "--debug api,hooks")))
      ACL_check("applySettings claudeArgs" ACL_claudeArgs "--debug api,hooks")
      ACL_claudeArgs = savedClaudeArgs)
    ; Load nonexistent file returns nil
    ACL_check("load missing" ACL_loadSettings("/tmp/nonexistent_acl_test.json") nil)
    ; Cleanup
    deleteFile(tmpFile)
    ACL_mode = savedMode)

  printf("\n--- Sessions ---\n")
  let(((savedFile ACL_sessionsFile) (savedSid ACL_sessionId) sample stale sorted)
    ACL_sessionsFile = strcat(ACL_homeDir "/sessions_test.json")
    sample = list(
      list("aaaa-aaaa" list(list("board" "/tmp/foo.brd") list("time" "100")))
      list("bbbb-bbbb" list(list("board" "/tmp/bar.brd") list("time" "300")))
      list("cccc-cccc" list(list("board" "/tmp/baz.brd") list("time" "200"))))
    ACL_saveSessions(sample)
    ACL_check("session preload" length(ACL_loadSessions()) 3)
    ; Sort by time, newest first
    sorted = ACL_sortSessionsByTime(ACL_loadSessions())
    ACL_check("sort newest first" car(car(sorted)) "bbbb-bbbb")
    ACL_check("sort middle" car(cadr(sorted)) "cccc-cccc")
    ACL_check("sort oldest last" car(caddr(sorted)) "aaaa-aaaa")
    ; Detect a stale-session line and ensure removeSession works
    stale = "claude: No conversation found with session ID: bbbb-bbbb"
    ACL_check("noSessionRe matches" pcreMatchp(ACL_noSessionRe stale) t)
    ; Stale handler also clears ACL_sessionId if it matches
    ACL_sessionId = "bbbb-bbbb"
    ACL_handleStaleSession(stale)
    ACL_check("stale removed" length(ACL_loadSessions()) 2)
    ACL_check("right one removed" assoc("bbbb-bbbb" ACL_loadSessions()) nil)
    ACL_check("sessionId cleared" ACL_sessionId nil)
    ACL_check("others kept" and(assoc("aaaa-aaaa" ACL_loadSessions())
                                assoc("cccc-cccc" ACL_loadSessions()) t) t)
    ; Idempotent: removing a non-existent id is a no-op
    ACL_handleStaleSession(stale)
    ACL_check("idempotent" length(ACL_loadSessions()) 2)
    ; sessionId NOT cleared when the stale id doesn't match the current one
    ACL_sessionId = "different-id"
    ACL_handleStaleSession(stale)
    ACL_check("preserves unrelated sessionId" ACL_sessionId "different-id")
    ACL_sessionId = savedSid
    deleteFile(ACL_sessionsFile)
    ACL_sessionsFile = savedFile)

  printf("\n--- Session fork ---\n")
  ; Drive ACL_processStreamLine with a synthetic init event and check
  ; the fork path: parent log dir + sessions.json entry preserved,
  ; parent files copied into the fork dir, fork's own sessions.json
  ; entry deferred to its first-text save (so it gets the right board).
  let(((savedFile ACL_sessionsFile) (savedSid ACL_sessionId)
       (savedLogDir ACL_sessionLogDir) (savedFork ACL_resumeIsFork)
       (savedSeq ACL_mcpCmdSeq) parentDir newDir)
    ACL_sessionsFile = strcat(ACL_homeDir "/sessions_rekey_test.json")
    ACL_sessionId = "rekey-old-2"
    parentDir = strcat(ACL_logDir "/rekey-old-2")
    ACL_createDirP(parentDir)
    let((fp)
      fp = outfile(strcat(parentDir "/cmd_3.il"))
      when(fp fprintf(fp "(plus 2 2)") close(fp))
      fp = outfile(strcat(parentDir "/cmd_3.out"))
      when(fp fprintf(fp "Result: 4") close(fp)))
    ACL_addSession("rekey-old-2" list(list("board" "/tmp/y.brd") list("time" "200")))
    ACL_resumeIsFork = t
    ACL_processStreamLine("{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"rekey-new-2\"}")
    newDir = strcat(ACL_logDir "/rekey-new-2")
    ACL_check("fork: id updated" ACL_sessionId "rekey-new-2")
    ACL_check("fork: parent dir preserved" isDir(parentDir) t)
    ACL_check("fork: parent cmd preserved"
      and(isFile(strcat(parentDir "/cmd_3.il")) t) t)
    ACL_check("fork: new dir present" isDir(newDir) t)
    ACL_check("fork: cmd file copied to new"
      and(isFile(strcat(newDir "/cmd_3.il")) t) t)
    ACL_check("fork: copied content matches"
      ACL_readFile(strcat(newDir "/cmd_3.il")) "(plus 2 2)")
    ACL_check("fork: seq seeded from copied files" ACL_mcpCmdSeq 3)
    ACL_check("fork: parent kept in sessions"
      and(assoc("rekey-old-2" ACL_loadSessions()) t) t)
    ; Fork should NOT pre-add the new sid: the first-text save path
    ; registers it with the current board (not the parent's).
    ACL_check("fork: new id NOT pre-added to sessions"
      assoc("rekey-new-2" ACL_loadSessions()) nil)
    ; cleanup
    foreach(d list(parentDir newDir)
      let((files)
        files = errset(getDirFiles(d))
        when(and(files car(files))
          foreach(f car(files)
            when(and(f f != "." f != "..")
              errset(deleteFile(strcat(d "/" f))))))
        errset(deleteDir(d))))

    ACL_resumeIsFork = savedFork
    ACL_mcpCmdSeq = savedSeq
    ACL_sessionLogDir = savedLogDir
    ACL_sessionId = savedSid
    deleteFile(ACL_sessionsFile)
    ACL_sessionsFile = savedFile)

  printf("\n--- Resume seq seeding ---\n")
  ; On resume claude returns the SAME sid, so the new-session branch
  ; in ACL_processStreamLine doesn't fire. The seq must still be
  ; reseeded from existing cmd_<N>.il files, otherwise tool_use
  ; numbering restarts at 1 and overwrites prior turns.
  let(((savedSid ACL_sessionId) (savedLogDir ACL_sessionLogDir)
       (savedSeq ACL_mcpCmdSeq) sid logDir fp)
    sid = "resume-seed-test"
    logDir = strcat(ACL_logDir "/" sid)
    ACL_createDirP(logDir)
    fp = outfile(strcat(logDir "/cmd_7.il"))
    when(fp fprintf(fp "(plus 1 1)") close(fp))
    ; Simulate resume: ACL_startClaude reset seq to 0 and the sid
    ; matches the one already set, so processStreamLine's rekey
    ; block must NOT be the only place that seeds.
    ACL_sessionId = sid
    ACL_sessionLogDir = logDir
    ACL_mcpCmdSeq = 0
    ACL_processStreamLine(sprintf(nil
      "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"%s\"}" sid))
    ACL_check("resume: seq seeded from existing files" ACL_mcpCmdSeq 7)
    errset(deleteFile(strcat(logDir "/cmd_7.il")))
    errset(deleteDir(logDir))
    ACL_mcpCmdSeq = savedSeq
    ACL_sessionLogDir = savedLogDir
    ACL_sessionId = savedSid)

  printf("\n--- Hook session_id ignored ---\n")
  ; SessionStart:resume hook events carry transient session_ids that must NOT
  ; trigger our rekey logic. Only system/init should be authoritative.
  let(((savedSid ACL_sessionId) (savedLogDir ACL_sessionLogDir))
    ACL_sessionId = "real-sid"
    ACL_sessionLogDir = strcat(ACL_logDir "/real-sid")
    ACL_processStreamLine(strcat(
      "{\"type\":\"system\",\"subtype\":\"hook_started\","
      "\"hook_name\":\"SessionStart:resume\","
      "\"session_id\":\"transient-bogus-id\"}"))
    ACL_check("hook event ignored" ACL_sessionId "real-sid")
    ACL_processStreamLine(strcat(
      "{\"type\":\"system\",\"subtype\":\"hook_response\","
      "\"hook_name\":\"SessionStart:resume\","
      "\"session_id\":\"another-transient-bogus\"}"))
    ACL_check("hook response ignored" ACL_sessionId "real-sid")
    ACL_sessionLogDir = savedLogDir
    ACL_sessionId = savedSid)

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
  let((claudeExists)
    claudeExists = errset(system(
      if(ACL_isWindows "where claude >NUL 2>&1"
        "env -u LD_LIBRARY_PATH which claude > /dev/null 2>&1")))
    if(and(claudeExists car(claudeExists) == 0) then
      ACL_streamErrorCount = 0
      ACL_startClaude()
      ACL_check("claude start" and(ACL_claude ipcIsAliveProcess(ACL_claude) t) t)
      ; End-to-end: send message and wait for response via ipcSleep
      ; ipcSleep processes handlers while waiting
      printf("  Sending hello to Claude...\n")
      ACL_responseBuf = ""
      ACL_sendMessage("Say exactly: HELLO_TEST_OK")
      ; Wait for response (ipcSleep processes handlers)
      ACL_gotText = nil
      for(i 1 120
        unless(ACL_gotText ipcSleep(1)))
      ACL_check("claude response" ACL_gotText t)
      ; SKILL execution round-trip test:
      ; Tool calls are now executed directly from the stream handler
      ; via a one-shot timer (no more SKILL queue-poll).
      printf("  Testing SKILL execution round-trip...\n")
      ACL_responseBuf = ""
      ACL_gotText = nil
      ACL_sendMessage("Execute this SKILL expression using the allegro_execute tool and report the result: (plus 40 2)")
      for(i 1 180
        unless(ACL_gotText
          ACL_mcpDrainPending()
          ipcSleep(1)))
      ACL_check("skill exec response" ACL_gotText t)
      ; Inspect actual artifacts: at least one cmd_*.out should exist
      ; and contain "42" somewhere in the result.
      let((files outContent foundExec)
        files = errset(getDirFiles(ACL_sessionLogDir))
        foundExec = nil
        outContent = ""
        when(and(files car(files))
          foreach(f car(files)
            when(and(strlen(f) > 4
                     substring(f (strlen(f) - 3)) == ".out")
              foundExec = t
              outContent = strcat(outContent
                ACL_readFile(strcat(ACL_sessionLogDir "/" f))))))
        ACL_check("mcp tool was called" foundExec t)
        ACL_check("mcp result contains 42"
          and(nindex(outContent "42") t) t))
      ACL_stopClaude()
      ACL_check("claude stop" ACL_claude nil)
      ACL_check("no stream errors" ACL_streamErrorCount 0)
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
