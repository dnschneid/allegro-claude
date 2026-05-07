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

; JSON unescape: a sentinel string that's vanishingly unlikely to
; appear in real JSON content stands in for "decoded backslash"
; while the simple escapes resolve, so input like "\\n" (literal
; backslash + n) doesn't get re-decoded as a newline.
defvar(ACL_unescSentinel "<__ACL_BS__>")
defvar(ACL_unescBackslashSentinelRe pcreCompile("\\\\\\\\"))
defvar(ACL_unescQuoteRe   pcreCompile("\\\\\""))
defvar(ACL_unescNewlineRe pcreCompile("\\\\n"))
defvar(ACL_unescTabRe     pcreCompile("\\\\t"))
defvar(ACL_unescCRRe      pcreCompile("\\\\r"))
defvar(ACL_unescSlashRe   pcreCompile("\\\\/"))
defvar(ACL_unescSentinelRe pcreCompile("<__ACL_BS__>"))

procedure(ACL_jUnescape(s)
  ; Replace JSON escape sequences. Two-phase to avoid double-decode:
  ; first swap "\\\\" for a sentinel string, then resolve the simple
  ; escapes, then swap the sentinel back to a single backslash.
  let(((r pcreReplace(ACL_unescBackslashSentinelRe s ACL_unescSentinel 0)))
    r = pcreReplace(ACL_unescQuoteRe   r "\"" 0)
    r = pcreReplace(ACL_unescNewlineRe r "\n" 0)
    r = pcreReplace(ACL_unescTabRe     r "\t" 0)
    r = pcreReplace(ACL_unescCRRe      r "\r" 0)
    r = pcreReplace(ACL_unescSlashRe   r "/" 0)
    r = pcreReplace(ACL_unescSentinelRe r "\\\\" 0)
    r))

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

; ============================================================
; 2. JSON Writer
; ============================================================

; JSON escape regexes -- single chars to escape. The order matters:
; backslashes must be escaped BEFORE the other rules add new
; backslashes, otherwise we'd double-encode them.
defvar(ACL_escBackslashRe pcreCompile("\\\\"))
defvar(ACL_escQuoteRe     pcreCompile("\""))
defvar(ACL_escNewlineRe   pcreCompile("\n"))
defvar(ACL_escCRRe        pcreCompile("\r"))
defvar(ACL_escTabRe       pcreCompile("\t"))

procedure(ACL_jsonEscStr(s)
  let(((r pcreReplace(ACL_escBackslashRe s "\\\\\\\\" 0)))
    r = pcreReplace(ACL_escQuoteRe     r "\\\\\""   0)
    r = pcreReplace(ACL_escNewlineRe   r "\\\\n"    0)
    r = pcreReplace(ACL_escCRRe        r "\\\\r"    0)
    r = pcreReplace(ACL_escTabRe       r "\\\\t"    0)
    strcat("\"" r "\"")))

procedure(ACL_jsonIsAlist(v)
  ; A JSON-object alist looks like ((stringKey1 val1) ...). Require
  ; the first entry to be a 2-list with a string key so a plain
  ; list-of-lists (e.g. ((1 2) 3)) doesn't get misidentified.
  and(listp(v) car(v) listp(car(v)) cdr(car(v))
      stringp(caar(v))))

procedure(ACL_jsonVal(v)
  cond(
    (stringp(v) ACL_jsonEscStr(v))
    (numberp(v) sprintf(nil "%L" v))
    (v == t      "true")
    (v == 'false "false")
    (null(v)     "null")
    (ACL_jsonIsAlist(v)
      strcat("{" buildString(
        mapcar(lambda((pair)
          strcat(ACL_jsonEscStr(car(pair)) ":" ACL_jsonVal(cadr(pair))))
          v) ",") "}"))
    (listp(v)
      strcat("[" buildString(mapcar('ACL_jsonVal v) ",") "]"))))

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
    ; Windows has no POSIX signals, so we have to ipcKillProcess
    if(ACL_isWindows
      ipcKillProcess(ACL_claude)
      ipcSignalProcess(ACL_claude 'TERM)))
  ACL_claude = nil)

defvar(ACL_claude nil)
defvar(ACL_claudeStopRequested nil)
defvar(ACL_isWindows (getShellEnvVar("OS") == "Windows_NT"))

procedure(ACL_normPath(path)
  if(and(stringp(path) ACL_isWindows)
    pcreReplace(ACL_backslashRe path "/" 0)
    path))

procedure(ACL_nonEmpty(s)
  ; True iff s is a non-empty string. Required because strlen errors
  ; on non-strings; bare `strlen(s) > 0` will crash on nil.
  and(stringp(s) strlen(s) > 0))

procedure(ACL_axlGetPath(name)
  ; Read an Allegro path variable, normalize slashes, ensure a
  ; trailing slash, and treat defined-but-blank as nil (sometimes
  ; happens with allegro_pcbenv) so callers can `or` against a
  ; default.
  let(((v axlGetVariable(name)))
    when(ACL_nonEmpty(v)
      pcreReplace(ACL_noTrailingSlashRe ACL_normPath(v) "$0/" 0))))

procedure(ACL_pcbenvDir()
  ; The user's pcbenv: allegro_pcbenv if set, otherwise $HOME/pcbenv
  ; (or $USERPROFILE/pcbenv on Windows).
  or(ACL_axlGetPath("allegro_pcbenv")
     strcat(or(getShellEnvVar("HOME")
               getShellEnvVar("USERPROFILE")) "/pcbenv")))

defvar(ACL_fast nil)                ; set to t to skip preloading Allegro docs
defvar(ACL_claudeArgs "")            ; extra flags appended to claude CLI invocation
defvar(ACL_extraPromptFiles nil)     ; list of paths appended to the system prompt (set in site/user init)
defvar(ACL_enableRawLog nil)       ; helps with debugging streams
defvar(ACL_form nil)
defvar(ACL_logContent nil)          ; accumulated log chunks (newest first)
defvar(ACL_logTruncLimit 12500)    ; max chars shown in form field
defvar(ACL_resultTruncLimit 150)   ; max chars shown for results in manual mode
defvar(ACL_statusTruncLimit 200)   ; max chars for the status bar (sanity cap; STRFILLIN scrolls)
defvar(ACL_logLineLimit 50)        ; max lines shown in form field
defvar(ACL_logFile nil)            ; temp file for full log viewer
defvar(ACL_logCodeLimit 250)       ; max chars for each code preview
defvar(ACL_sessionId nil)
defvar(ACL_sessionSaved nil)       ; true after first successful reply
defvar(ACL_mode "quiet")
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

; Match "approve"/"approved" (and similar light variants) at the
; start of the message, optionally followed by punctuation and free
; text. Anything captured in \1 is treated as extra prompting.
defvar(ACL_approveRe pcreCompile("^\\s*approved?\\b[\\W]*(.*)$" pcreGenCompileOptBits(?caseLess t)))
defvar(ACL_rejectRe  pcreCompile("^\\s*rejecte?d?\\b[\\W]*(.*)$"  pcreGenCompileOptBits(?caseLess t)))
; "No conversation found with session ID: <uuid>" -- claude prints this
; to stderr and exits when --resume is given a session it doesn't have.
defvar(ACL_noSessionRe pcreCompile(
  "No conversation found with session ID: ([0-9a-f-]+)"))
defvar(ACL_bignumRe  pcreCompile("^-?\\d{10,}$"))

; Path manipulation. Compiled once because they fire on hot paths
; (every IPC write, every stream-handler tool_use, etc).
defvar(ACL_backslashRe       pcreCompile("\\\\"))
defvar(ACL_noTrailingSlashRe pcreCompile("[^/]$"))
defvar(ACL_trailingSlashesRe pcreCompile("/+$"))
defvar(ACL_lastPathCompRe    pcreCompile("[^/\\\\]+$"))
defvar(ACL_basenameStripRe   pcreCompile("^.*[/\\\\]"))
defvar(ACL_lastPathSegRe     pcreCompile("/[^/]+$"))
defvar(ACL_doubleQuoteRe     pcreCompile("\""))
defvar(ACL_singleQuoteRe     pcreCompile("'"))

; Stream / journal / status processing.
defvar(ACL_cmdSeqFileRe      pcreCompile("^cmd_(\\d+)\\.il$"))
defvar(ACL_mcpToolPrefixRe   pcreCompile("^.*__"))
defvar(ACL_mcpAllegroToolRe  pcreCompile("^mcp__allegro__allegro_"))
defvar(ACL_xmlTagRe          pcreCompile("<[^>]+>"))
defvar(ACL_trimWSRe          pcreCompile("^\\s+|\\s+$"))
defvar(ACL_collapseWSRe      pcreCompile("\\s+"))
defvar(ACL_journalTSRe       pcreCompile("^\\\\[te] \\(\\d+:\\d+:\\d+\\) ?"))
defvar(ACL_journalSkipRe     pcreCompile("^(allegro [0-9]|Host=|CmdLine=|Journal (start|end))"))
defvar(ACL_manualStatusRe    pcreCompile("^Manual:"))
defvar(ACL_nonIdentCharRe    pcreCompile("[^a-zA-Z0-9_]"))
defvar(ACL_axlPrefixRe       pcreCompile("^axl\\w+$"))

; Doc-cache filenames.
defvar(ACL_versionSanitizeRe pcreCompile("[^\\w]"))
defvar(ACL_hotfixStripRe     pcreCompile("_(S|HF)\\d+\\.md$"))

; System-prompt template substitutions.
defvar(ACL_promptNotesRe     pcreCompile("[$]ALLEGRO_CLAUDE_NOTES"))
defvar(ACL_promptInstallRe   pcreCompile("[$]ALLEGRO_INSTALL_ROOT"))
defvar(ACL_promptSiteRe      pcreCompile("[$]ALLEGRO_SITE"))
defvar(ACL_promptPcbenvRe    pcreCompile("[$]ALLEGRO_PCBENV"))

; ============================================================
; UTF-8 -> CP-1252 recoding for the form widget on Windows.
; SKILL string literals don't honor \xNN escapes, so all byte
; sequences are built via intToChar at load time.
; ============================================================

procedure(ACL_byte(n)
  ; Single-byte string for byte value n. (intToChar returns a symbol;
  ; pcreReplace and friends want a string.)
  strcat("" intToChar(n)))

procedure(ACL_bytes(@rest ns)
  ; Multi-byte string from a list of byte values.
  buildString(mapcar('ACL_byte ns) ""))

; Translation table: each entry is (compiled-regex replacement-string).
; Source data is a flat list of (utf8-byte-list replacement) pairs;
; replacement is either a CP-1252 byte (integer) for lossless mappings
; or an ASCII string for lossy ones. mapcar inflates each pair into
; the (regex, string) form pcreReplace expects.
defvar(ACL_recodeTable
  mapcar(lambda((row)
           list(pcreCompile(apply('ACL_bytes car(row)))
                if(integerp(cadr(row)) ACL_byte(cadr(row)) cadr(row))))
    '(
      ; --- Smart punctuation: lossless CP-1252 ---
      ((0xe2 0x80 0x98) 0x91)    ; ' left  single
      ((0xe2 0x80 0x99) 0x92)    ; ' right single
      ((0xe2 0x80 0x9c) 0x93)    ; " left  double
      ((0xe2 0x80 0x9d) 0x94)    ; " right double
      ((0xe2 0x80 0x93) 0x96)    ; en dash
      ((0xe2 0x80 0x94) 0x97)    ; em dash
      ((0xe2 0x80 0xa6) 0x85)    ; ellipsis
      ((0xe2 0x80 0xa2) 0x95)    ; bullet
      ((0xe2 0x82 0xac) 0x80)    ; euro
      ((0xc2 0xa0)      0xa0)    ; nbsp
      ((0xc2 0xb7)      0xb7)    ; middle dot
      ; --- Math, units, symbols: lossless CP-1252 ---
      ((0xc2 0xb5)      0xb5)    ; micro
      ((0xc2 0xb0)      0xb0)    ; degree
      ((0xc2 0xb1)      0xb1)    ; plus-minus
      ((0xc3 0x97)      0xd7)    ; multiply
      ((0xc3 0xb7)      0xf7)    ; divide
      ((0xc2 0xb2)      0xb2)    ; superscript 2
      ((0xc2 0xb3)      0xb3)    ; superscript 3
      ((0xc2 0xa9)      0xa9)    ; copyright
      ((0xc2 0xae)      0xae)    ; registered
      ((0xe2 0x84 0xa2) 0x99)    ; trademark
      ((0xc2 0xbc)      0xbc)    ; 1/4
      ((0xc2 0xbd)      0xbd)    ; 1/2
      ((0xc2 0xbe)      0xbe)    ; 3/4
      ; --- Currency, punctuation, ordinals: lossless CP-1252 ---
      ((0xc2 0xa1)      0xa1)    ; inverted !
      ((0xc2 0xa2)      0xa2)    ; cent
      ((0xc2 0xa3)      0xa3)    ; pound
      ((0xc2 0xa5)      0xa5)    ; yen
      ((0xc2 0xa6)      0xa6)    ; broken bar
      ((0xc2 0xa7)      0xa7)    ; section
      ((0xc2 0xab)      0xab)    ; left guillemet
      ((0xc2 0xac)      0xac)    ; not
      ((0xc2 0xb6)      0xb6)    ; pilcrow
      ((0xc2 0xbb)      0xbb)    ; right guillemet
      ((0xc2 0xbf)      0xbf)    ; inverted ?
      ; --- Daggers / per mille: lossless CP-1252 ---
      ((0xe2 0x80 0xa0) 0x86)    ; dagger
      ((0xe2 0x80 0xa1) 0x87)    ; double dagger
      ((0xe2 0x80 0xb0) 0x89)    ; per mille
      ; --- Ohm: not in CP-1252, lossy ASCII ---
      ((0xce 0xa9)      "ohm")   ; greek capital omega
      ((0xe2 0x84 0xa6) "ohm")   ; ohm sign U+2126
      ; --- Box drawing: lossy ASCII ---
      ((0xe2 0x94 0x80) "-")     ; horizontal
      ((0xe2 0x94 0x82) "|")     ; vertical
      ; corners + tees + cross share the 0xe2 0x94 prefix.
      ; 0x5b/0x5d are ASCII '[' / ']' so the regex character class
      ; embeds cleanly in the byte sequence.
      ((0xe2 0x94 0x5b 0x8c 0x90 0x94 0x98 0x9c 0xa4 0xac 0xb4 0xbc 0x5d) "+")
      ; --- Arrows: lossy ASCII ---
      ((0xe2 0x86 0x92) "->")
      ((0xe2 0x86 0x90) "<-")
      ((0xe2 0x86 0x91) "^")
      ((0xe2 0x86 0x93) "v")
      ; --- Math comparators: lossy ASCII (not in CP-1252) ---
      ((0xe2 0x89 0xa4) "<=")
      ((0xe2 0x89 0xa5) ">=")
      ((0xe2 0x89 0xa0) "!="))))

; Catch-all: any remaining valid UTF-8 multi-byte sequence collapses
; to a single "?". The lead byte range [0xc0-0xf7] excludes the high
; bytes the table just emitted (which are isolated, not preceded by a
; lead byte), so we don't eat our own output. Adjacent unmapped
; sequences merge so an unknown 3-byte char doesn't show as "???".
defvar(ACL_recodeCatchallRe
  pcreCompile(strcat("(?:[" ACL_byte(0xc0) "-" ACL_byte(0xf7) "]["
                     ACL_byte(0x80) "-" ACL_byte(0xbf) "]+)+")))

procedure(ACL_recode(s)
  ; Convert a UTF-8 string to CP-1252 for display in Allegro form
  ; widgets on Windows. Lossless for smart punctuation, math/units,
  ; and Latin-1; lossy ASCII for box-drawing/arrows/comparators;
  ; "?" for everything else. No-op on Linux (Allegro renders UTF-8
  ; fine there), on non-strings, and on pure-ASCII input
  if(or(null(ACL_isWindows) null(stringp(s))
        null(pcreMatchp(ACL_recodeCatchallRe s))) s
    let(((r s))
      foreach(entry ACL_recodeTable
        r = pcreReplace(car(entry) r cadr(entry) 0))
      pcreReplace(ACL_recodeCatchallRe r "?" 0))))

; All path defvars below use the convention "directories end with /,
; files don't". Saves callers from needing to insert separators.
defvar(ACL_homeDir  ; use ~/.local/share to help with sandboxing
  ACL_normPath(strcat(or(getShellEnvVar("XDG_DATA_HOME")
            strcat(or(getShellEnvVar("USERPROFILE") getShellEnvVar("HOME"))
                   "/.local/share"))
         "/allegro_claude/")))
defvar(ACL_notesDir     strcat(ACL_homeDir "notes/"))
defvar(ACL_sessionsFile strcat(ACL_homeDir "sessions.json"))
defvar(ACL_settingsFile strcat(ACL_homeDir "settings.json"))
defvar(ACL_logDir       strcat(ACL_homeDir "logs/"))
defvar(ACL_sessionLogDir ACL_logDir)

; ACL_scriptDir is the directory containing this file (and PROMPT.md,
; LESSONS.md, the .form, and allegro_mcp.py). Auto-detect via piport.
; The user can pre-set ACL_scriptDir before loading to skip detection.
defvar(ACL_scriptDir nil)
unless(ACL_scriptDir
  ACL_scriptDir = car(errset(
    pcreReplace(ACL_lastPathCompRe
      simplifyFilename(get_filename(piport)) "" 0))))
; Normalize: forward slashes, guaranteed trailing slash. Then sanity-
; check by content -- PROMPT.md should sit alongside this file.
when(stringp(ACL_scriptDir)
  ACL_scriptDir = pcreReplace(ACL_noTrailingSlashRe
    ACL_normPath(ACL_scriptDir) "$0/" 0))
unless(and(stringp(ACL_scriptDir) isFile(strcat(ACL_scriptDir "PROMPT.md")))
  printf(strcat(
    "*Warning* ACL: script directory looks wrong "
    "(ACL_scriptDir = %L; expected to contain PROMPT.md). "
    "Set ACL_scriptDir explicitly before loading allegro_claude.il -- e.g.:\n"
    "  ACL_scriptDir = \"/path/to/allegro-claude/skill/\"\n"
    "  load(strcat(ACL_scriptDir \"allegro_claude.il\"))\n") ACL_scriptDir))

; ============================================================
; 4. Utilities
; ============================================================

procedure(ACL_renameOver(src dst)
  ; renameFile fails on Windows if dst exists. Atomic on POSIX.
  when(and(ACL_isWindows isFile(dst)) errset(deleteFile(dst)))
  renameFile(src dst))

procedure(ACL_listDirFiles(dir)
  ; getDirFiles errors on missing/unreadable dirs, returns ("." "..")
  ; on success even when empty. Return a clean list of regular file
  ; names (no "." / ".."), or nil on error or empty dir.
  let(((result errset(getDirFiles(dir))))
    when(and(result car(result))
      setof(f car(result) and(f f != "." f != "..")))))

procedure(ACL_createDirP(path)
  ; mkdir -p: createDir doesn't recurse, so walk parents first.
  ; Strip any trailing slashes first so the regex can find the last
  ; component to lop off.
  let(((p pcreReplace(ACL_trailingSlashesRe path "" 0)))
    when(and(strlen(p) > 0 null(isDir(p)))
      ACL_createDirP(pcreReplace(ACL_lastPathSegRe p "" 0))
      createDir(p))))

procedure(ACL_readFile(path)
  ; Returns "" if path is missing/unreadable.
  let((fp lines line)
    fp = infile(path)
    if(fp then
      while(gets(line fp) lines = cons(line lines))
      close(fp)
      buildString(reverse(lines) "")
    else
      "")))

procedure(ACL_appendChat(text)
  ACL_logWrite(strcat(text "\n")))

procedure(ACL_logEndsWithNL()
  ; True if the most recent log entry is a complete line. nil also
  ; means "no entry yet", which counts as a complete-line state for
  ; the purposes of deciding whether to start a new line.
  or(null(ACL_logContent)
     substring(car(ACL_logContent) strlen(car(ACL_logContent)) 1) == "\n"))

procedure(ACL_logWrite(text)
  ; Stores one line per list entry. Partial lines appended via rplaca.
  ; Suppresses consecutive blank lines.
  let((rest nlPos pre)
    rest = ACL_recode(text)
    while(and(rest strlen(rest) > 0)
      nlPos = nindex(rest "\n")
      if(nlPos then
        pre = substring(rest 1 nlPos)
        cond(
          (null(ACL_logEndsWithNL())
            ; Continue an open partial line.
            rplaca(ACL_logContent strcat(car(ACL_logContent) pre)))
          (or(pre != "\n" car(ACL_logContent) != "\n")
            ; New line; suppress consecutive blanks.
            ACL_logContent = cons(pre ACL_logContent)))
        rest = substring(rest (nlPos + 1))
      else
        if(null(ACL_logEndsWithNL()) then
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
  letseq(((logfile strcat(ACL_sessionLogDir "log.txt"))
          (fp outfile(logfile)))
    when(fp
      fprintf(fp "%s" ACL_logString())
      close(fp)
      axlUIViewFileCreate(logfile "Claude - Full Log" nil '(50 120) nil ACL_form))))

procedure(ACL_openLogDir()
  ; Open the per-session log directory in the OS file explorer so the
  ; user can browse cmd_<N>.il / cmd_<N>.out / tool_*.out files.
  ; Allegro has no built-in "open in explorer", so shell out.
  when(ACL_sessionLogDir
    if(ACL_isWindows
      system(sprintf(nil "cmd /c start \"\" \"%s\"" ACL_sessionLogDir))
      system(sprintf(nil "xdg-open '%s' &" ACL_sessionLogDir)))))

procedure(ACL_setStatus(text)
  ; While manual mode is holding pending tool calls, the user needs
  ; to see "Manual: N pending" persistently -- suppress any other
  ; status update that would clobber it. Once the queue drains or
  ; the mode changes, status is open again.
  text = ACL_recode(text)
  when(and(ACL_form
           or(pcreMatchp(ACL_manualStatusRe text)
              ACL_mode != "manual"
              null(ACL_mcpPending)))
    axlFormSetField(ACL_form "statuslabel"
      if(strlen(text) > ACL_statusTruncLimit
        strcat(substring(text 1 ACL_statusTruncLimit-3) "...")
        text))))

procedure(ACL_buildSystemPrompt()
  ; Read the PROMPT.md template, substitute $ALLEGRO_INSTALL_ROOT and
  ; $ALLEGRO_CLAUDE_PATH with actual directories, and return the result.
  let(((template ACL_readFile(strcat(ACL_scriptDir "PROMPT.md"))))
    template = strcat(template "\n\n" ACL_readFile(strcat(ACL_scriptDir "LESSONS.md")))
    when(isFile(strcat(ACL_notesDir "LESSONS.md"))
      template = strcat(template "\n\n" ACL_readFile(strcat(ACL_notesDir "LESSONS.md"))))
    foreach(extra ACL_extraPromptFiles
      when(and(stringp(extra) isFile(extra))
        template = strcat(template "\n\n" ACL_readFile(extra))))
    template = pcreReplace(ACL_promptNotesRe template ACL_notesDir 0)
    template = pcreReplace(ACL_promptInstallRe template
      ACL_normPath(axlGetVariable("allegro_install_root")) 0)
    template = pcreReplace(ACL_promptSiteRe template
      ACL_normPath(or(ACL_axlGetPath("allegro_site") "")) 0)
    template = pcreReplace(ACL_promptPcbenvRe template
      ACL_normPath(ACL_pcbenvDir()) 0)
    when(ACL_isWindows
      template = strcat(template "\n\n"
        "## Output Encoding\n\n"
        "**Only use ASCII characters in responses.** Do not use Unicode "
        "characters such as curly quotes, em dashes, bullets, or other "
        "non-ASCII glyphs. Use straight quotes, `--`, and `*` instead."))
    template))

procedure(ACL_shellQuote(s)
  if(ACL_isWindows
    strcat("\"" pcreReplace(ACL_doubleQuoteRe s "\\\"" 0) "\"")
    strcat("'" pcreReplace(ACL_singleQuoteRe s "'\\''" 0) "'")))

; ============================================================
; 4b. Settings Persistence
; ============================================================

procedure(ACL_readJsonFile(path)
  ; Read a JSON file and return the parsed top-level value, or nil
  ; if the file is missing/empty/unparseable.
  let(((text ACL_readFile(path)))
    when(strlen(text) > 0
      let(((parsed ACL_jParse(text)))
        when(parsed car(parsed))))))

procedure(ACL_loadSettings(path) ACL_readJsonFile(path))

procedure(ACL_saveSettings(path settings)
  ACL_writeFileAtomic(path strcat(ACL_jsonVal(settings) "\n")))

procedure(ACL_currentSettings()
  list(list("mode" ACL_mode)
       list("fast" or(ACL_fast 'false))
       list("claudeArgs" or(ACL_claudeArgs ""))))

procedure(ACL_applySettings(settings)
  let(((val ACL_jGet(settings "mode")))
    when(val
      ACL_mode = val
      when(ACL_form axlFormSetField(ACL_form "mode" val))))
  ACL_fast = ACL_jGet(settings "fast")
  let(((ca ACL_jGet(settings "claudeArgs")))
    when(stringp(ca) ACL_claudeArgs = ca)))

; ============================================================
; 5. Session Management
; ============================================================

procedure(ACL_loadSessions() ACL_readJsonFile(ACL_sessionsFile))

procedure(ACL_saveSessions(sessions)
  ACL_writeFileAtomic(ACL_sessionsFile strcat(ACL_jsonVal(sessions) "\n")))

procedure(ACL_addSession(sid info)
  let(((sessions ACL_loadSessions()))
    ACL_saveSessions(cons(list(sid info)
                          remove(assoc(sid sessions) sessions)))))

procedure(ACL_removeSession(sid)
  let(((sessions ACL_loadSessions()))
    ACL_saveSessions(remove(assoc(sid sessions) sessions))))

procedure(ACL_handleStaleSession(stderrLine)
  ; Called from the stderr handler when claude reports an unknown
  ; --resume id. Strip the id from sessions.json so we don't try to
  ; restore it next time, and clear ACL_sessionId so the next
  ; ACL_ensureClaude starts fresh instead of looping on the bad id.
  when(pcreMatchp(ACL_noSessionRe stderrLine)
    let(((sid pcreSubstitute(ACL_noSessionRe "\\1")))
      when(ACL_nonEmpty(sid)
        printf("ACL: removing stale session id %s from sessions.json\n" sid)
        ACL_removeSession(sid)
        when(ACL_sessionId == sid
          ACL_sessionId = nil)))))

procedure(ACL_getSession(sid)
  cadr(assoc(sid ACL_loadSessions())))

procedure(ACL_getBoardSessions(boardPath)
  let(((normBoard ACL_normPath(boardPath)))
    setof(pair ACL_loadSessions()
      ACL_normPath(ACL_jGet(cadr(pair) "board")) == normBoard)))

procedure(ACL_sortSessionsByTime(sessions)
  ; Sort session entries newest-first by their "time" field.
  ; Each entry is (sid info-alist); time is a string-encoded epoch second.
  sort(copy(sessions)
    lambda((a b)
      let(((ta atoi(or(ACL_jGet(cadr(a) "time") "0")))
           (tb atoi(or(ACL_jGet(cadr(b) "time") "0"))))
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
    ; Write MCP config for Claude CLI. The MCP server discovers its
    ; session UUID from CLAUDE_LAUNCHER_SESSION_FILE (set by claude on
    ; launch) and constructs its log dir relative to its own location.
    ;
    ; Copy allegro_mcp.py into ACL_homeDir before pointing the config
    ; at it to avoid potential sandboxing issues.
    mcpConfigFile = ACL_normPath(strcat(ACL_homeDir "mcp_config.json"))
    let(((mcpScript ACL_normPath(strcat(ACL_homeDir "allegro_mcp.py"))))
      ACL_copyFile(strcat(ACL_scriptDir "allegro_mcp.py") mcpScript)
      fp = outfile(mcpConfigFile)
      when(fp
        fprintf(fp "%s" ACL_jsonObj(list("mcpServers"
          list(list("allegro" list(
            list("command" if(ACL_isWindows "python" "python3"))
            list("args" list(mcpScript))))))))
        close(fp)))
    promptFile = ACL_normPath(strcat(ACL_homeDir "PROMPT.md"))
    fp = outfile(promptFile)
    when(fp
      fprintf(fp "%s" ACL_buildSystemPrompt())
      ; Claude only honors the LAST --append-system-prompt-file flag,
      ; so the cached docs (if any) get concatenated onto our own
      ; prompt and passed via a single flag.
      unless(ACL_fast
        let(((doc ACL_findOrPlanDocs()))
          when(isFile(doc)
            fprintf(fp "\n\n%s" ACL_readFile(doc)))))
      close(fp))
    installRoot = ACL_axlGetPath("allegro_install_root")
    siteDir = ACL_axlGetPath("allegro_site")
    pcbenvDir = ACL_pcbenvDir()
    projectDir = ACL_normPath(pcreReplace(ACL_lastPathCompRe
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
        "mcp__allegro__allegro_execute,"
        "mcp__allegro__allegro_read_file,"
        "mcp__allegro__allegro_write_file,"
        "mcp__allegro__allegro_edit_file,"
        "mcp__allegro__allegro_multi_edit_file"))
      "--disallowedTools" "AskUserQuestion,Edit,Write,NotebookEdit"
      "--model" "opus[1m]"
      "--effort" "max")
    ACL_resumeIsFork = and(resumeId fork t)
    when(resumeId
      args = append1(args "--resume")
      args = append1(args resumeId)
      when(fork args = append1(args "--fork-session")))
    cmd = buildString(args " ")
    when(ACL_nonEmpty(ACL_claudeArgs)
      cmd = strcat(cmd " " ACL_claudeArgs))
    let(((fp outfile(strcat(ACL_homeDir "raw.log") "a")))
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
        axlFlushDisplay())
      'ACL_claudeExitHandler)
    ipcWaitForProcess(ACL_claude)
    unless(and(ACL_claude ipcIsAliveProcess(ACL_claude))
      ACL_setStatus("Failed to initialize!")
      printf("*Error* ACL: claude process failed to start. Command: %s\n" cmd))))

procedure(ACL_claudeExitHandler(id status)
  ; postFunc registered with ipcBeginProcess. Surfaces unexpected
  ; exits in the chat log; quiet on deliberate stop (see ACL_stopClaude).
  ACL_claude = nil
  ACL_pendingInput = nil
  unless(ACL_claudeStopRequested
    ACL_setStatus(sprintf(nil "Claude exited (status %L)" status))
    ACL_appendChat(sprintf(nil
      "[Claude process exited unexpectedly (status %L). Send any message to restart.]"
      status)))
  ACL_claudeStopRequested = nil
  when(ACL_form axlFormSetField(ACL_form "send" "Send")))

procedure(ACL_stopClaude()
  ; Suppress the unexpected-exit chat message in the postFunc handler
  ; -- this exit was deliberate.
  ACL_claudeStopRequested = t
  when(and(ACL_claude ipcIsAliveProcess(ACL_claude))
    ; Windows has no POSIX signals, so we have to ipcKillProcess
    if(ACL_isWindows
      ipcKillProcess(ACL_claude)
      ipcSignalProcess(ACL_claude 'TERM)))
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
    let(((pairs list(
        list("type" "user")
        list("message" list(
          list("role" "user")
          list("content" text))))))
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
  ; one of our allegro_* tools arrives. Logs the call and queues it
  ; for top-level execution -- we can't run ACL_execBlock here because
  ; evalstring inside a dataHandler deadlocks.
  ;
  ; The cmd_<seq>.il file is written here in stream context (which is
  ; single-threaded with respect to other stream events), so the
  ; readable log can't get interleaved oddly even if execution hangs.
  letseq(((toolId ACL_jGet(block "id"))
          (toolName or(ACL_jGet(block "name") ""))
          (input ACL_jGet(block "input"))
          (preview ACL_toolPreview(toolName input))
          (seq nil))
    when(and(stringp(toolId) input preview)
      ACL_mcpCmdSeq = ACL_mcpCmdSeq + 1
      seq = ACL_mcpCmdSeq
      when(ACL_mode != "quiet"
        ACL_logWrite(sprintf(nil "\n\n[cmd_%d.il:\n%s]\n\n"
          seq
          if(and(ACL_mode == "snippets"
                 strlen(preview) > ACL_logCodeLimit)
            strcat(substring(preview 1 (ACL_logCodeLimit - 3)) "...")
            preview))))
      when(ACL_sessionLogDir
        ACL_writeFile(sprintf(nil "%s/cmd_%d.il" ACL_sessionLogDir seq) preview))
      ACL_mcpPending = append(ACL_mcpPending list(list(toolId toolName input seq)))
      ; In manual mode, hold the queue until the user types `approve`
      ; (or `reject`). Otherwise schedule a deferred drain.
      if(ACL_mode == "manual"
        ACL_setStatus(
          sprintf(nil "Manual: %d pending...waiting for you to \"approve\" or \"reject\"" length(ACL_mcpPending))
        )
        ACL_mcpScheduleDrain()))))

procedure(ACL_toolPreview(toolName input)
  ; Human-readable representation of a tool call for the cmd_<N>.il
  ; log. allegro_execute logs the SKILL code; the file tools log a
  ; comment-prefixed summary plus any content/edit payloads. Returns
  ; nil for unknown tools.
  cond(
    (toolName == "mcp__allegro__allegro_execute"
      ACL_jGet(input "code"))
    (toolName == "mcp__allegro__allegro_read_file"
      sprintf(nil "; read_file %L" ACL_jGet(input "path")))
    (toolName == "mcp__allegro__allegro_write_file"
      sprintf(nil "; write_file %L\n%s"
        ACL_jGet(input "path") ACL_jGetStr(input "content")))
    (toolName == "mcp__allegro__allegro_edit_file"
      sprintf(nil "; edit_file %L\n;-- old --\n%s\n;-- new --\n%s"
        ACL_jGet(input "path")
        ACL_jGetStr(input "old_string")
        ACL_jGetStr(input "new_string")))
    (toolName == "mcp__allegro__allegro_multi_edit_file"
      let(((edits or(ACL_jGet(input "edits") nil))
           (idx 0)
           parts)
        parts = list(sprintf(nil "; multi_edit_file %L (%d edits)"
          ACL_jGet(input "path") length(edits)))
        foreach(edit edits
          idx = idx + 1
          parts = append(parts list(
            sprintf(nil ";-- edit %d old --" idx)
            ACL_jGetStr(edit "old_string")
            sprintf(nil ";-- edit %d new --" idx)
            ACL_jGetStr(edit "new_string"))))
        buildString(parts "\n")))))

procedure(ACL_mcpScheduleDrain()
  ; Always defer drain via a one-shot timer so ACL_execBlock's
  ; evalstring runs from a clean stack -- never inside a form
  ; callback's let/prog locals (which would dynamic-scope into the
  ; eval'd code) and never inside the dataHandler (deadlocks).
  unless(ACL_mcpExecTimer
    ACL_mcpExecTimer = axlUIWTimerAdd(nil 1 t 'ACL_mcpDrainPending)))

procedure(ACL_mcpDrainPending(@rest args)
  ACL_mcpExecTimer = nil
  let(((pending ACL_mcpPending))
    ACL_mcpPending = nil
    foreach(entry pending
      letseq(((toolId car(entry))
              (toolName cadr(entry))
              (input caddr(entry))
              (seq cadddr(entry))
              (result ACL_runTool(toolName input))
              (ipcOutPath when(ACL_sessionLogDir
                                sprintf(nil "%s/tool_%s.out" ACL_sessionLogDir toolId))))
        when(ACL_sessionLogDir
          ACL_writeFile(sprintf(nil "%s/cmd_%d.out" ACL_sessionLogDir seq) result)
          ; The IPC file the Python MCP server polls for: keyed by
          ; tool_use_id. Atomic publish via temp + rename.
          ACL_writeFileAtomic(ipcOutPath result))))))

procedure(ACL_runTool(toolName input)
  ; Dispatch one tool call by name. Each branch handles its own arg
  ; extraction so adding a tool only touches this proc + ACL_toolPreview.
  cond(
    (toolName == "mcp__allegro__allegro_execute"
      let(((raw errset(ACL_execBlock(ACL_jGet(input "code")))))
        if(raw car(raw) "*error* SKILL execution failed unexpectedly")))
    (toolName == "mcp__allegro__allegro_read_file"
      ACL_toolReadFile(ACL_jGet(input "path")))
    (toolName == "mcp__allegro__allegro_write_file"
      ACL_toolWriteFile(ACL_jGet(input "path")
                        ACL_jGetStr(input "content")))
    (toolName == "mcp__allegro__allegro_edit_file"
      ACL_toolEditFile(ACL_jGet(input "path")
                       ACL_jGetStr(input "old_string")
                       ACL_jGetStr(input "new_string")))
    (toolName == "mcp__allegro__allegro_multi_edit_file"
      ACL_toolMultiEditFile(ACL_jGet(input "path")
                            ACL_jGet(input "edits")))
    (t sprintf(nil "*error* unknown tool: %s" toolName))))

procedure(ACL_jGetStr(obj key)
  ; Like ACL_jGet but returns "" for missing/non-string values, so
  ; callers can treat the result as a string unconditionally.
  let(((v ACL_jGet(obj key)))
    if(stringp(v) v "")))

defvar(ACL_skillFileRe pcreCompile("\\.il$" pcreGenCompileOptBits(?caseLess t)))

procedure(ACL_writeChecked(path content okMsg)
  ; Run the .il syntax check, write the file if it passes, and
  ; return either the syntax-check error or okMsg.
  or(ACL_skillSyntaxCheck(path content)
     progn(ACL_writeFile(path content) okMsg)))

procedure(ACL_validateFilePath(opName path needExisting)
  ; Returns nil if path is a non-empty string and (when needExisting)
  ; refers to an existing file; otherwise an "*error* OPNAME: ..." line.
  cond(
    (null(ACL_nonEmpty(path))
      sprintf(nil "*error* %s: missing path" opName))
    (and(needExisting null(isFile(path)))
      sprintf(nil "*error* %s: not a file: %s" opName path))))

procedure(ACL_toolReadFile(path)
  or(ACL_validateFilePath("read_file" path t)
     ACL_readFile(path)))

procedure(ACL_toolWriteFile(path content)
  or(ACL_validateFilePath("write_file" path nil)
     ACL_writeChecked(path content
       sprintf(nil "Wrote %d bytes to %s" strlen(content) path))))

procedure(ACL_applyEdit(text oldStr newStr)
  ; Apply a single find/replace to text. Returns
  ;   (text newText)    on success
  ;   (error message)   on not-found / non-unique
  letseq(((first nindex(text oldStr))
          (after when(first (first + strlen(oldStr))))
          (second when(after nindex(substring(text after) oldStr))))
    cond(
      (null(first)
        list('error sprintf(nil "old_string not found: %L" oldStr)))
      (second
        list('error sprintf(nil "old_string is not unique: %L" oldStr)))
      (t list('text strcat(substring(text 1 (first - 1))
                           newStr
                           substring(text after)))))))

procedure(ACL_toolEditFile(path oldStr newStr)
  or(ACL_validateFilePath("edit_file" path t)
     when(null(ACL_nonEmpty(oldStr))
       "*error* edit_file: missing old_string")
     let(((res ACL_applyEdit(ACL_readFile(path) oldStr newStr)))
       if(car(res) == 'error
         sprintf(nil "*error* edit_file: %s in %s" cadr(res) path)
         ACL_writeChecked(path cadr(res)
           sprintf(nil "Edited %s (%d bytes)" path strlen(cadr(res))))))))

procedure(ACL_toolMultiEditFile(path edits)
  ; Apply a list of {old_string, new_string} edits in sequence,
  ; failing the whole call (without writing) if any single edit
  ; can't be applied or the final content fails the .il syntax
  ; check. Each edit's old_string must be unique at the time of
  ; that edit -- earlier edits can affect uniqueness for later
  ; ones, which is the same semantics claude's MultiEdit uses.
  or(ACL_validateFilePath("multi_edit_file" path t)
     when(null(and(listp(edits) edits))
       "*error* multi_edit_file: edits must be a non-empty list")
     let(((text ACL_readFile(path))
          (idx 0)
          err)
       foreach(edit edits
         idx = idx + 1
         unless(err
           letseq(((oldStr ACL_jGetStr(edit "old_string"))
                   (newStr ACL_jGetStr(edit "new_string")))
             cond(
               (null(ACL_nonEmpty(oldStr))
                 err = sprintf(nil "edit %d: missing old_string" idx))
               (t letseq(((res ACL_applyEdit(text oldStr newStr)))
                    if(car(res) == 'error
                      err = sprintf(nil "edit %d: %s" idx cadr(res))
                      text = cadr(res))))))))
       if(err
         sprintf(nil "*error* multi_edit_file: %s in %s" err path)
         ACL_writeChecked(path text
           sprintf(nil "Edited %s (%d edits, %d bytes)"
             path length(edits) strlen(text)))))))

procedure(ACL_skillSyntaxCheck(path content)
  ; Syntax-check .il content using only the reader -- no eval, so
  ; nothing in `content` runs even if it tries to escape a wrapper.
  ; We wrap as `progn(<content>) ACL_synEOF__` and read top-level
  ; forms from a string port. Well-formed content gives exactly two
  ; forms: a list whose head is `progn`, then the EOF sentinel. Any
  ; other shape -- extra forms (escape attempt or stray `)`),
  ; missing sentinel (unterminated string / missing close eating
  ; the rest), or wrong head -- is a syntax error.
  when(pcreMatchp(ACL_skillFileRe path)
    let((p forms err)
      p = instring(strcat("progn(\n" content "\n) ACL_synEOF__"))
      forms = car(errset(lineread(p) t))
      close(p)
      cond(
        (or(null(forms) listp(forms) == nil)
          err = "form list missing")
        (length(forms) != 2
          err = sprintf(nil "expected 2 top-level forms, got %d"
                          length(forms)))
        (cadr(forms) != 'ACL_synEOF__
          err = "EOF sentinel missing (unterminated string or paren?)")
        (or(null(listp(car(forms))) car(car(forms)) != 'progn)
          err = "wrapper not preserved (stray `)` in content?)"))
      when(err
        sprintf(nil "*error* syntax check failed for %s: %s" path err)))))

procedure(ACL_writeFile(path content)
  ; Plain (non-atomic) write -- truncates path and writes content.
  ; Used for files where torn writes are acceptable (cmd_<N>.il,
  ; cmd_<N>.out: human-readable session log).
  let(((fp outfile(path)))
    when(fp
      fprintf(fp "%s" content)
      close(fp))))

procedure(ACL_writeFileAtomic(path content)
  ; Atomic write: write to <path>.tmp then rename over <path>. The
  ; rename is atomic on POSIX, near-atomic on Windows (delete + rename
  ; via ACL_renameOver). Used for files that other processes / future
  ; runs read (settings.json, sessions.json, tool_<id>.out polled by
  ; the python MCP server).
  let(((tmp strcat(path ".tmp")))
    ACL_writeFile(tmp content)
    ACL_renameOver(tmp path)))

procedure(ACL_copyFile(src dst)
  ; Stream src to dst line by line. Returns t on success, nil if
  ; either side couldn't be opened. Overwrites dst if it exists.
  letseq(((in infile(src))
          (out when(in outfile(dst)))
          line)
    when(and(in out)
      while(gets(line in) fprintf(out "%s" line)))
    ; Close whichever side was opened, even if the other failed.
    when(in close(in))
    when(out close(out))
    and(in out t)))

procedure(ACL_copyDirFiles(srcDir dstDir)
  ; Copy regular files (skip dotfiles like . and ..) from srcDir into
  ; dstDir, which must already exist. Used when forking a session so
  ; the fork inherits the parent's readable cmd_<n>.il / .out logs
  ; without stealing them.
  foreach(f ACL_listDirFiles(srcDir)
    ACL_copyFile(strcat(srcDir "/" f) strcat(dstDir "/" f))))

procedure(ACL_mcpScanMaxSeq(dir)
  ; Find the highest N from cmd_<N>.il files in dir, so a restored
  ; session continues numbering instead of overwriting prior logs.
  let((high m n)
    high = 0
    foreach(f ACL_listDirFiles(dir)
      when(pcreMatchp(ACL_cmdSeqFileRe f)
        m = pcreSubstitute(ACL_cmdSeqFileRe "\\1")
        n = atoi(m)
        when(and(n n > high) high = n)))
    high))

; ============================================================
; 7. Stream Event Processing
; ============================================================

procedure(ACL_claudeDataHandler(id data)
  let((pos line)
    when(ACL_enableRawLog
      let(((fp outfile(strcat(ACL_homeDir "raw.log") "a")))
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
        let(((newDir strcat(ACL_logDir sid "/"))
             (oldDir when(ACL_sessionId strcat(ACL_logDir ACL_sessionId "/"))))
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
              letseq(((msg ACL_jGet(event "message"))
                      (msgId when(msg ACL_jGet(msg "id"))))
                ACL_streamingMsgId = msgId
                when(and(msgId null(assoc(msgId ACL_streamedMsgLen)))
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
                        let(((entry assoc(ACL_streamingMsgId ACL_streamedMsgLen)))
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
                          "[Session log dir: %s -- holds your prior cmd_<n>.il/.out (allegro_execute code/output) from this session (reference them as appropriate), and is your scratch space for any reports, generated scripts, or working files the user might want to inspect via the Files... button.]"
                          ACL_sessionLogDir)
                          ?isSynthetic t ?noQuery t)))))))
            (evtype == "content_block_start"
              cblock = ACL_jGet(event "content_block")
              cond(
                (and(cblock ACL_jGet(cblock "type") == "tool_use")
                  ACL_hadToolUse = t
                  ACL_setStatus(sprintf(nil "Using %s..."
                    pcreReplace(ACL_mcpToolPrefixRe
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
          entry = when(msgId assoc(msgId ACL_streamedMsgLen))
          content = when(msg ACL_jGet(msg "content"))
          when(content
            fullText = ""
            foreach(block content
              when(and(block ACL_jGet(block "type") == "text")
                text = ACL_jGet(block "text")
                when(text fullText = strcat(fullText text)))
              ; Tool calls for our allegro_* MCP tools: extract the
              ; arguments from the stream and execute locally.
              when(and(block ACL_jGet(block "type") == "tool_use"
                       pcreMatchp(ACL_mcpAllegroToolRe
                         or(ACL_jGet(block "name") "")))
                ACL_handleToolCall(block)))
            ; If we have a tracked entry for this msg, use it as the
            ; high-water mark. Otherwise (no message_start was seen --
            ; e.g. resume mid-turn, or partial stream capture), assume
            ; the entire fullText was already delivered via deltas:
            ; printing it again would duplicate; missing the unstreamed
            ; prefix is the lesser evil.
            seenLen = if(entry cadr(entry) strlen(fullText))
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
                  let(((stripped pcreReplace(ACL_xmlTagRe content "" 0)))
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
  pcreReplace(ACL_trimWSRe code "" 0))

procedure(ACL_execBlock(code)
  ; Execute one SKILL block with error handling.
  ; Returns result string including any printed output.
  prog((result errInfo errMsg output port warnings shellMsgs jfile)
    when(or(null(code) strlen(code) == 0)
      return("(empty block)"))
    ; Check if axl* functions used are defined
    let(((docError ACL_checkFuncDocs(code)))
      when(docError
        return(sprintf(nil "ERROR: %s" docError))))
    ACL_setStatus(strcat("Executing SKILL: "
      pcreReplace(ACL_collapseWSRe code " " 0)))
    ; Capture Allegro shell messages via a temporary journal. This is
    ; the only mechanism that catches errors from axlShell sub-commands
    ; AND axlMsgPut output (errport/poport/errset/muffleWarnings/
    ; axlMsgContext all miss them). Skip if the user has a recording
    ; active -- we can't have two journals.
    unless(ACL_recording
      jfile = strcat(ACL_sessionLogDir "exec_journal.scr")
      errset(axlJournal(jfile)))
    ; Execute with:
    ;   poport redirect to capture printf output
    ;   muffleWarnings to capture warnings
    ;   errsetstring to capture errors as strings (nil=suppress console)
    ;   progn() wrapper so multi-statement blocks all evaluate (without
    ;     the wrapper, errsetstring evaluates only the first form and
    ;     silently drops anything after, so e.g. `x = 5  foreach(...)  x`
    ;     would never execute the foreach or read x back). The wrapper
    ;     also makes the value of the LAST expression the result.
    ; CRITICAL: capture errset.errset before doing anything else --
    ; subsequent SKILL operations clobber it.
    port = outstring()
    result = muffleWarnings(let(((poport port))
      errsetstring(strcat("progn(" code "\n)") nil)))
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
  letseq(((fp infile(path))
          (lines nil)
          line)
    when(fp
      while(gets(line fp)
        when(or(substring(line 1 3) == "\\t " substring(line 1 3) == "\\e ")
          ; Strip "\t (HH:MM:SS) " or "\e (HH:MM:SS) " prefix
          let(((trimmed pcreReplace(ACL_trimWSRe
                          pcreReplace(ACL_journalTSRe line "" 0) "" 0)))
            ; Skip journal boilerplate lines
            unless(or(strlen(trimmed) == 0
                      pcreMatchp(ACL_journalSkipRe trimmed))
              lines = cons(strcat(trimmed "\n") lines)))))
      close(fp))
    buildString(reverse(lines) "")))

procedure(ACL_checkFuncDocs(code)
  ; Check if axl* function names used in code are actually defined.
  ; Returns a warning string if any are undefined, nil if all ok.
  ; Splits the code on non-identifier chars, picks out the axl-words,
  ; dedupes via unique, and reports the ones whose symbol isn't bound.
  let((tokens axlNames missing)
    tokens = parseString(pcreReplace(ACL_nonIdentCharRe code " " 0))
    axlNames = unique(setof(tok tokens pcreMatchp(ACL_axlPrefixRe tok)))
    missing = setof(name axlNames null(fboundp(stringToSymbol(name))))
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
          ACL_saveSettings(strcat(ACL_sessionLogDir "settings.json") ACL_currentSettings()))
        ACL_setStatus(sprintf(nil "Mode: %s" val))
        ; Switching out of manual mode releases any held tool calls.
        ; Drain handles an empty queue gracefully. Done after the
        ; status update so "Mode: auto" lands before any execution
        ; output starts displacing it.
        when(val != "manual"
          ACL_mcpScheduleDrain()))
      (field == "record"
        ACL_toggleRecording(form))
      (field == "fulllog"
        ACL_showFullLog())
      (field == "files"
        ACL_openLogDir())
      (field == "loglines"
        let(((n atoi(val)))
          when(and(n n > 0)
            ACL_logLineLimit = n
            ; Redisplay with new limit
            ACL_logWrite(""))))
      (field == "session"
        ACL_handleSessionPick()))))

procedure(ACL_doSend(form)
  let(((text axlFormGetField(form "userinput"))
       (inManual and(ACL_mode == "manual" ACL_mcpPending)))
    when(and(text strlen(text) > 0)
      cond(
        ; approve/reject are only special-cased while we're actively
        ; holding tool calls in manual mode -- otherwise they're
        ; ordinary chat words that should reach claude.
        (and(inManual pcreMatchp(ACL_approveRe text))
          axlFormSetField(form "userinput" "")
          axlFormSetActiveField(form "userinput")
          ACL_handleApprove(pcreSubstitute(ACL_approveRe "\\1")))
        (and(inManual pcreMatchp(ACL_rejectRe text))
          axlFormSetField(form "userinput" "")
          axlFormSetActiveField(form "userinput")
          ACL_handleReject(pcreSubstitute(ACL_rejectRe "\\1")))
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
    let(((contents ACL_readFile(ACL_journalFile)))
      when(strlen(contents) > 0
        ACL_handleJournal(contents)))
  else
    ACL_journalFile = strcat(ACL_sessionLogDir "journal.scr")
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
    let(((text axlFormGetField(ACL_form "userinput")))
      when(text != ACL_pendingInput
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
  letseq(((elapsed stringToTime(getCurrentTime()) - ACL_lastCmdTime)
          (prefix if(and(ACL_lastCmdTime elapsed > 60)
                     "[The board may have been edited. Re-query the design instead of relying on memory.] "
                     ""))
          (userUuid sprintf(nil "user%d-%d" ACL_uuidEpoch ACL_promptId)))
    ; Send system prefix as synthetic (not displayed, no response generated)
    when(strlen(prefix) > 0
      ACL_sendMessage(prefix ?isSynthetic t ?noQuery t))
    ; Send user's actual message
    ACL_sendMessage(text ?uuid userUuid)
    ; Start polling for input changes (if enabled)
    when(ACL_autoUpdateInput ACL_startInputPoll())))

procedure(ACL_handleApprove(@optional (extra ""))
  ; Caller has already trimmed the leading "approve". Anything left
  ; was extra prompting that doesn't fit the approve/reject channel
  ; -- log it as discarded so the user knows it didn't reach claude.
  if(ACL_nonEmpty(extra)
    ACL_appendChat(sprintf(nil "[Approved. Additional prompting discarded: %s]" extra))
    ACL_appendChat("[Approved.]"))
  ACL_mcpScheduleDrain())

procedure(ACL_handleReject(@optional (extra ""))
  ; Caller has already trimmed the leading "reject". If the user
  ; added context, surface it as the chat line and pass it through to
  ; claude as part of the tool's rejection result so claude knows
  ; what to do next; otherwise use the bare "Rejected." form.
  letseq(((haveExtra ACL_nonEmpty(extra))
          (chatLine if(haveExtra sprintf(nil "[Rejected. %s]" extra) "[Rejected.]"))
          (reason if(haveExtra
            sprintf(nil "*rejected by user in manual mode* -- do not retry. The user said:\n\"%s\"\n. Respond accordingly." extra)
            "*rejected by user in manual mode* -- do not retry. Ask the user what they would like instead.")))
    ACL_appendChat(chatLine)
    ACL_setStatus("Thinking...")
    ; Respond to each pending tool_use with the rejection result.
    ; Claude receives this as the tool's output, so the rejection
    ; rides the tool-use channel -- no separate user message needed.
    let(((pending ACL_mcpPending))
      ACL_mcpPending = nil
      foreach(entry pending
        letseq(((toolId car(entry))
                (ipcOutPath when(ACL_sessionLogDir
                                  sprintf(nil "%s/tool_%s.out" ACL_sessionLogDir toolId))))
          when(ipcOutPath
            ACL_writeFileAtomic(ipcOutPath reason)))))))

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
    sessions = ACL_loadSessions()
    unless(sessions
      ACL_appendChat("No previous sessions. Starting new session.")
      ACL_handleNewSession()
      return(nil))
    ; Build parallel lists of labels and session IDs
    sids = mapcar('car sessions)
    labels = mapcar(lambda((entry)
      letseq(((info cadr(entry))
              (board or(ACL_jGet(info "board") "?"))
              (rawTime ACL_jGet(info "time"))
              (time if(and(rawTime numberp(atoi(rawTime)))
                       timeToString(atoi(rawTime))
                       "?")))
        sprintf(nil "%s  [%s]  (%s)" car(entry) board time)))
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
  pcreReplace(ACL_basenameStripRe path "" 0))

procedure(ACL_findOrPlanDocs()
  ; Look for the cached Allegro docs file across known locations.
  ; Filename is "SPB<sanitized-version>.md". We try the exact version
  ; (with hotfix, e.g. SPB25_1_2025_S020.md) first across all dirs,
  ; then the version without the hotfix suffix (e.g. SPB25_1_2025.md).
  ; Returns the first match found. If nothing matches, returns the
  ; notes-dir path with the exact-version filename so the agent can
  ; create it there.
  letseq(((exactName strcat("SPB"
                              pcreReplace(ACL_versionSanitizeRe
                                axlVersion('fullVersion) "_" 0)
                              ".md"))
          ; Strip the hotfix suffix (trailing "_S<digits>" or "_HF<digits>")
          (baseName pcreReplace(ACL_hotfixStripRe exactName ".md" 0))
          (dirs list(ACL_notesDir
                     ACL_axlGetPath("allegro_pcbenv")
                     ACL_axlGetPath("allegro_site")
                     ACL_scriptDir))
          found)
    ; Exact filename in any dir wins; then the less-specific (no hotfix).
    foreach(name list(exactName baseName)
      foreach(d dirs
        when(and(stringp(d) null(found))
          let(((path strcat(d name)))
            when(isFile(path) found = path)))))
    or(found strcat(ACL_notesDir exactName))))

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
            "  " ACL_notesDir "\n"
            "  " ACL_axlGetPath("allegro_pcbenv") "\n"
            "  " ACL_axlGetPath("allegro_site") "\n"
            "  " ACL_scriptDir "\n"
            "named " ACL_basename(doc) " (or the version-without-hotfix "
            "equivalent).")))))))
  ACL_sendMessage(sprintf(nil "Current board: %L\nSay hello" axlGetDrawingName())
    ?isSynthetic t))

procedure(ACL_handleRestoreSession(sid)
  let(((info ACL_getSession(sid)))
    if(null(info) then
      ; Session not in our sessions.json -- nothing to restore.
      ACL_handleNewSession()
    else
      ACL_sessionId = sid
      ACL_sessionLogDir = strcat(ACL_logDir ACL_sessionId "/")
      ACL_sessionSaved = t
      ACL_logReset()
      ACL_applySettings(or(
        ACL_loadSettings(strcat(ACL_sessionLogDir "settings.json"))
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

procedure(ACL_openPanel(@rest args)
  prog((formFile prompt)
    ; Any args become the initial prompt: typing `claude show me the netlist`
    ; opens the dialog with that text pre-populated and sends it.
    prompt = if(args buildString(args " ") "")
    when(and(ACL_form errset(axlFormDisplay(ACL_form)))
      ; Form already exists -- just queue the prompt if any
      when(strlen(prompt) > 0
        axlFormSetField(ACL_form "userinput" prompt)
        ACL_doSend(ACL_form))
      return(t))
    formFile = strcat(ACL_scriptDir "allegro_claude.form")
    ACL_form = axlFormCreate('ACL_form formFile nil 'ACL_formCB t t)
    when(ACL_form
      axlFormDefaultButton(ACL_form "send")
      ACL_applySettings(ACL_loadSettings(ACL_settingsFile))
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
        letseq(((board axlGetDrawingName())
                (sessions when(board ACL_getBoardSessions(board))))
          ; Auto-resume the most recent session for this board, if any.
          ; If the session id is stale, the stderr handler clears it and
          ; the next user action starts fresh via ACL_ensureClaude.
          if(sessions then
            ACL_handleRestoreSession(car(car(ACL_sortSessionsByTime(sessions))))
          else
            ACL_handleNewSession())))
      ; If a prompt was given on the command line, send it after setup.
      when(strlen(prompt) > 0
        axlFormSetField(ACL_form "userinput" prompt)
        ACL_doSend(ACL_form)))))

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

procedure(ACL_checkTrue(name got)
  ; Like ACL_check but coerces got to a boolean -- avoids the noisy
  ; `ACL_check("...", and(x t), t)` idiom.
  ACL_check(name and(got t) t))

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
  ; Pathological: literal "\\n" (backslash + n) must NOT decode to a
  ; newline -- exercises the sentinel-swap in jUnescape.
  ACL_check("escaped backslash-n"
    car(ACL_jParse("\"a\\\\nb\""))  "a\\nb")
  ACL_check("escaped slash"
    car(ACL_jParse("\"a\\/b\""))    "a/b")
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
  let(((o car(ACL_jParse("{\"x\":10,\"y\":20}"))))
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
  ; List-of-lists with non-string keys must serialize as a nested
  ; array, not as an object with weird non-string keys.
  ACL_check("val nested arr"  ACL_jsonVal('((1 2) 3))           "[[1,2],3]")
  ACL_check("val list of arr" ACL_jsonVal(list(list(1) list(2))) "[[1],[2]]")
  ACL_check("jsonObj"
    ACL_jsonObj(list("type" "msg") list("n" 1))
    "{\"type\":\"msg\",\"n\":1}")

  printf("\n--- JSON Roundtrip ---\n")
  letseq(((orig ACL_jsonObj(list("type" "user_message")
                            list("content" "hello\nworld")))
          (parsed car(ACL_jParse(orig))))
    ACL_check("rt type"    ACL_jGet(parsed "type")     "user_message")
    ACL_check("rt content" ACL_jGet(parsed "content")  "hello\nworld"))

  printf("\n--- SKILL Execution ---\n")
  let(((savedForm ACL_form))
    ACL_form = nil
    ACL_check("exec simple"
      ACL_execBlock("(plus 40 2)")
      "Result: 42")
    ACL_check("checkFuncDocs all bound"
      ACL_checkFuncDocs("axlMsgPut(\"hi\") axlGetVariable(\"foo\")")
      nil)
    ACL_checkTrue("checkFuncDocs flags missing"
      ACL_checkFuncDocs("axlMsgPut(x) axlBogusNotARealFunction()"))
    ACL_check("exec empty"
      ACL_execBlock("")
      "(empty block)")
    ACL_check("exec with output"
      ACL_execBlock("printf(\"hello\\n\") 99")
      "Output:\nhello\n\nResult: 99")
    let(((errResult ACL_execBlock("(undefined_function_xyz)")))
      ACL_checkTrue("exec error" nindex(errResult "*Error*")))
    ; Allegro shell errors should be captured via the journal
    let(((shellResult ACL_execBlock("axlShell(\"zoom bogus\")")))
      ACL_checkTrue("exec captures shell error"
        nindex(shellResult "Command not found")))
    ; SKILL error() message text should survive
    let(((errResult ACL_execBlock("error(\"my custom error\")")))
      ACL_checkTrue("exec preserves error msg"
        nindex(errResult "my custom error")))
    ; axlMsgPut output should be captured (journal)
    let(((msgResult ACL_execBlock("axlMsgPut(\"a logged note\")")))
      ACL_checkTrue("exec captures axlMsgPut"
        nindex(msgResult "a logged note")))
    ; Multi-statement blocks should all evaluate; result is the last
    ; expression's value. (Without the progn wrapper, errsetstring
    ; would only run the first form.)
    ACL_check("exec multi-statement"
      ACL_execBlock("x = 7\ny = 5\nx + y")
      "Result: 12")
    ACL_check("exec multi-statement side effects"
      ACL_execBlock("acc = 0\nfor(i 1 4 acc = acc + i)\nacc")
      "Result: 10")
    ; A trailing line comment must not eat the closing paren we add.
    ACL_check("exec trailing comment"
      ACL_execBlock("(plus 1 2) ; comment with no trailing newline")
      "Result: 3")
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
    ACL_sessionLogDir = strcat(ACL_homeDir "mcp_test/")
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
    ACL_checkTrue("cmd il written"
      isFile(strcat(ACL_sessionLogDir "cmd_1.il")))
    ACL_checkTrue("cmd out written"
      isFile(strcat(ACL_sessionLogDir "cmd_1.out")))
    ACL_checkTrue("ipc out written"
      isFile(strcat(ACL_sessionLogDir "tool_toolu_test_42.out")))
    ACL_check("cmd il content"
      ACL_readFile(strcat(ACL_sessionLogDir "cmd_1.il")) "(plus 40 2)")
    ACL_check("ipc out content"
      ACL_readFile(strcat(ACL_sessionLogDir "tool_toolu_test_42.out"))
      "Result: 42")
    ; Multiple queued at once should all execute on one drain
    ACL_handleToolCall(list(list("id" "toolu_a") list("name" "mcp__allegro__allegro_execute")
                            list("input" list(list("code" "(plus 1 1)")))))
    ACL_handleToolCall(list(list("id" "toolu_b") list("name" "mcp__allegro__allegro_execute")
                            list("input" list(list("code" "(plus 2 2)")))))
    ACL_check("queued two" length(ACL_mcpPending) 2)
    ACL_mcpDrainPending()
    ACL_check("seq advanced again" ACL_mcpCmdSeq 3)
    ACL_check("ipc a" ACL_readFile(strcat(ACL_sessionLogDir "tool_toolu_a.out"))
      "Result: 2")
    ACL_check("ipc b" ACL_readFile(strcat(ACL_sessionLogDir "tool_toolu_b.out"))
      "Result: 4")
    ; Block missing required fields is ignored
    ACL_handleToolCall(list(list("name" "mcp__allegro__allegro_execute")
                            list("input" list(list("code" "(plus 9 9)")))))
    ACL_check("missing id ignored" ACL_mcpPending nil)
    ; ACL_mcpScanMaxSeq finds the highest existing N
    ACL_check("scan max seq sees existing"
      ACL_mcpScanMaxSeq(ACL_sessionLogDir) 3)
    ; Empty dir -> 0
    let(((emptyDir strcat(ACL_homeDir "mcp_test_empty/")))
      createDir(emptyDir)
      ACL_check("scan max seq empty dir"
        ACL_mcpScanMaxSeq(emptyDir) 0)
      errset(deleteDir(emptyDir)))
    ; Nonexistent dir -> 0 (errset swallows)
    ACL_check("scan max seq nonexistent dir"
      ACL_mcpScanMaxSeq(strcat(ACL_homeDir "no_such_dir_42")) 0)

    ; --- Manual mode: tool calls are HELD until approve/reject ---
    let(((savedMode ACL_mode))
      ACL_mode = "manual"
      ACL_mcpPending = nil
      ACL_handleToolCall(list(list("id" "toolu_manual_1")
                              list("name" "mcp__allegro__allegro_execute")
                              list("input" list(list("code" "(plus 5 5)")))))
      ACL_check("manual: queued" length(ACL_mcpPending) 1)
      ACL_check("manual: timer NOT armed" ACL_mcpExecTimer nil)
      ; Approve schedules a deferred drain; in tests, run it inline.
      ACL_handleApprove()
      ACL_checkTrue("manual: approve scheduled" ACL_mcpExecTimer)
      ACL_mcpDrainPending()
      ACL_check("manual: approve drained" ACL_mcpPending nil)
      ACL_checkTrue("manual: approve wrote .out"
        isFile(strcat(ACL_sessionLogDir "tool_toolu_manual_1.out")))

      ; Reject writes a rejection .out for each pending so the MCP
      ; server doesn't hang polling.
      ACL_handleToolCall(list(list("id" "toolu_manual_2")
                              list("name" "mcp__allegro__allegro_execute")
                              list("input" list(list("code" "(plus 7 7)")))))
      ACL_check("manual: queued again" length(ACL_mcpPending) 1)
      ACL_handleReject()
      ACL_check("manual: reject cleared" ACL_mcpPending nil)
      ACL_checkTrue("manual: reject wrote .out"
        isFile(strcat(ACL_sessionLogDir "tool_toolu_manual_2.out")))
      ACL_check("manual: reject .out content"
        ACL_readFile(strcat(ACL_sessionLogDir "tool_toolu_manual_2.out"))
        "*rejected by user in manual mode* -- do not retry. Ask the user what they would like instead.")

      ; Reject WITH extra prompting -- chat shows the user's text and
      ; the .out passes their words through to claude.
      ACL_handleToolCall(list(list("id" "toolu_manual_3")
                              list("name" "mcp__allegro__allegro_execute")
                              list("input" list(list("code" "(plus 9 9)")))))
      ACL_handleReject("but use snap_grid first")
      ACL_check("manual: reject extra .out content"
        ACL_readFile(strcat(ACL_sessionLogDir "tool_toolu_manual_3.out"))
        "*rejected by user in manual mode* -- do not retry. The user said:\n\"but use snap_grid first\"\n. Respond accordingly.")

      ; approve/reject regexes accept variants and pass extras
      ACL_check("approveRe bare" pcreMatchp(ACL_approveRe "approve") t)
      ACL_check("approveRe ed+text"
        and(pcreMatchp(ACL_approveRe "approved. good job")
            pcreSubstitute(ACL_approveRe "\\1")) "good job")
      ACL_check("rejectRe ed+text"
        and(pcreMatchp(ACL_rejectRe "rejected, but try this instead")
            pcreSubstitute(ACL_rejectRe "\\1")) "but try this instead")
      ACL_check("approveRe doesn't match unrelated"
        pcreMatchp(ACL_approveRe "what does approve do?") nil)

      ACL_mode = savedMode)

    ; Clean up
    foreach(f ACL_listDirFiles(ACL_sessionLogDir)
      errset(deleteFile(strcat(ACL_sessionLogDir f))))
    errset(deleteDir(ACL_sessionLogDir))
    ACL_sessionLogDir = savedSessionDir
    ACL_mcpCmdSeq = savedSeq
    ACL_mcpPending = savedPending
    ACL_form = savedForm)

  printf("\n--- SKILL syntax check ---\n")
  ; Reader-only check: must accept well-formed content, reject
  ; structural problems, and crucially MUST NOT execute content
  ; (no eval -- code injection attempts read as extra forms and
  ; are rejected).
  let((dummy)
    ; Non-.il paths: skipped, returns nil
    ACL_check("syn skip non-.il"
      ACL_skillSyntaxCheck("foo.txt" "anything goes ;;) ((") nil)
    ; Well-formed
    ACL_check("syn accept simple"
      ACL_skillSyntaxCheck("a.il" "(plus 1 2)") nil)
    ACL_check("syn accept multi-form"
      ACL_skillSyntaxCheck("a.il" "(plus 1 2)\n(times 3 4)") nil)
    ACL_check("syn accept empty"
      ACL_skillSyntaxCheck("a.il" "") nil)
    ACL_check("syn accept whitespace only"
      ACL_skillSyntaxCheck("a.il" "\n\n  \n") nil)
    ACL_check("syn accept procedure def"
      ACL_skillSyntaxCheck("a.il"
        "procedure(foo(x) plus(x 1))\n") nil)
    ACL_check("syn accept comments"
      ACL_skillSyntaxCheck("a.il" "; just a comment\n(plus 1 2)") nil)
    ACL_check("syn accept literal nil form"
      ACL_skillSyntaxCheck("a.il" "nil") nil)
    ; Malformed
    ACL_checkTrue("syn reject extra close"
      ACL_skillSyntaxCheck("a.il" "(plus 1 2)))"))
    ACL_checkTrue("syn reject missing close"
      ACL_skillSyntaxCheck("a.il" "(plus 1 2"))
    ACL_checkTrue("syn reject unterm string"
      ACL_skillSyntaxCheck("a.il" "(setq x \"open"))
    ; Safety: payloads designed to escape the wrapper. The probe
    ; that matters is that the global ACL_synProbeFlag stays nil --
    ; reader-only check must NOT execute the payload.
    ACL_synProbeFlag = nil
    ACL_checkTrue("syn reject escape-progn payload"
      ACL_skillSyntaxCheck("a.il"
        ") (setq ACL_synProbeFlag 'PWNED) progn("))
    ACL_check("syn payload did not run"
      ACL_synProbeFlag nil)
    ; Trailing junk after a balanced form: extra top-level form,
    ; reader sees 3 forms (progn body, junk, EOF), rejected.
    ACL_synProbeFlag = nil
    ACL_checkTrue("syn reject trailing junk after balance"
      ACL_skillSyntaxCheck("a.il"
        "(setq x 1)\n) (setq ACL_synProbeFlag 'PWNED) progn("))
    ACL_check("syn trailing-junk payload did not run"
      ACL_synProbeFlag nil))

  let(((tmpDir strcat(ACL_homeDir "filetool_test/")))
    ACL_createDirP(tmpDir)
    ; read_file: missing file
    ACL_check("read_file missing"
      ACL_runTool("mcp__allegro__allegro_read_file"
        list(list("path" strcat(tmpDir "nope.txt"))))
      sprintf(nil "*error* read_file: not a file: %snope.txt" tmpDir))
    ; write_file plain text
    let(((p strcat(tmpDir "hello.txt")))
      ACL_runTool("mcp__allegro__allegro_write_file"
        list(list("path" p) list("content" "hi there\n")))
      ACL_check("write_file content"
        ACL_runTool("mcp__allegro__allegro_read_file" list(list("path" p)))
        "hi there\n"))
    ; write_file SKILL with valid syntax
    let(((p strcat(tmpDir "good.il")))
      ACL_runTool("mcp__allegro__allegro_write_file"
        list(list("path" p)
             list("content" "(plus 1 2)\n(times 3 4)\n")))
      ACL_check("write_file .il valid round-trip"
        ACL_runTool("mcp__allegro__allegro_read_file" list(list("path" p)))
        "(plus 1 2)\n(times 3 4)\n"))
    ; write_file SKILL with bad syntax: rejected, file untouched
    let(((p strcat(tmpDir "bad.il")))
      ACL_runTool("mcp__allegro__allegro_write_file"
        list(list("path" p) list("content" "(plus 1 2)))\n")))
      ACL_check("write_file .il bad: file not created"
        isFile(p) nil)
      ACL_checkTrue("write_file .il bad: returns error"
        pcreMatchp(pcreCompile("syntax check failed")
          ACL_runTool("mcp__allegro__allegro_write_file"
            list(list("path" p) list("content" "unbalanced \"string"))))))
    ; edit_file: unique replace
    let(((p strcat(tmpDir "edit.txt")))
      ACL_runTool("mcp__allegro__allegro_write_file"
        list(list("path" p) list("content" "alpha\nbeta\ngamma\n")))
      ACL_runTool("mcp__allegro__allegro_edit_file"
        list(list("path" p) list("old_string" "beta")
             list("new_string" "BETA")))
      ACL_check("edit_file unique replace"
        ACL_runTool("mcp__allegro__allegro_read_file" list(list("path" p)))
        "alpha\nBETA\ngamma\n"))
    ; edit_file: not found
    let(((p strcat(tmpDir "edit.txt")))
      ACL_checkTrue("edit_file not found"
        pcreMatchp(pcreCompile("not found")
          ACL_runTool("mcp__allegro__allegro_edit_file"
            list(list("path" p) list("old_string" "no_such_text")
                 list("new_string" "x"))))))
    ; edit_file: ambiguous
    let(((p strcat(tmpDir "ambig.txt")))
      ACL_runTool("mcp__allegro__allegro_write_file"
        list(list("path" p) list("content" "x\nx\n")))
      ACL_checkTrue("edit_file not unique"
        pcreMatchp(pcreCompile("not unique")
          ACL_runTool("mcp__allegro__allegro_edit_file"
            list(list("path" p) list("old_string" "x")
                 list("new_string" "y"))))))
    ; edit_file: .il syntax check on result.
    let(((p strcat(tmpDir "edit.il")))
      ACL_runTool("mcp__allegro__allegro_write_file"
        list(list("path" p) list("content" "(plus 1 2)\n")))
      ACL_checkTrue("edit_file .il bad result rejected"
        pcreMatchp(pcreCompile("syntax check failed")
          ACL_runTool("mcp__allegro__allegro_edit_file"
            list(list("path" p) list("old_string" "(plus 1 2)")
                 list("new_string" "1 2)))")))))
      ACL_check("edit_file .il bad: file unchanged"
        ACL_runTool("mcp__allegro__allegro_read_file" list(list("path" p)))
        "(plus 1 2)\n"))
    ; multi_edit_file: sequential edits, each unique at its turn.
    let(((p strcat(tmpDir "multi.txt")))
      ACL_runTool("mcp__allegro__allegro_write_file"
        list(list("path" p) list("content" "alpha\nbeta\ngamma\n")))
      ACL_runTool("mcp__allegro__allegro_multi_edit_file"
        list(list("path" p)
             list("edits" list(
               list(list("old_string" "alpha") list("new_string" "ALPHA"))
               list(list("old_string" "gamma") list("new_string" "GAMMA"))))))
      ACL_check("multi_edit_file applies all"
        ACL_runTool("mcp__allegro__allegro_read_file" list(list("path" p)))
        "ALPHA\nbeta\nGAMMA\n"))
    ; multi_edit_file: any failure aborts atomically (file unchanged).
    let(((p strcat(tmpDir "multi_atomic.txt")))
      ACL_runTool("mcp__allegro__allegro_write_file"
        list(list("path" p) list("content" "one\ntwo\n")))
      ACL_checkTrue("multi_edit_file atomic on failure"
        pcreMatchp(pcreCompile("not found")
          ACL_runTool("mcp__allegro__allegro_multi_edit_file"
            list(list("path" p)
                 list("edits" list(
                   list(list("old_string" "one") list("new_string" "ONE"))
                   list(list("old_string" "missing") list("new_string" "X"))))))))
      ACL_check("multi_edit_file unchanged after failure"
        ACL_runTool("mcp__allegro__allegro_read_file" list(list("path" p)))
        "one\ntwo\n"))
    ; Cleanup
    foreach(f ACL_listDirFiles(tmpDir)
      errset(deleteFile(strcat(tmpDir f))))
    errset(deleteDir(tmpDir)))

  printf("\n--- Extra prompt files ---\n")
  let(((tmpDir strcat(ACL_homeDir "extraprompt_test/"))
       (savedExtra ACL_extraPromptFiles)
       p1 p2 fp basePrompt withExtras)
    ACL_createDirP(tmpDir)
    p1 = strcat(tmpDir "policy.md")
    p2 = strcat(tmpDir "library.md")
    fp = outfile(p1) when(fp fprintf(fp "SITE_POLICY_MARKER") close(fp))
    fp = outfile(p2) when(fp fprintf(fp "LIBRARY_CONVENTIONS_MARKER") close(fp))
    basePrompt = ACL_buildSystemPrompt()
    ACL_check("extra prompt: marker absent by default"
      pcreMatchp(pcreCompile("SITE_POLICY_MARKER") basePrompt) nil)
    ACL_extraPromptFiles = list(p1 p2)
    withExtras = ACL_buildSystemPrompt()
    ACL_checkTrue("extra prompt: first file appended"
      pcreMatchp(pcreCompile("SITE_POLICY_MARKER") withExtras))
    ACL_checkTrue("extra prompt: second file appended"
      pcreMatchp(pcreCompile("LIBRARY_CONVENTIONS_MARKER") withExtras))
    ; Missing files are silently skipped (don't fail the build).
    ACL_extraPromptFiles = list(p1 strcat(tmpDir "nope.md") p2)
    let(((p ACL_buildSystemPrompt()))
      ACL_checkTrue("extra prompt: missing skipped, others kept"
        and(pcreMatchp(pcreCompile("SITE_POLICY_MARKER") p)
            pcreMatchp(pcreCompile("LIBRARY_CONVENTIONS_MARKER") p))))
    ; Non-string entries are skipped, not errored.
    ACL_extraPromptFiles = list(p1 nil 42 p2)
    let(((p ACL_buildSystemPrompt()))
      ACL_checkTrue("extra prompt: non-strings skipped"
        and(pcreMatchp(pcreCompile("SITE_POLICY_MARKER") p)
            pcreMatchp(pcreCompile("LIBRARY_CONVENTIONS_MARKER") p))))
    ; Cleanup
    ACL_extraPromptFiles = savedExtra
    foreach(f ACL_listDirFiles(tmpDir)
      errset(deleteFile(strcat(tmpDir f))))
    errset(deleteDir(tmpDir)))

  printf("\n--- Form File ---\n")
  letseq(((formPath strcat(ACL_scriptDir "allegro_claude.form"))
          (formHandle axlFormCreate('ACL_testForm formPath nil nil nil)))
    ACL_checkTrue("form parse" formHandle)
    when(formHandle axlFormClose(formHandle)))

  printf("\n--- Doc Lookup ---\n")
  let(((savedNotes ACL_notesDir) (savedScript ACL_scriptDir)
       (savedSite axlGetVariable("allegro_site"))
       (savedPcb axlGetVariable("allegro_pcbenv"))
       doc exactName baseName notesDir pcbDir siteDir scriptDir)
    notesDir = strcat(ACL_homeDir "doc_test_notes/")
    pcbDir = strcat(ACL_homeDir "doc_test_pcbenv/")
    siteDir = strcat(ACL_homeDir "doc_test_site/")
    scriptDir = strcat(ACL_homeDir "doc_test_script/")
    foreach(d list(notesDir pcbDir siteDir scriptDir) createDir(d))
    ACL_notesDir = notesDir
    ACL_scriptDir = scriptDir
    axlSetVariable("allegro_pcbenv" pcbDir)
    axlSetVariable("allegro_site" siteDir)
    exactName = strcat("SPB"
      pcreReplace(ACL_versionSanitizeRe axlVersion('fullVersion) "_" 0) ".md")
    baseName = pcreReplace(ACL_hotfixStripRe
      exactName ".md" 0)
    let((fp p)
      ; ---- 1. No files anywhere -> default to notesDir/exactName
      doc = ACL_findOrPlanDocs()
      ACL_check("doc default to notesDir"
        doc strcat(notesDir exactName))

      ; ---- 2. Exact in scriptDir wins (alone)
      p = strcat(scriptDir exactName)
      fp = outfile(p) when(fp fprintf(fp "x") close(fp))
      ACL_check("doc exact in scriptDir" ACL_findOrPlanDocs() p)
      deleteFile(p)

      ; ---- 3. Exact in siteDir wins (alone)
      p = strcat(siteDir exactName)
      fp = outfile(p) when(fp fprintf(fp "x") close(fp))
      ACL_check("doc exact in siteDir" ACL_findOrPlanDocs() p)
      deleteFile(p)

      ; ---- 4. Exact in pcbDir wins (alone)
      p = strcat(pcbDir exactName)
      fp = outfile(p) when(fp fprintf(fp "x") close(fp))
      ACL_check("doc exact in pcbDir" ACL_findOrPlanDocs() p)
      deleteFile(p)

      ; ---- 5. Exact in notesDir wins (alone)
      p = strcat(notesDir exactName)
      fp = outfile(p) when(fp fprintf(fp "x") close(fp))
      ACL_check("doc exact in notesDir" ACL_findOrPlanDocs() p)
      deleteFile(p)

      ; ---- 6. Dir priority: notesDir > pcbenv when both have exact
      letseq(((pNotes strcat(notesDir exactName))
              (pPcb   strcat(pcbDir exactName)))
        fp = outfile(pNotes) when(fp fprintf(fp "n") close(fp))
        fp = outfile(pPcb) when(fp fprintf(fp "p") close(fp))
        ACL_check("doc notesDir beats pcbenv" ACL_findOrPlanDocs() pNotes)
        deleteFile(pNotes) deleteFile(pPcb))

      ; ---- 7. Dir priority: pcbenv > site
      letseq(((pPcb  strcat(pcbDir exactName))
              (pSite strcat(siteDir exactName)))
        fp = outfile(pPcb) when(fp fprintf(fp "p") close(fp))
        fp = outfile(pSite) when(fp fprintf(fp "s") close(fp))
        ACL_check("doc pcbenv beats site" ACL_findOrPlanDocs() pPcb)
        deleteFile(pPcb) deleteFile(pSite))

      ; ---- 8. Dir priority: site > scriptDir
      letseq(((pSite   strcat(siteDir exactName))
              (pScript strcat(scriptDir exactName)))
        fp = outfile(pSite) when(fp fprintf(fp "s") close(fp))
        fp = outfile(pScript) when(fp fprintf(fp "x") close(fp))
        ACL_check("doc site beats scriptDir" ACL_findOrPlanDocs() pSite)
        deleteFile(pSite) deleteFile(pScript))

      ; ---- 9. Exact in scriptDir beats base in notesDir
      letseq(((pExact strcat(scriptDir exactName))
              (pBase  strcat(notesDir baseName)))
        fp = outfile(pExact) when(fp fprintf(fp "e") close(fp))
        fp = outfile(pBase) when(fp fprintf(fp "b") close(fp))
        ACL_check("doc exact anywhere beats base in notes"
          ACL_findOrPlanDocs() pExact)
        deleteFile(pExact) deleteFile(pBase))

      ; ---- 10. Base name found in notesDir when no exact exists
      p = strcat(notesDir baseName)
      fp = outfile(p) when(fp fprintf(fp "x") close(fp))
      ACL_check("doc base in notesDir" ACL_findOrPlanDocs() p)
      deleteFile(p)

      ; ---- 11. Base name found in scriptDir when nothing else
      p = strcat(scriptDir baseName)
      fp = outfile(p) when(fp fprintf(fp "x") close(fp))
      ACL_check("doc base in scriptDir" ACL_findOrPlanDocs() p)
      deleteFile(p)

      ; ---- 12. Base in notesDir beats base in pcbenv (priority within base)
      letseq(((pNotes strcat(notesDir baseName))
              (pPcb   strcat(pcbDir baseName)))
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
  let((tmpFile settings loaded
       (savedMode ACL_mode) (savedFast ACL_fast)
       (savedClaudeArgs ACL_claudeArgs))
    tmpFile = strcat(ACL_sessionLogDir "test_settings.json")
    ; Round-trip save/load
    settings = list(list("mode" "verbose"))
    ACL_saveSettings(tmpFile settings)
    loaded = ACL_loadSettings(tmpFile)
    ACL_check("settings roundtrip" loaded settings)
    ACL_check("settings get mode" ACL_jGet(loaded "mode") "verbose")
    ; currentSettings reflects the live globals -- pin them to known
    ; values, otherwise the test depends on whatever settings.json
    ; was applied at load time.
    ACL_mode = "quiet"
    ACL_fast = nil
    ACL_claudeArgs = ""
    ACL_check("currentSettings" ACL_currentSettings()
      list(list("mode" "quiet") list("fast" 'false) list("claudeArgs" "")))
    ; applySettings updates ACL_mode
    ACL_applySettings(list(list("mode" "manual")))
    ACL_check("applySettings" ACL_mode "manual")
    ; claudeArgs round-trips
    ACL_applySettings(list(list("claudeArgs" "--debug api,hooks")))
    ACL_check("applySettings claudeArgs" ACL_claudeArgs "--debug api,hooks")
    ; Load nonexistent file returns nil
    ACL_check("load missing" ACL_loadSettings("/tmp/nonexistent_acl_test.json") nil)
    ; Cleanup
    deleteFile(tmpFile)
    ACL_claudeArgs = savedClaudeArgs
    ACL_fast = savedFast
    ACL_mode = savedMode)

  printf("\n--- Sessions ---\n")
  let(((savedFile ACL_sessionsFile) (savedSid ACL_sessionId) sample stale sorted)
    ACL_sessionsFile = strcat(ACL_homeDir "sessions_test.json")
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
    ACL_sessionsFile = strcat(ACL_homeDir "sessions_rekey_test.json")
    ACL_sessionId = "rekey-old-2"
    parentDir = strcat(ACL_logDir "rekey-old-2/")
    ACL_createDirP(parentDir)
    let(((fp outfile(strcat(parentDir "/cmd_3.il"))))
      when(fp fprintf(fp "(plus 2 2)") close(fp))
      fp = outfile(strcat(parentDir "/cmd_3.out"))
      when(fp fprintf(fp "Result: 4") close(fp)))
    ACL_addSession("rekey-old-2" list(list("board" "/tmp/y.brd") list("time" "200")))
    ACL_resumeIsFork = t
    ACL_processStreamLine("{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"rekey-new-2\"}")
    newDir = strcat(ACL_logDir "rekey-new-2/")
    ACL_check("fork: id updated" ACL_sessionId "rekey-new-2")
    ACL_check("fork: parent dir preserved" isDir(parentDir) t)
    ACL_checkTrue("fork: parent cmd preserved"
      isFile(strcat(parentDir "/cmd_3.il")))
    ACL_check("fork: new dir present" isDir(newDir) t)
    ACL_checkTrue("fork: cmd file copied to new"
      isFile(strcat(newDir "/cmd_3.il")))
    ACL_check("fork: copied content matches"
      ACL_readFile(strcat(newDir "/cmd_3.il")) "(plus 2 2)")
    ACL_check("fork: seq seeded from copied files" ACL_mcpCmdSeq 3)
    ACL_checkTrue("fork: parent kept in sessions"
      assoc("rekey-old-2" ACL_loadSessions()))
    ; Fork should NOT pre-add the new sid: the first-text save path
    ; registers it with the current board (not the parent's).
    ACL_check("fork: new id NOT pre-added to sessions"
      assoc("rekey-new-2" ACL_loadSessions()) nil)
    ; cleanup
    foreach(d list(parentDir newDir)
      foreach(f ACL_listDirFiles(d)
        errset(deleteFile(strcat(d "/" f))))
      errset(deleteDir(d)))

    ACL_resumeIsFork = savedFork
    ACL_mcpCmdSeq = savedSeq
    ACL_sessionLogDir = savedLogDir
    ACL_sessionId = savedSid
    deleteFile(ACL_sessionsFile)
    ACL_sessionsFile = savedFile)

  printf("\n--- Resume seq seeding ---\n")
  ; On resume claude returns the SAME sid, so processStreamLine's
  ; new-sid branch never fires. The seq must still be seeded from
  ; existing cmd_<N>.il files on every system/init event, otherwise
  ; tool_use numbering restarts at 1 and overwrites prior turns.
  let(((savedSid ACL_sessionId) (savedLogDir ACL_sessionLogDir)
       (savedSeq ACL_mcpCmdSeq) sid logDir fp)
    sid = "resume-seed-test"
    logDir = strcat(ACL_logDir sid "/")
    ACL_createDirP(logDir)
    fp = outfile(strcat(logDir "/cmd_7.il"))
    when(fp fprintf(fp "(plus 1 1)") close(fp))
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
  ; SessionStart:resume hook events carry transient session_ids that
  ; must not be mistaken for a real sid change. Only system/init is
  ; authoritative.
  let(((savedSid ACL_sessionId) (savedLogDir ACL_sessionLogDir))
    ACL_sessionId = "real-sid"
    ACL_sessionLogDir = strcat(ACL_logDir "real-sid/")
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

  printf("\n--- CP-1252 recode ---\n")
  let(((savedWin ACL_isWindows))
    ACL_isWindows = t
    ; Lossless table mapping: high CP-1252 byte stays in place.
    ACL_check("lossless single byte"
      ACL_recode(strcat("don" ACL_bytes(0xe2 0x80 0x99) "t"))
      strcat("don" ACL_byte(0x92) "t"))
    ; Lossy table mapping: ASCII fallback string.
    ACL_check("lossy ascii"
      ACL_recode(strcat("a" ACL_bytes(0xe2 0x94 0x82) "b")) "a|b")
    ; Catch-all collapses unmapped UTF-8 to a single ?, even when
    ; multiple unmapped sequences are adjacent.
    ACL_check("catchall mixed"
      ACL_recode(strcat("a" ACL_bytes(0xf0 0x9f 0x98 0x80 0xf0 0x9f 0x98 0x81) "b"))
      "a?b")
    ; Catch-all must NOT eat the high CP-1252 bytes the table emitted.
    ACL_check("catchall preserves recoded"
      ACL_recode(ACL_bytes(0xe2 0x80 0x99 0xe2 0x80 0x99))
      strcat(ACL_byte(0x92) ACL_byte(0x92)))
    ACL_check("ascii passthrough"
      ACL_recode("hello world") "hello world")
    ACL_isWindows = nil
    ACL_check("linux passthrough"
      ACL_recode(strcat("don" ACL_bytes(0xe2 0x80 0x99) "t"))
      strcat("don" ACL_bytes(0xe2 0x80 0x99) "t"))
    ACL_isWindows = t
    ACL_check("nil passthrough" ACL_recode(nil) nil)
    ACL_isWindows = savedWin)

  printf("\n--- recode integration via stream ---\n")
  let(((savedBuf ACL_responseBuf) (savedLog ACL_logContent)
       (savedId ACL_streamingMsgId) (savedLen ACL_streamedMsgLen)
       (savedForm ACL_form) (savedWin ACL_isWindows))
    ACL_form = nil ACL_logContent = nil ACL_responseBuf = ""
    ACL_streamingMsgId = nil ACL_streamedMsgLen = nil
    ACL_isWindows = t
    ACL_processStreamLine(strcat(
      "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_start\","
      "\"message\":{\"id\":\"msg_recode\"}}}"))
    ACL_processStreamLine(strcat(
      "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\","
      "\"index\":0,\"delta\":{\"type\":\"text_delta\","
      "\"text\":\"X" ACL_bytes(0xe2 0x94 0x82) "Y\"}}}"))
    ACL_check("stream-time recode"
      ACL_logString() "X|Y")
    ACL_isWindows = savedWin
    ACL_form = savedForm
    ACL_streamedMsgLen = savedLen
    ACL_streamingMsgId = savedId
    ACL_logContent = savedLog
    ACL_responseBuf = savedBuf)

  printf("\n--- Assistant dedup fallback ---\n")
  ; If the stream skipped message_start (resume mid-turn or partial
  ; capture), the assistant event must NOT print the full text on top
  ; of whatever was already streamed via deltas. Verify by feeding a
  ; mid-stream delta + assistant pair with no message_start.
  let(((savedBuf ACL_responseBuf) (savedLog ACL_logContent)
       (savedId ACL_streamingMsgId) (savedLen ACL_streamedMsgLen)
       (savedForm ACL_form))
    ACL_form = nil ACL_logContent = nil ACL_responseBuf = ""
    ACL_streamingMsgId = nil ACL_streamedMsgLen = nil
    ACL_processStreamLine(strcat(
      "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\","
      "\"index\":0,\"delta\":{\"type\":\"text_delta\","
      "\"text\":\" world!\"}}}"))
    ACL_processStreamLine(strcat(
      "{\"type\":\"assistant\",\"message\":{\"id\":\"msg_no_start\","
      "\"content\":[{\"type\":\"text\",\"text\":\"Hello world!\"}]}}"))
    ACL_check("dedup fallback: only streamed text shown"
      ACL_logString() " world!")
    ; Now the normal path: message_start + deltas + assistant. The
    ; assistant copy must not duplicate anything.
    ACL_logContent = nil ACL_responseBuf = ""
    ACL_streamingMsgId = nil ACL_streamedMsgLen = nil
    ACL_processStreamLine(strcat(
      "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_start\","
      "\"message\":{\"id\":\"msg_full\"}}}"))
    ACL_processStreamLine(strcat(
      "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\","
      "\"index\":0,\"delta\":{\"type\":\"text_delta\","
      "\"text\":\"Hello world!\"}}}"))
    ACL_processStreamLine(strcat(
      "{\"type\":\"assistant\",\"message\":{\"id\":\"msg_full\","
      "\"content\":[{\"type\":\"text\",\"text\":\"Hello world!\"}]}}"))
    ACL_check("dedup full stream: text shown once"
      ACL_logString() "Hello world!")
    ACL_form = savedForm
    ACL_streamedMsgLen = savedLen
    ACL_streamingMsgId = savedId
    ACL_logContent = savedLog
    ACL_responseBuf = savedBuf)

  printf("\n--- IPC ---\n")
  let((proc buf ready)
    buf = ""
    ready = nil
    ; Spawn a simple echo process to verify IPC round-trip. `cat`
    ; doesn't exist on Windows; `more` reads stdin and writes
    ; everything to stdout when stdin isn't a terminal.
    proc = ipcBeginProcess(
      if(ACL_isWindows "cmd /c more" "cat")
      ""
      lambda((id data) buf = strcat(buf data)  ready = t)
      lambda((id data) printf("ipc err: %s\n" data)))
    ipcWaitForProcess(proc)
    ACL_checkTrue("ipc spawn" and(proc ipcIsAliveProcess(proc)))
    ; Write and read back
    ipcWriteProcess(proc "hello\n")
    ; Give dataHandler time to fire (may need a brief pause)
    for(i 1 10 unless(ready ipcSleep(1)))
    ACL_checkTrue("ipc echo"
      ; cmd /c more on Windows tacks a CR on; cat doesn't.
      or(buf == "hello\n" buf == "hello\r\n"))
    ipcKillProcess(proc))

  printf("\n--- Claude Process ---\n")
  let(((claudeExists errset(system(
          if(ACL_isWindows "where claude >NUL 2>&1"
            "env -u LD_LIBRARY_PATH which claude > /dev/null 2>&1")))))
    if(and(claudeExists car(claudeExists) == 0) then
      ACL_streamErrorCount = 0
      ACL_startClaude()
      ACL_checkTrue("claude start" and(ACL_claude ipcIsAliveProcess(ACL_claude)))
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
      ; SKILL execution round-trip test: stream tool_use -> handler
      ; -> deferred drain -> .out file -> MCP server -> claude.
      printf("  Testing SKILL execution round-trip...\n")
      ACL_responseBuf = ""
      ACL_gotText = nil
      ACL_sendMessage("Execute this SKILL expression using the allegro_execute tool and report the result: (plus 40 2)")
      for(i 1 180
        unless(ACL_gotText
          ACL_mcpDrainPending()
          ipcSleep(1)))
      ACL_check("skill exec response" ACL_gotText t)
      ; Inspect actual artifacts: each cmd_<N>.il should have a
      ; matching cmd_<N>.out containing "42".
      let(((outContent "")
           (foundExec nil))
        for(i 1 30
          unless(foundExec
            foreach(f ACL_listDirFiles(ACL_sessionLogDir)
              when(pcreMatchp(ACL_cmdSeqFileRe f)
                let(((outPath strcat(ACL_sessionLogDir
                                     substring(f 1 (strlen(f) - 2)) "out")))
                  when(isFile(outPath)
                    foundExec = t
                    outContent = strcat(outContent ACL_readFile(outPath))))))
            unless(foundExec ipcSleep(1))))
        unless(foundExec
          printf("    sessionLogDir=%L isDir=%L files=%L\n"
            ACL_sessionLogDir
            isDir(ACL_sessionLogDir)
            ACL_listDirFiles(ACL_sessionLogDir)))
        ACL_check("mcp tool was called" foundExec t)
        ACL_checkTrue("mcp result contains 42"
          nindex(outContent "42")))
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
