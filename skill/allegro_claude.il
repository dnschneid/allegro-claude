; SPDX-FileCopyrightText: (C) 2026 Meta Platforms Inc.
; SPDX-License-Identifier: Apache-2.0
;
; allegro_claude.il -- SKILL coding-assistant integration
;
; Architecture:
;   A long-lived agent CLI process is spawned via ipcBeginProcess. Two
;   drivers exist:
;     "claude" -- Anthropic claude CLI in stream-json mode, newline-
;                 delimited user/assistant JSON over stdio.
;     "codex"  -- `codex app-server` in JSON-RPC stdio mode.
;   Each driver translates its protocol into the shared event surface
;   (text deltas, tool_use blocks, turn end, errors) that the rest of
;   the SKILL code already consumes.
;   Both drivers share the same allegro MCP server (allegro_mcp.py) for
;   SKILL execution and file IO.

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

; Clean up any existing dialogs (callbacks point at the old code).
when(and(boundp('ACL_sessionPickerForm) ACL_sessionPickerForm)
  axlFormClose(ACL_sessionPickerForm)
  ACL_sessionPickerForm = nil)
when(and(boundp('ACL_form) ACL_form)
  axlFormClose(ACL_form)
  ACL_form = nil)

; Clean up any existing agent process from a previous load
when(and(boundp('ACL_proc) ACL_proc)
  when(ipcIsAliveProcess(ACL_proc)
    printf("ACL: stopping previous agent process\n")
    ; Windows has no POSIX signals, so we have to ipcKillProcess
    if(ACL_isWindows
      ipcKillProcess(ACL_proc)
      ipcSignalProcess(ACL_proc 'TERM)))
  when(ACL_proc ipcWait(ACL_proc))
  ACL_proc = nil)

defvar(ACL_proc nil)               ; the live agent subprocess (any driver)
defvar(ACL_procStopRequested nil)
defvar(ACL_isWindows (getShellEnvVar("OS") == "Windows_NT"))

procedure(ACL_normPath(path)
  if(and(stringp(path) ACL_isWindows)
    pcreReplace(ACL_backslashRe path "/" 0)
    path))

procedure(ACL_ensureTrailingSlash(path)
  ; Append "/" iff path is a non-empty string that doesn't already end
  ; in one. nil/empty pass through unchanged.
  if(and(stringp(path) plusp(strlen(path))
         nequal(substring(path strlen(path) 1) "/"))
    strcat(path "/")
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
    when(ACL_nonEmpty(v) ACL_ensureTrailingSlash(ACL_normPath(v)))))

procedure(ACL_pcbenvDir()
  ; The user's pcbenv: allegro_pcbenv if set, otherwise $HOME/pcbenv
  ; (or $USERPROFILE/pcbenv on Windows).
  or(ACL_axlGetPath("allegro_pcbenv")
     strcat(or(getShellEnvVar("HOME")
               getShellEnvVar("USERPROFILE")) "/pcbenv")))

; defvar in SKILL is an unconditional assign (unlike Common Lisp's);
; ACL_defOpt preserves a value the user set before loading us. Guard
; the macro install too so dev reloads don't trip the "redefined"
; warning.
unless(getd('ACL_defOpt)
  defmacro(ACL_defOpt (var val)
    `unless(boundp(',var) ,var = ,val)))

ACL_defOpt(ACL_fast nil)                ; set to t to skip preloading Allegro docs
ACL_defOpt(ACL_claudeArgs "")            ; extra flags appended to claude CLI invocation
ACL_defOpt(ACL_codexArgs "")             ; extra flags appended to codex CLI invocation
ACL_defOpt(ACL_extraPromptFiles nil)     ; list of paths appended to the system prompt (set in site/user init)
ACL_defOpt(ACL_extraModels "")           ; JSON object of additional model entries (set in site/user init)
ACL_defOpt(ACL_useBuiltinModels 'last)   ; 'last: built-ins after user entries; t: before; nil: omit entirely.
ACL_defOpt(ACL_enableRawLog nil)       ; helps with debugging streams

; ---- Model registry ----
;
; A JSON object keyed by short slug id (stable; persisted in
; settings/sessions; safe to use as a filesystem name). Each value
; is an object with keys:
;   label    -- user-facing display name (free-form string).
;   driver   -- "claude" or "codex".
;   model    -- driver-specific model identifier.
;   context  -- context window in tokens; gates the ~1.5MB doc cache.
;   fallback -- (optional) id of another entry to swap to on a
;               matching ACL_fallbackTriggers error.
;   effort   -- (optional) reasoning effort. Mapped per-driver:
;               claude -> `--effort <value>`,
;               codex  -> `-c model_reasoning_effort=<value>`.
;   args     -- (optional) extra CLI args appended for this entry;
;               the slot for per-model flags a wrapper needs
;               (e.g. `--with-proxy URL`).
;
; The parser accepts `'` in place of `"` so the embedded SKILL string
; literal stays readable; literal `"` quotes also work.
;
; ACL_modelsJson is the built-in list. ACL_extraModels (a JSON object
; string) is merged with it at lookup time; sites set it via their
; ilinit to expose private models. An extra entry whose key matches a
; built-in always replaces the built-in (regardless of order).
; ACL_useBuiltinModels controls placement:
;   'last (default) -- user entries first, built-ins after.
;   t               -- built-ins first, user entries after.
;   nil             -- omit built-ins entirely.
defvar(ACL_modelsJson "{
  'opus-1m':         {'label':'Claude Opus (1M)',         'driver':'claude','model':'opus[1m]',
                      'context':1000000, 'effort':'max', 'fallback':'opus-4-7-1m'},
  'opus-4-7-1m':     {'label':'Claude Opus 4.7 (1M)',     'driver':'claude','model':'claude-opus-4-7[1m]',
                      'context':1000000, 'effort':'max'},
  'opus-4-7-200k':   {'label':'Claude Opus 4.7 (200K)',   'driver':'claude','model':'claude-opus-4-7',
                      'context':200000,  'effort':'max'},
  'sonnet-4-6-1m':   {'label':'Claude Sonnet 4.6 (1M)',   'driver':'claude','model':'claude-sonnet-4-6[1m]',
                      'context':1000000, 'effort':'max'},
  'sonnet-4-6-200k': {'label':'Claude Sonnet 4.6 (200K)', 'driver':'claude','model':'claude-sonnet-4-6',
                      'context':200000,  'effort':'max'},
  'gpt-5-5':         {'label':'Codex GPT-5.5',            'driver':'codex', 'model':'gpt-5.5',
                      'context':256000,  'effort':'xhigh'}
}")

defvar(ACL_modelsApostropheRe pcreCompile("'"))

procedure(ACL_parseModelsJson(text)
  ; Parse a JSON object of model entries. Allows `'` as sugar for
  ; `"` so the embedded literal stays readable (none of our model
  ; field values legitimately contain apostrophes). The outer `{}`
  ; is optional so site ilinits can compose entries with `strcat`
  ; without each fragment having to balance braces. Returns the
  ; parsed alist (((id entry) ...)), or nil with a warning on
  ; malformed input.
  when(ACL_nonEmpty(text)
    letseq(((trimmed pcreReplace(pcreCompile("^\\s+|\\s+$") text "" 0))
            (wrapped if(or(pcreMatchp("^\\{" trimmed)
                           pcreMatchp("^\\[" trimmed))
                      trimmed
                      strcat("{" trimmed "}")))
            (cooked pcreReplace(ACL_modelsApostropheRe wrapped "\"" 0))
            (parsed car(errset(ACL_jParse(cooked)))))
      cond(
        (null(parsed)
          printf("*Warning* ACL: failed to parse models JSON\n")
          nil)
        (null(ACL_jsonIsAlist(car(parsed)))
          printf("*Warning* ACL: models JSON must be an object keyed by id\n")
          nil)
        (t car(parsed))))))

procedure(ACL_models()
  ; Live registry merged from ACL_modelsJson and ACL_extraModels.
  ; User entries always win on id collision; ACL_useBuiltinModels
  ; chooses where the surviving built-ins land ('last/t/nil).
  letseq(((user ACL_parseModelsJson(ACL_extraModels))
          (builtins when(ACL_useBuiltinModels
                         ACL_parseModelsJson(ACL_modelsJson)))
          (kept setof(b builtins null(assoc(car(b) user)))))
    cond(
      (equal(ACL_useBuiltinModels 'last)  append(user kept))
      (null(ACL_useBuiltinModels)         user)
      (t                                  append(kept user)))))

; The model entry selected for the running session. The car is the
; id (slug); the cadr is the field object. Set by ACL_resolveModel
; before any driver call.
defvar(ACL_activeEntry nil)

procedure(ACL_modelById(id)
  ; Look up a registry entry by its id slug. Returns the full alist
  ; entry `(id fields)` or nil on miss.
  when(stringp(id) assoc(id ACL_models())))

procedure(ACL_defaultModelEntry() car(ACL_models()))

procedure(ACL_resolveModel(id)
  ; Return the registry entry matching id, defaulting to the first
  ; entry. Warns when id was supplied but didn't match.
  let(((entry and(ACL_nonEmpty(id) ACL_modelById(id))))
    cond(
      (entry entry)
      (t
        when(ACL_nonEmpty(id)
          printf("*Warning* ACL: unknown model %L; falling back to %L\n"
            id car(ACL_defaultModelEntry())))
        ACL_defaultModelEntry()))))

procedure(ACL_entryField(entry key)
  ; Field lookup on an entry's value object (the cdr's first item is
  ; the field alist).
  when(entry ACL_jGet(cadr(entry) key)))

procedure(ACL_entryLabel(entry)
  ; Falls back to the id when no `label` is supplied.
  or(ACL_entryField(entry "label") car(entry)))

procedure(ACL_activeId()
  car(or(ACL_activeEntry ACL_defaultModelEntry())))

procedure(ACL_activeDriver()
  ACL_entryField(or(ACL_activeEntry ACL_defaultModelEntry()) "driver"))

procedure(ACL_activeModelId()
  ACL_entryField(or(ACL_activeEntry ACL_defaultModelEntry()) "model"))

procedure(ACL_activeLabel()
  ACL_entryLabel(or(ACL_activeEntry ACL_defaultModelEntry())))

procedure(ACL_activeContext()
  ; Context window in tokens for the active model; nil if unset.
  ACL_entryField(or(ACL_activeEntry ACL_defaultModelEntry()) "context"))

ACL_defOpt(ACL_docCacheRatio 1.8)
; Acceptance ratio: inline the cache when cache_bytes / context_tokens
; <= ratio, otherwise fall back to a system-prompt reference and let
; the agent grep the file via $MCP_read_file. Lower for tighter
; inlining. plans/minimal-doc-cache.md sketches a trim that would
; let small-context models keep some inline domain guidance.

procedure(ACL_docCacheFits(@optional (entry ACL_activeEntry)
                                     (cacheBytes nil))
  ; t when the doc cache would fit alongside the rest of the system
  ; prompt and a real conversation. Missing context counts as "unknown,
  ; assume yes" so legacy entries don't silently lose the cache;
  ; missing/empty cache file counts as "doesn't apply, return t".
  ; cacheBytes overrides the auto-detected file size (tests use this).
  letseq(((ctx ACL_entryField(or(entry ACL_defaultModelEntry()) "context"))
          (sz or(cacheBytes
                 let(((path ACL_findOrPlanDocs()))
                   when(and(path isFile(path)) fileLength(path))))))
    or(null(ctx) null(sz)
       (sz / float(ctx)) <= ACL_docCacheRatio)))

; Each entry: (label predicate(errStatus resText) -> t/nil). First match wins.
defvar(ACL_fallbackTriggers
  list(
    list("API rejected role:\"system\" in messages[]"
         'ACL_isRoleSystemError)))
defvar(ACL_form nil)
defvar(ACL_statusText "")            ; mirrors what setStatus pushed to the form
defvar(ACL_sessionPickerForm nil)    ; transient session-picker dialog
defvar(ACL_sessionPickerSids nil)    ; sids in listbox order; index 0
                                     ; (the "+ New session" pseudo-row)
                                     ; is held as nil
defvar(ACL_sessionPickerModelIds nil) ; model ids in modelchoice listbox order
defvar(ACL_sessionPickerSelIdx 0)    ; last selection index reported by
                                     ; the listbox callback. Tracked so
                                     ; Rename/Delete know which row the
                                     ; user had highlighted at click time
                                     ; (the button click is its own
                                     ; field-change event and doesn't
                                     ; carry the list's curValueInt).
defvar(ACL_logContent nil)          ; accumulated log chunks (newest first)
defvar(ACL_logUnflushed "")         ; log text to be flushed once ACL_sessionLogDir gets set
defvar(ACL_logTruncLimit 12500)    ; max chars shown in form field
defvar(ACL_statusTruncLimit 200)   ; max chars for the status bar (sanity cap; STRFILLIN scrolls)
defvar(ACL_logLineLimit 50)        ; max lines shown in form field
defvar(ACL_logCodeLimit 250)       ; max chars for each code preview
defvar(ACL_maxReadBytes 20480)     ; allegro_read_file hard cap per call
defvar(ACL_sessionId nil)
defvar(ACL_sessionSaved nil)       ; true once the session entry has been written
defvar(ACL_sessionUserMsgSeen nil) ; true once a real (non-synthetic) user msg was sent
defvar(ACL_mode "quiet")
defvar(ACL_lineBuf "")
defvar(ACL_streamErrorCount 0)   ; increments when the driver data handler throws
defvar(ACL_responseBuf "")
defvar(ACL_lastCmdTime 0)
defvar(ACL_recording nil)
defvar(ACL_journalFile nil)
defvar(ACL_gotText nil)          ; set to t when any text arrives
defvar(ACL_runtimeProbe nil)     ; tests poke this with a fresh value the model can only learn via allegro_execute
defvar(ACL_sessionCostUsd 0.0)   ; cumulative within an agent run; cleared on (re)start
defvar(ACL_sessionWeightedTokens 0.0) ; weighted token total when cost isn't reported
defvar(ACL_lastContextTokens 0)  ; in+cache_read+cache_creation from latest result event
defvar(ACL_lastContextWindow nil) ; modelUsage[*].contextWindow from latest result event
defvar(ACL_streamingMsgId nil)    ; message ID currently being streamed
defvar(ACL_streamedMsgLen nil)    ; alist of (msgId . textLen) for streamed messages
defvar(ACL_hadToolUse nil)       ; true if tool_use occurred since last text block
defvar(ACL_resumeIsFork nil)      ; t if the current launch was a fork (skip session migrate)
defvar(ACL_pendingForkName nil)   ; parent name to inherit on first-text save
defvar(ACL_busy nil)              ; t between turn start and turn end
defvar(ACL_pendingChatQueue nil)  ; user msgs shown as "Queued:" until flush
defvar(ACL_sessionTag nil)        ; per-launch handshake tag exported to the agent/MCP
defvar(ACL_sessionTagWritten nil) ; t once the tag has been stamped into the session dir
defvar(ACL_lastSent nil)          ; (text isSynthetic noQuery) of the most recent send; replayed on model fallback
defvar(ACL_fallbackRetryPending nil) ; non-nil = the trigger label that fired; data handler runs the relaunch after returning

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
defvar(ACL_trailingSlashesRe pcreCompile("/+$"))
defvar(ACL_lastPathCompRe    pcreCompile("[^/\\\\]+$"))
defvar(ACL_basenameStripRe   pcreCompile("^.*[/\\\\]"))
defvar(ACL_lastPathSegRe     pcreCompile("/[^/]+$"))
defvar(ACL_doubleQuoteRe     pcreCompile("\""))
defvar(ACL_singleQuoteRe     pcreCompile("'"))
; Windows arg escape (MSVC CRT rules): backslashes before " must be
; doubled, the " itself becomes \"; trailing backslashes (right before
; the closing wrapper ") must also be doubled.
defvar(ACL_winBsBeforeQuoteRe pcreCompile("(\\\\*)\""))
defvar(ACL_winTrailingBsRe    pcreCompile("(\\\\+)$"))

; Stream / journal / status processing.
defvar(ACL_cmdSeqFileRe      pcreCompile("^cmd_(\\d+)\\.il$"))
defvar(ACL_mcpToolPrefixRe   pcreCompile("^.*__"))
defvar(ACL_mcpAllegroToolRe  pcreCompile("^mcp__allegro__allegro_"))
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
; Tool prefix placeholder: PROMPT.md uses `$MCP_execute` and friends;
; each driver substitutes its own MCP-tool prefix at build time.
defvar(ACL_promptToolPrefixRe pcreCompile("[$]MCP_"))

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

; ACL_scriptDir is the directory containing this and related sources.
; The user can pre-set ACL_scriptDir before loading to set precedence.
; Regardless, The first directory that has the required files is selected.
procedure(ACL_validScriptDir(d)
  when(stringp(d)
    let(((nd ACL_ensureTrailingSlash(ACL_normPath(d))))
      when(isFile(strcat(nd "allegro_mcp.py")) nd))))
defvar(ACL_scriptDir nil)
ACL_scriptDir = ACL_validScriptDir(car(exists(d
  append(list(ACL_scriptDir
              getShellEnvVar("ACL_SCRIPT_DIR")
              car(errset(pcreReplace(ACL_lastPathCompRe
                simplifyFilename(get_filename(piport)) "" 0))))
         getSkillPath())
  ACL_validScriptDir(d))))
unless(ACL_scriptDir
  printf(strcat(
    "*Warning* ACL: could not locate script directory "
    "(no allegro_mcp.py found via ACL_scriptDir, ACL_SCRIPT_DIR env var, "
    "piport parent directory, or getSkillPath). "
    "Set ACL_scriptDir explicitly before loading allegro_claude.il -- e.g.:\n"
    "  ACL_scriptDir = \"/path/to/allegro-claude/skill/\"\n"
    "  load(strcat(ACL_scriptDir \"allegro_claude.il\"))\n")))

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

procedure(ACL_appendChat(text @key (toFile t))
  ACL_logWrite(strcat(text "\n") ?toFile toFile))

procedure(ACL_logFilePath()
  ; The on-disk mirror of ACL_logContent. nil if we don't have a session dir yet
  when(and(ACL_sessionLogDir ACL_sessionLogDir != ACL_logDir)
    strcat(ACL_sessionLogDir "log.txt")))

procedure(ACL_logFileAppend(text)
  ; Mirror a logWrite to disk so Full Log and restore both stay fast.
  ; Buffer until the per-session dir exists.
  ACL_logUnflushed = strcat(ACL_logUnflushed text)
  letseq(((path ACL_logFilePath())
          (fp when(path outfile(path "a"))))
    when(fp
      fprintf(fp "%s" ACL_logUnflushed)
      close(fp)
      ACL_logUnflushed = "")))

procedure(ACL_logEndsWithNL()
  ; True if the most recent log entry is a complete line. nil also
  ; means "no entry yet", which counts as a complete-line state for
  ; the purposes of deciding whether to start a new line.
  or(null(ACL_logContent)
     substring(car(ACL_logContent) strlen(car(ACL_logContent)) 1) == "\n"))

procedure(ACL_logWrite(text @key (toFile t))
  ; Stores one line per list entry. Partial lines appended via rplaca.
  ; Suppresses consecutive blank lines. Mirrors accepted text to the
  ; on-disk log file (buffered before sessionLogDir is known) unless
  ; toFile is false -- used by restore to repopulate state from a file
  ; we just read, without re-appending its content to itself.
  let((rest nlPos pre)
    rest = ACL_recode(text)
    while(and(rest strlen(rest) > 0)
      nlPos = nindex(rest "\n")
      if(nlPos then
        pre = substring(rest 1 nlPos)
        cond(
          (null(ACL_logEndsWithNL())
            ; Continue an open partial line.
            rplaca(ACL_logContent strcat(car(ACL_logContent) pre))
            when(toFile ACL_logFileAppend(pre)))
          (or(pre != "\n" car(ACL_logContent) != "\n")
            ; New line; suppress consecutive blanks.
            ACL_logContent = cons(pre ACL_logContent)
            when(toFile ACL_logFileAppend(pre))))
        rest = substring(rest (nlPos + 1))
      else
        if(null(ACL_logEndsWithNL()) then
          rplaca(ACL_logContent strcat(car(ACL_logContent) rest))
        else
          ACL_logContent = cons(rest ACL_logContent))
        when(toFile ACL_logFileAppend(rest))
        rest = nil)))
  when(ACL_form
    axlFormSetField(ACL_form "chatlog" ACL_logTail(ACL_logLineLimit))))

procedure(ACL_logString()
  buildString(reverse(ACL_logContent) ""))

procedure(ACL_logTail(n)
  ; Reserve slots for the queue rows (one each, plus a blank separator)
  ; so queued entries stay visible even when the log is long.
  prog((lines count result chunk reserved budget)
    reserved = if(ACL_pendingChatQueue (1 + length(ACL_pendingChatQueue)) 0)
    budget = max(1 (n - reserved))
    lines = ACL_logContent
    count = 0
    result = ""
    while(and(lines count < budget)
      chunk = car(lines)
      when(strlen(result) + strlen(chunk) > ACL_logTruncLimit
        return(ACL_withPendingChat(strcat("...\n" result))))
      result = strcat(chunk result)
      when(substring(chunk strlen(chunk) 1) == "\n"
        count++)
      lines = cdr(lines))
    return(ACL_withPendingChat(
      if(lines strcat("...\n" result) result)))))

procedure(ACL_withPendingChat(tail)
  ; Append queued user msgs (panel-only, not on disk) to the tail.
  ; Leading "\n\n" separates from prior log; subsequent entries get
  ; one newline so the queue reads as a tight block.
  if(ACL_pendingChatQueue
    strcat(tail "\n\n"
      buildString(mapcar(lambda((s) strcat("Queued: " s)) ACL_pendingChatQueue)
                  "\n") "\n")
    tail))

procedure(ACL_enqueueChatLine(text)
  ACL_pendingChatQueue = append1(ACL_pendingChatQueue text)
  ; If claude isn't busy, the message lands directly in the log; the
  ; "Queued:" decoration only appears while it's actually waiting.
  if(ACL_busy
    when(ACL_form
      axlFormSetField(ACL_form "chatlog" ACL_logTail(ACL_logLineLimit)))
    ACL_flushPendingChat()))

procedure(ACL_flushPendingChat(@key (one nil))
  ; Move queued lines into log.txt as "You: ...". With ?one t, only
  ; the oldest entry flushes -- matches claude's behavior of consuming
  ; one queued message per turn-end (vs. all at tool-end).
  letseq(((all ACL_pendingChatQueue)
          (q if(one
                when(all list(car(all)))
                all))
          (remaining if(one cdr(all) nil)))
    ACL_pendingChatQueue = remaining
    foreach(text q
      ACL_appendChat(sprintf(nil "\n\nYou: %s" text)))))

procedure(ACL_dropPendingChat()
  ACL_pendingChatQueue = nil)

procedure(ACL_logReset()
  ; Drop the in-memory log + clear the chat panel.
  ACL_logContent = nil
  ACL_logUnflushed = ""
  when(ACL_form axlFormSetField(ACL_form "chatlog" "")))

procedure(ACL_logLoadFromFile()
  ; Repopulate ACL_logContent from the persisted log.txt so a resumed
  ; session shows its prior chat history. Terminate any partial messages
  ; that may have been interrupted in the previous session.
  letseq(((path ACL_logFilePath())
          (text when(and(path isFile(path)) ACL_readFile(path))))
    when(and(text strlen(text) > 0)
      ACL_logWrite(text ?toFile nil)
      when(and(ACL_logContent not(ACL_logEndsWithNL()))
        rplaca(ACL_logContent strcat(car(ACL_logContent) "\n"))))))

procedure(ACL_showFullLog()
  ; The log file is written incrementally as messages stream in, so we
  ; just open it. The button is disabled (see ACL_refreshLogButtons)
  ; until ACL_sessionLogDir is set, so we don't need a fallback.
  let(((path ACL_logFilePath()))
    when(and(path isFile(path))
      axlUIViewFileCreate(path "Claude - Full Log" nil '(50 120) nil ACL_form))))

procedure(ACL_refreshLogButtons()
  ; Full Log / Files... both depend on ACL_sessionLogDir being set to a
  ; real per-session path. Toggle their editability so the user can't
  ; click into an inert state.
  let(((haveDir ACL_logFilePath()))
    when(ACL_form
      axlFormSetFieldEditable(ACL_form "fulllog" haveDir)
      axlFormSetFieldEditable(ACL_form "files" haveDir))))

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
  when(or(pcreMatchp(ACL_manualStatusRe text)
          ACL_mode != "manual"
          null(ACL_mcpPending))
    ACL_statusText = text
    when(ACL_form
      axlFormSetField(ACL_form "statuslabel"
        if(strlen(text) > ACL_statusTruncLimit
          strcat(substring(text 1 ACL_statusTruncLimit-3) "...")
          text)))))

procedure(ACL_toolPrefix(@optional (driver ACL_activeDriver()))
  ; PROMPT.md uses `$MCP_` placeholders; the prefix differs per driver
  ; because claude exposes MCP tools as `mcp__<server>__<tool>` while
  ; codex hands the model the bare tool name.
  cond(
    (driver == "claude" "mcp__allegro__allegro_")
    (driver == "codex"  "allegro_")
    (t                  "allegro_")))

procedure(ACL_replacePaths(text)
  ; Replaces $PATHs with the actual paths plus $MCP_ with the current
  ; driver's MCP tool naming convention.
  text = pcreReplace(ACL_promptNotesRe text ACL_notesDir 0)
  text = pcreReplace(ACL_promptInstallRe text
    ACL_normPath(axlGetVariable("allegro_install_root")) 0)
  text = pcreReplace(ACL_promptSiteRe text
    ACL_normPath(or(ACL_axlGetPath("allegro_site") "")) 0)
  text = pcreReplace(ACL_promptPcbenvRe text
    ACL_normPath(ACL_pcbenvDir()) 0)
  pcreReplace(ACL_promptToolPrefixRe text ACL_toolPrefix() 0))

procedure(ACL_buildSystemPrompt()
  ; PROMPT.md + LESSONS.md (+ per-site companions + windows ascii note
  ; + offline-doc-cache reference when the cache won't be inlined),
  ; joined with blank lines and run through ACL_replacePaths so the
  ; $PATH / $MCP_ placeholders resolve.
  letseq(((paths append(
            list(strcat(ACL_scriptDir "PROMPT.md")
                 strcat(ACL_scriptDir "LESSONS.md")
                 strcat(ACL_notesDir  "LESSONS.md"))
            setof(p ACL_extraPromptFiles stringp(p))))
          (chunks setof(s mapcar('ACL_readFile paths) (and s (nequal s ""))))
          (asciiNote when(ACL_isWindows
            strcat("## Output Encoding\n\n"
                   "**Only use ASCII characters in responses.** Do not use Unicode "
                   "characters such as curly quotes, em dashes, bullets, or other "
                   "non-ASCII glyphs. Use straight quotes, `--`, and `*` instead.")))
          (docRef unless(ACL_shouldLoadDocCache()
            ACL_docCacheReference())))
    when(asciiNote chunks = append1(chunks asciiNote))
    when(docRef chunks = append1(chunks docRef))
    ACL_replacePaths(buildString(chunks "\n\n"))))

procedure(ACL_shellQuote(s)
  ; Quote one argv value for ipcBeginProcess. Both platforms have a
  ; two-pass eat (ipcBeginProcess + the real shell), so the escape
  ; goes through twice.
  ; Linux: sh single-quote with '\'' escape, then pre-escape `\` and
  ; `"` so pass-1 emits exactly the sh form we wanted.
  ; Windows: per-arg MSVC-CRT escape (doubled BS before `"`, doubled
  ; trailing BS), applied twice, wrapped in `\"...\"` (escaped quotes
  ; that survive ipcBeginProcess's bare-`"` strip). Callers must
  ; wrap the assembled command in `cmd /c "..."` (see ACL_wrapCmd)
  ; so ipcBeginProcess treats it as one token.
  if(ACL_isWindows
    let(((esc s))
      for(i 1 2
        esc = pcreReplace(ACL_winBsBeforeQuoteRe esc "\\1\\1\\\\\"" 0)
        esc = pcreReplace(ACL_winTrailingBsRe esc "\\1\\1" 0))
      strcat("\\\"" esc "\\\""))
    let(((sh strcat("'" pcreReplace(ACL_singleQuoteRe s "'\\\\''" 0) "'")))
      sh = pcreReplace(ACL_backslashRe sh "\\\\\\\\" 0)
      pcreReplace(ACL_doubleQuoteRe sh "\\\\\"" 0))))

procedure(ACL_wrapCmd(cmd)
  ; Finalize a command string built from ACL_shellQuote'd tokens for
  ; handoff to ipcBeginProcess. Linux is a no-op (sh tokenizes the
  ; whole string and each `'...'` arg survives). Windows wraps in
  ; `cmd /c "..."` so the outer call sees one token and inner `"`
  ; chars are preserved through CreateProcess.
  if(ACL_isWindows
    sprintf(nil "cmd /c \"%s\"" cmd)
    cmd))

procedure(ACL_formIsAlive(formHandle)
  ; True if formHandle can be redisplayed; nil if stale (eg after a
  ; script reload). errset traps the failed redisplay.
  and(formHandle errset(axlFormDisplay(formHandle))))

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
       list("claudeArgs" or(ACL_claudeArgs ""))
       list("codexArgs" or(ACL_codexArgs ""))
       list("model" or(ACL_activeId() ""))))

procedure(ACL_applySettings(settings)
  let(((val ACL_jGet(settings "mode")))
    when(val
      ACL_mode = val
      when(ACL_form axlFormSetField(ACL_form "mode" val))))
  ACL_fast = ACL_jGet(settings "fast")
  let(((ca ACL_jGet(settings "claudeArgs")))
    when(stringp(ca) ACL_claudeArgs = ca))
  let(((ca ACL_jGet(settings "codexArgs")))
    when(stringp(ca) ACL_codexArgs = ca))
  let(((m ACL_jGet(settings "model")))
    when(stringp(m)
      ACL_activeEntry = ACL_resolveModel(m))))

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

procedure(ACL_dropStaleSession(sid label)
  ; Forget a session id the live agent has refused. `label` names the
  ; driver-specific error for the chat surface so the user understands
  ; why the restore quietly turned into a new session. Returns nil.
  when(ACL_nonEmpty(sid)
    printf("ACL: removing stale session id %s from sessions.json\n" sid)
    ACL_removeSession(sid)
    ACL_appendChat(sprintf(nil
      "\n[%s: No conversation found with session ID: %s]\n"
      or(label "agent") sid))
    when(ACL_sessionId == sid
      ACL_sessionId = nil)
    nil))

procedure(ACL_handleStaleSession(stderrLine)
  ; Called from claude's stderr handler. Match the well-known
  ; "No conversation found ..." line, then dispatch to the shared
  ; cleanup so the next ACL_ensureAgent starts fresh rather than
  ; looping on the bad id.
  when(pcreMatchp(ACL_noSessionRe stderrLine)
    ACL_dropStaleSession(pcreSubstitute(ACL_noSessionRe "\\1") "claude")))

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

procedure(ACL_sessionName(info)
  ; nil for sessions saved before the "name" field existed.
  when(info ACL_jGet(info "name")))

procedure(ACL_sessionModel(info)
  ; Returns the model id stored on the session, or the registry
  ; default for legacy entries that predate the field.
  or(when(info ACL_jGet(info "model"))
     car(ACL_defaultModelEntry())))

procedure(ACL_setSessionName(sid newName)
  ; Pass nil or "" to clear the name. Missing sid is a no-op.
  letseq(((sessions ACL_loadSessions())
          (entry assoc(sid sessions))
          (info when(entry cadr(entry)))
          (clean when(and(stringp(newName) strlen(newName) > 0) newName)))
    when(entry
      info = setof(p info car(p) != "name")
      when(clean info = append(info list(list("name" clean))))
      rplaca(cdr(entry) info)
      ACL_saveSessions(sessions))))

procedure(ACL_sessionLabel(sid info @key (currentSid nil))
  ; Picker row text: name (or UUID prefix), board basename, model, time,
  ; and a "(current)" suffix when this entry is the running session.
  ; Models no longer in the registry get a `(!)` suffix so users see
  ; the row will refuse to open.
  letseq(((name ACL_sessionName(info))
          (label or(name
                    when(and(stringp(sid) strlen(sid) >= 8)
                      strcat(substring(sid 1 8) "..."))
                    or(sid "?")))
          (board ACL_basename(or(ACL_jGet(info "board") "?")))
          (modelId ACL_sessionModel(info))
          (entry ACL_modelById(modelId))
          (model if(entry ACL_entryLabel(entry)
                   strcat(modelId " (!)")))
          (rawTime ACL_jGet(info "time"))
          (time if(and(rawTime numberp(atoi(rawTime)))
                   timeToString(atoi(rawTime))
                   "?"))
          (suffix if(sid == currentSid "  (current)" "")))
    sprintf(nil "%s  [%s]  [%s]  (%s)%s" label board model time suffix)))

procedure(ACL_deleteSessionFiles(sid)
  ; Caller is responsible for ACL_removeSession on sessions.json.
  ; SKILL's deleteDir refuses non-empty dirs, so unlink files first.
  ; Session dirs are flat -- no recursion needed.
  let(((dir strcat(ACL_logDir sid "/")))
    when(isDir(dir)
      foreach(f ACL_listDirFiles(dir)
        deleteFile(strcat(dir f)))
      deleteDir(dir))))

procedure(ACL_maybeSaveSession()
  ; First-text save, gated on the user actually having sent a non-
  ; synthetic message. The synthetic boot-up ping is NOT enough -- it
  ; would otherwise clutter sessions.json with empty entries. Once
  ; saved, this is a no-op (ACL_sessionSaved == t).
  when(and(null(ACL_sessionSaved) ACL_sessionUserMsgSeen
           ACL_sessionId axlGetDrawingName())
    letseq(((base list(
              list("board" ACL_normPath(axlGetDrawingName()))
              list("time" sprintf(nil "%d"
                stringToTime(getCurrentTime())))
              list("model" or(ACL_activeId() ""))))
            (info if(ACL_pendingForkName
                     append(base list(list("name"
                       ACL_pendingForkName)))
                     base)))
      ACL_addSession(ACL_sessionId info))
    ACL_pendingForkName = nil
    ACL_sessionSaved = t
    when(ACL_sessionPickerForm
      ACL_renderSessionPicker(?selectIdx ACL_sessionPickerSelIdx))
    ; Tell the agent where its prior commands live so it can grep them
    ; instead of re-running discovery.
    ACL_sendMessage(sprintf(nil
      "[Session log dir: %s -- holds your prior cmd_<n>.il/.out (allegro_execute code/output) from this session (reference them as appropriate), and is your scratch space for any reports, generated scripts, or working files the user might want to inspect via the Files... button.]"
      ACL_sessionLogDir)
      ?isSynthetic t ?noQuery t)))

; ============================================================
; 6. Agent Process Management
; ============================================================

procedure(ACL_makeSessionTag()
  ; Per-launch handshake tag exported via ACL_SESSION_TAG so the MCP
  ; server can find this session's log dir via the acl_tag file.
  ; Epoch seconds suffice since ACL_stopAgent waits for the prior
  ; process to exit before the next launch.
  sprintf(nil "acl-%d" stringToTime(getCurrentTime())))

procedure(ACL_writeSessionTag()
  ; Idempotent per launch; skipped until the init handler assigns
  ; a real per-session dir.
  when(and(ACL_sessionTag ACL_sessionLogDir
           ACL_sessionLogDir != ACL_logDir
           null(ACL_sessionTagWritten))
    ACL_writeFileAtomic(strcat(ACL_sessionLogDir "acl_tag") ACL_sessionTag)
    ACL_sessionTagWritten = t))

procedure(ACL_writeMcpConfig()
  ; Stage the MCP server script alongside its config so paths are stable
  ; regardless of where the agent process treats as its sandbox root.
  ; Returns the absolute path of the config file.
  letseq(((mcpConfigFile ACL_normPath(strcat(ACL_homeDir "mcp_config.json")))
          (mcpScript ACL_normPath(strcat(ACL_homeDir "allegro_mcp.py"))))
    ACL_copyFile(strcat(ACL_scriptDir "allegro_mcp.py") mcpScript)
    let(((fp outfile(mcpConfigFile)))
      when(fp
        fprintf(fp "%s" ACL_jsonObj(list("mcpServers"
          list(list("allegro" list(
            list("command" if(ACL_isWindows "python" "python3"))
            list("args" list(mcpScript))))))))
        close(fp)))
    mcpConfigFile))

procedure(ACL_shouldLoadDocCache()
  ; Inline the full cache only when fast mode is off AND the cache
  ; fits the active model's window. If it doesn't fit, the system
  ; prompt instead carries a pointer to the cache file -- see
  ; ACL_docCacheReference.
  and(null(ACL_fast) ACL_docCacheFits()))

procedure(ACL_docCacheReference()
  ; System-prompt snippet inserted when the doc cache exists but
  ; doesn't fit inline. Doc reading is read-only, so the agent's
  ; built-in file/shell tools are fine; only steer to $MCP_execute
  ; when the result needs to land in an Allegro SKILL expression.
  let(((path ACL_findOrPlanDocs()))
    when(and(path isFile(path))
      strcat("## Allegro SKILL documentation cache (offline)\n\n"
        "A condensed Allegro SKILL reference is on disk at\n"
        "  " path "\n\n"
        "It does not fit in this model's context, but it IS the "
        "authoritative offline reference for axl* functions, "
        "object property tables, and shell-command syntax. **Always** "
        "read or grep it with your built-in file/shell tools "
        "before guessing a SKILL signature, trawling the raw HTML "
        "docs, or running speculative tool calls. Use `$MCP_execute` "
        "shell grep when you need the result inside an Allegro SKILL "
        "expression. It is faster, more accurate, and dramatically "
        "cheaper than trial-and-error.\n"))))

procedure(ACL_writeSystemPromptFile(@key (appendDocs t))
  ; Write the assembled system prompt (optionally with the doc cache
  ; inlined) to a per-launch file; return its absolute path. The cache
  ; gate lives in ACL_shouldLoadDocCache; this just respects the flag.
  letseq(((promptFile ACL_normPath(strcat(ACL_homeDir "PROMPT.md")))
          (fp outfile(promptFile)))
    when(fp
      fprintf(fp "%s" ACL_buildSystemPrompt())
      when(appendDocs
        let(((doc ACL_findOrPlanDocs()))
          when(and(doc isFile(doc))
            fprintf(fp "\n\n%s" ACL_replacePaths(ACL_readFile(doc))))))
      close(fp))
    promptFile))

procedure(ACL_resetAgentState()
  ACL_mcpPending = nil
  ACL_mcpCmdSeq = 0
  ACL_lineBuf = ""
  ACL_responseBuf = ""
  ACL_sessionCostUsd = 0.0
  ACL_sessionWeightedTokens = 0.0
  ACL_lastContextTokens = 0
  ACL_lastContextWindow = nil
  ACL_streamingMsgId = nil
  ACL_streamedMsgLen = nil
  ACL_busy = nil
  ACL_dropPendingChat()
  let(((fp outfile(strcat(ACL_homeDir "raw.log") "a")))
    when(fp fprintf(fp "\n--- %s ---\n" getCurrentTime()) close(fp)))
  ACL_sessionTag = ACL_makeSessionTag()
  ACL_sessionTagWritten = nil
  setShellEnvVar("ACL_SESSION_TAG" ACL_sessionTag))

procedure(ACL_startAgent(@optional resumeId fork)
  ; Stop any previous process and dispatch to the driver named on the
  ; active model entry. The driver populates ACL_proc and arranges its
  ; own data/exit handlers.
  ACL_stopAgent()
  ACL_createDirP(ACL_homeDir)
  createDir(ACL_notesDir)
  createDir(ACL_logDir)
  ACL_resetAgentState()
  ACL_resumeIsFork = and(resumeId fork t)
  let(((driver ACL_activeDriver()))
    cond(
      (driver == "claude" ACL_claudeDriverStart(resumeId fork))
      (driver == "codex"  ACL_codexDriverStart(resumeId fork))
      (t
        printf("*Error* ACL: unknown driver %L for model %L\n"
          driver ACL_activeId())
        ACL_setStatus("Failed to initialize!"))))
  unless(and(ACL_proc ipcIsAliveProcess(ACL_proc))
    ACL_setStatus("Failed to initialize!")))

procedure(ACL_exitHandler(id status)
  ; Common postFunc registered with ipcBeginProcess by both drivers.
  ; Surfaces unexpected exits in the chat log; quiet on deliberate stop.
  ACL_proc = nil
  ACL_busy = nil
  unless(ACL_procStopRequested
    ACL_setStatus(sprintf(nil "Agent exited (status %L)" status))
    ACL_appendChat(sprintf(nil
      "\n\n[Agent process exited unexpectedly (status %L). Send any message to restart.]"
      status)))
  ACL_flushPendingChat()
  ACL_procStopRequested = nil
  when(ACL_form axlFormSetField(ACL_form "send" "Send")))

procedure(ACL_stopAgent()
  ; Gate stopRequested on having a live process to kill, so a no-op
  ; stopAgent() doesn't silence the next spawn's unexpected exit.
  when(and(ACL_proc ipcIsAliveProcess(ACL_proc))
    ACL_procStopRequested = t
    ACL_setStatus("Saving session...")
    if(ACL_isWindows
      ipcKillProcess(ACL_proc)
      ipcSignalProcess(ACL_proc 'TERM))
    when(ACL_proc ipcWait(ACL_proc))
    ACL_setStatus("Session ended"))
  ACL_proc = nil
  ACL_busy = nil
  ACL_flushPendingChat()
  when(ACL_form axlFormSetField(ACL_form "send" "Send")))

; --- Claude driver ---

procedure(ACL_claudeDriverStart(resumeId fork)
  let((cmd promptFile installRoot siteDir pcbenvDir projectDir args
       mcpConfigFile modelId effort)
    mcpConfigFile = ACL_writeMcpConfig()
    promptFile = ACL_writeSystemPromptFile(?appendDocs ACL_shouldLoadDocCache())
    installRoot = ACL_axlGetPath("allegro_install_root")
    siteDir = ACL_axlGetPath("allegro_site")
    pcbenvDir = ACL_pcbenvDir()
    projectDir = ACL_normPath(pcreReplace(ACL_lastPathCompRe
      simplifyFilename(axlGetDrawingName()) "" 0))
    modelId = ACL_activeModelId()
    effort = ACL_entryField(ACL_activeEntry "effort")
    args = list(
      if(ACL_isWindows "claude -p" "env -u LD_LIBRARY_PATH claude -p")
      "--verbose"
      "--input-format stream-json"
      "--output-format stream-json"
      "--include-partial-messages"
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
      "--model" modelId)
    when(ACL_nonEmpty(effort)
      args = append(args list("--effort" ACL_shellQuote(effort))))
    when(resumeId
      args = append1(args "--resume")
      args = append1(args resumeId)
      when(fork args = append1(args "--fork-session")))
    cmd = buildString(args " ")
    let(((entryArgs ACL_entryField(ACL_activeEntry "args")))
      when(ACL_nonEmpty(entryArgs)
        cmd = strcat(cmd " " entryArgs)))
    when(ACL_nonEmpty(ACL_claudeArgs)
      cmd = strcat(cmd " " ACL_claudeArgs))
    cmd = ACL_wrapCmd(cmd)
    ACL_proc = ipcBeginProcess(cmd ""
      lambda((id data)
        ACL_dispatchStreamLines(data "claude" 'ACL_processStreamLine))
      lambda((id data)
        foreach(d parseString(data "\n")
          printf("claude: %s\n" d)
          ACL_handleStaleSession(d))
        axlFlushDisplay())
      'ACL_exitHandler)
    ipcWaitForProcess(ACL_proc)
    unless(and(ACL_proc ipcIsAliveProcess(ACL_proc))
      printf("*Error* ACL: claude process failed to start. Command: %s\n"
        cmd))))

procedure(ACL_claudeDriverSend(text isSynthetic noQuery)
  ; Pack one user message in claude's stream-json wire format.
  let(((pairs list(
      list("type" "user")
      list("message" list(
        list("role" "user")
        list("content" text))))))
    when(isSynthetic pairs = append(pairs list(list("isSynthetic" t))))
    when(noQuery pairs = append(pairs list(list("shouldQuery" 'false))))
    ipcWriteProcess(ACL_proc strcat(ACL_jsonVal(pairs) "\n"))))

; --- Codex driver ---
;
; Talks to `codex app-server --listen stdio://` over newline-delimited
; JSON-RPC (no jsonrpc:"2.0" header). Lifecycle: spawn once per
; session, initialize -> thread/start (or thread/resume / thread/fork
; on restore) -> turn/start per user message. The threadId returned
; by codex becomes ACL_sessionId. Wrapper-routed targets (--with-proxy
; etc.) live in the registry entry's `args` field.

defvar(ACL_codexNextRpcId 0)        ; per-process JSON-RPC id sequence
defvar(ACL_codexThreadId nil)       ; UUIDv7 from thread/started; mirrored to ACL_sessionId
defvar(ACL_codexInitialized nil)    ; set after the initialize round-trip completes
defvar(ACL_codexThreadStarted nil)  ; set after thread/start (or resume/fork) returns
defvar(ACL_codexResumeId nil)       ; thread id requested at launch (for thread/resume / fork)
defvar(ACL_codexResumeIsFork nil)   ; t if the launch should fork from codexResumeId
defvar(ACL_codexPendingTurns nil)   ; user messages queued behind the active turn
defvar(ACL_codexPendingAmbient "")  ; noQuery text buffered for the next real turn
defvar(ACL_codexInflightSend nil)   ; t while a turn is in-flight (not yet turn/completed)
defvar(ACL_codexCurrentTurnId nil)  ; id of the in-flight turn (used as turn/steer's expectedTurnId)
defvar(ACL_codexInflightSteerId nil) ; RPC id of an in-flight turn/steer; non-nil while we await its response
defvar(ACL_codexInflightSteerText nil) ; text of the in-flight steer; re-queued on failure
defvar(ACL_codexInflightSteerCount 0) ; display-queue entries the in-flight steer represents
defvar(ACL_codexSteeredPendingFlush 0) ; display entries waiting to flush at the next item/started (when codex's pending input actually reaches the model)

; Filter codex's noisy stderr: ANSI escapes + recurring OTel /
; web_search_mode chatter + model misuse of resources/list against
; non-existent MCP servers.
defvar(ACL_ansiEscRe pcreCompile(strcat(ACL_byte(0x1b) "\\[[0-9;]*[a-zA-Z]")))
defvar(ACL_codexNoiseRe pcreCompile(strcat(
  "BatchLogProcessor\\.|"
  "BatchSpanProcessor\\.|"
  "web_search_mode|"
  "unknown MCP server")))
; Router errors for the allegro MCP server -- counted so tests can
; assert no router errors during an exchange. Misuse of built-ins
; (update_plan, resources/*) is excluded.
defvar(ACL_codexMcpErrorRe pcreCompile("router: error=tools/call .*allegro"))
defvar(ACL_codexMcpErrorCount 0)
defvar(ACL_codexAllegroToolRe pcreCompile("^allegro_"))

procedure(ACL_codexCleanStderr(line)
  ; ANSI-stripped line, or nil to suppress. Tallies allegro-MCP
  ; router errors as a side effect (consumed by tests).
  let(((clean pcreReplace(ACL_ansiEscRe line "" 0)))
    when(pcreMatchp(ACL_codexMcpErrorRe clean)
      ACL_codexMcpErrorCount = ACL_codexMcpErrorCount + 1)
    unless(pcreMatchp(ACL_codexNoiseRe clean) clean)))

procedure(ACL_codexAllocRpcId()
  ACL_codexNextRpcId = ACL_codexNextRpcId + 1
  ACL_codexNextRpcId)

procedure(ACL_codexSend(method paramsObj @optional id)
  ; id present -> request, id absent -> notification.
  let(((envelope list(list("method" method)
                      list("params" paramsObj))))
    when(id envelope = cons(list("id" id) envelope))
    let(((wire strcat(ACL_jsonVal(envelope) "\n")))
      when(ACL_enableRawLog
        let(((fp outfile(strcat(ACL_homeDir "raw.log") "a")))
          when(fp fprintf(fp ">>> %s" wire) close(fp))))
      ipcWriteProcess(ACL_proc wire))))

procedure(ACL_tomlStr(s)
  ; TOML basic-string ("...") with \" and \\ escapes. Same wire shape
  ; as JSON, so reuse ACL_jsonEscStr -- safe for any UTF-8 input.
  ACL_jsonEscStr(or(s "")))

procedure(ACL_codexConfigArg(key tomlValue)
  ; The two argv tokens of a `-c key=value` flag. tomlValue is
  ; already TOML-encoded (string -> `"..."`, array -> `[...]`,
  ; bareword -> as-is). Only the value is shell-quoted -- the bare
  ; `-c` flag stays unquoted so cmd /sh parsing doesn't break.
  list("-c" ACL_shellQuote(sprintf(nil "%s=%s" key tomlValue))))

procedure(ACL_codexBuildCmd(mcpScript entryArgs)
  ; Assemble the codex command line. Only `-c key=value` values are
  ; shell-quoted (they carry TOML `"` chars and array commas that
  ; must survive the cmd /sh parse). The executable name and bare
  ; flags pass through as-is so cmd's command-name scanner can find
  ; `codex` on PATH -- quoting the first token wraps it as
  ; `\"codex\"` which cmd.exe can't resolve. User-supplied entryArgs
  ; / ACL_codexArgs are injected raw (user owns the shell-quoting).
  ; `-c` flags MUST land before `app-server`; wrapper flags
  ; (--with-proxy etc.) share that constraint.
  ;
  ; Auto-approve allegro tools below: SKILL gates approvals via
  ; ACL_mode (manual/auto/quiet); codex must not pop its own
  ; approval prompts and deadlock the turn.
  letseq(((pythonCmd if(ACL_isWindows "python" "python3"))
          (tag or(ACL_sessionTag ""))
          (effort ACL_entryField(ACL_activeEntry "effort"))
          (tokens nil))
    tokens = list(if(ACL_isWindows "codex"
                                   "env -u LD_LIBRARY_PATH codex"))
    foreach(pair list(
        ACL_codexConfigArg("mcp_servers.allegro.command"
          ACL_tomlStr(pythonCmd))
        ACL_codexConfigArg("mcp_servers.allegro.args"
          sprintf(nil "[%s, %s]"
            ACL_tomlStr(mcpScript) ACL_tomlStr(tag)))
        ACL_codexConfigArg("mcp_servers.allegro.default_tools_approval_mode"
          ACL_tomlStr("auto"))
        ACL_codexConfigArg("tools.experimental_request_user_input.enabled"
          "false"))
      tokens = append(tokens pair))
    when(ACL_nonEmpty(effort)
      tokens = append(tokens
        ACL_codexConfigArg("model_reasoning_effort" effort)))
    let(((cmd buildString(tokens " ")))
      when(ACL_nonEmpty(entryArgs)
        cmd = strcat(cmd " " entryArgs))
      when(ACL_nonEmpty(ACL_codexArgs)
        cmd = strcat(cmd " " ACL_codexArgs))
      cmd = strcat(cmd " app-server --listen stdio://")
      ACL_wrapCmd(cmd))))

procedure(ACL_codexDriverStart(resumeId fork)
  ; Run codex against the user's normal ~/.codex (no CODEX_HOME
  ; override, same as the claude driver). Per-launch state (MCP
  ; server registration with the session tag, entry args, model
  ; effort) lands as `-c` overrides assembled inline.
  letseq(((mcpScript ACL_normPath(strcat(ACL_homeDir "allegro_mcp.py")))
          (entryArgs ACL_entryField(ACL_activeEntry "args"))
          (cmd ACL_codexBuildCmd(mcpScript entryArgs)))
    ACL_copyFile(strcat(ACL_scriptDir "allegro_mcp.py") mcpScript)
    ACL_codexInitialized = nil
    ACL_codexThreadStarted = nil
    ACL_codexThreadId = nil
    ACL_codexResumeId = resumeId
    ACL_codexResumeIsFork = and(resumeId fork)
    ACL_codexPendingTurns = nil
    ACL_codexPendingAmbient = ""
    ACL_codexInflightSend = nil
    ACL_codexCurrentTurnId = nil
    ACL_codexInflightSteerId = nil
    ACL_codexInflightSteerText = nil
    ACL_codexInflightSteerCount = 0
    ACL_codexSteeredPendingFlush = 0
    ACL_codexNextRpcId = 0
    ACL_proc = ipcBeginProcess(cmd ""
      lambda((id data)
        ACL_dispatchStreamLines(data "codex" 'ACL_codexProcessLine))
      lambda((id data)
        foreach(d parseString(data "\n")
          let(((clean ACL_codexCleanStderr(d)))
            when(clean printf("codex: %s\n" clean))))
        axlFlushDisplay())
      'ACL_exitHandler)
    ipcWaitForProcess(ACL_proc)
    if(and(ACL_proc ipcIsAliveProcess(ACL_proc))
      ; Kick off the JSON-RPC dance. thread/start gets queued in
      ; the data handler once initialize completes.
      ACL_codexSend("initialize"
        list(list("clientInfo" list(list("name" "allegro-claude")
                                    list("version" "1.0")))
             list("capabilities" list(list("clientType" "ide"))))
        ACL_codexAllocRpcId())
      printf("*Error* ACL: codex process failed to start. Command: %s\n"
        cmd))))

procedure(ACL_dispatchStreamLines(data label processLineFn)
  ; Shared stream demux for both drivers: optional raw-log mirror,
  ; newline-split with trailing partial preserved, per-line errset so
  ; one bad line can't deadlock the handler, then a single check for
  ; an armed fallback retry (driver's stop+restart can't safely run
  ; from a nested dataHandler frame).
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
        unless(errset(funcall(processLineFn line))
          ACL_streamErrorCount++
          printf("*Warning* ACL: %s stream error: %L\n"
            label errset.errset)
          axlFlushDisplay()))
      pos = nindex(ACL_lineBuf "\n"))
    when(ACL_fallbackRetryPending
      ACL_fallbackRetry())))

procedure(ACL_codexBuildThreadParams()
  ; thread/start params shared by start/resume/fork. SKILL handles
  ; approvals via ACL_mode; sandbox=read-only forces every file write
  ; through the allegro MCP server (whose Python process runs outside
  ; codex's sandbox). Mirrors claude's --disallowedTools Edit/Write:
  ; we don't want the model writing through shell or apply_patch and
  ; silently hitting the sandbox redirect.
  letseq(((projectDir ACL_normPath(pcreReplace(ACL_lastPathCompRe
            simplifyFilename(or(axlGetDrawingName() ACL_homeDir)) "" 0)))
          (devInstr ACL_buildSystemPrompt()))
    when(ACL_shouldLoadDocCache()
      let(((doc ACL_findOrPlanDocs()))
        when(and(doc isFile(doc))
          devInstr = strcat(devInstr "\n\n"
                              ACL_replacePaths(ACL_readFile(doc))))))
    list(
      list("model" ACL_activeModelId())
      list("developerInstructions" devInstr)
      list("cwd" projectDir)
      list("approvalPolicy" "never")
      list("sandbox" "read-only"))))

procedure(ACL_codexProcessLine(line)
  prog((parsed method params id result errBody)
    parsed = ACL_jParse(line)
    unless(parsed return(nil))
    parsed = car(parsed)
    method = ACL_jGet(parsed "method")
    params = ACL_jGet(parsed "params")
    id = ACL_jGet(parsed "id")
    result = ACL_jGet(parsed "result")
    errBody = ACL_jGet(parsed "error")
    cond(
      ; Server-initiated request (has both method and id): we must
      ; reply or codex stalls. ACL_codexHandleRequest auto-decides
      ; (SKILL's ACL_mode is the real approval gate).
      (and(id method) ACL_codexHandleRequest(id method params))
      ; Response (has id, no method): correlate to outstanding request.
      (and(id null(method))
        ACL_codexHandleResponse(id result errBody))
      ; Notification (has method, no id).
      (method ACL_codexHandleNotification(method params)))))

procedure(ACL_codexHandleRequest(id method params)
  ; Server-initiated requests must be answered or codex stalls.
  ; commandExecution approvals auto-accept (SKILL's ACL_mode is the
  ; real gate). Anything else gets a JSON-RPC error so codex moves
  ; on instead of hanging.
  cond(
    (method == "item/commandExecution/requestApproval"
      let(((cmd or(ACL_jGet(params "command") "")))
        when(ACL_nonEmpty(cmd)
          ACL_setStatus(sprintf(nil "Running: %s"
            pcreReplace(ACL_collapseWSRe cmd " " 0))))
        ACL_codexSendResult(id list(list("decision" "accept")))))
    (t
      printf("*Warning* ACL: codex unhandled request %s id=%L\n" method id)
      ACL_codexSendError(id -32601 sprintf(nil "Unknown method: %s" method)))))

procedure(ACL_codexSendResult(id result)
  ; Send a JSON-RPC response payload back to codex.
  let(((wire strcat(ACL_jsonObj(list("id" id) list("result" result)) "\n")))
    when(ACL_enableRawLog
      let(((fp outfile(strcat(ACL_homeDir "raw.log") "a")))
        when(fp fprintf(fp ">>> %s" wire) close(fp))))
    ipcWriteProcess(ACL_proc wire)))

procedure(ACL_codexSendError(id code message)
  ; Send a JSON-RPC error reply for an unhandled server request.
  let(((wire strcat(ACL_jsonObj(list("id" id)
                                list("error" list(list("code" code)
                                                  list("message" message)))) "\n")))
    when(ACL_enableRawLog
      let(((fp outfile(strcat(ACL_homeDir "raw.log") "a")))
        when(fp fprintf(fp ">>> %s" wire) close(fp))))
    ipcWriteProcess(ACL_proc wire)))

procedure(ACL_codexExtractThreadId(result)
  ; Both `result` (thread/start response) and `params` (thread/started
  ; notification) carry the thread id at `.thread.id`.
  let(((th ACL_jGet(result "thread")))
    when(th ACL_jGet(th "id"))))

procedure(ACL_codexCaptureThreadId(tid)
  ; Idempotent across thread/{start,resume,fork} response and the
  ; thread/started notification (either may arrive first). Skip the
  ; "Connected" stamp if a queued turn will flip status to
  ; "Thinking..." anyway.
  when(and(stringp(tid) null(ACL_codexThreadStarted))
    ACL_codexThreadId = tid
    ACL_sessionId = tid
    ACL_codexBootstrapSessionDir(tid)
    ACL_codexThreadStarted = t
    unless(ACL_codexPendingTurns ACL_setStatus("Connected"))
    ACL_codexFlush()))

procedure(ACL_codexHandleResponse(id result errBody)
  ; Dispatch JSON-RPC responses we care about: turn/steer ack
  ; (handleSteerResponse handles success+failure), pre-thread error
  ; (stale-session reject), other errors (try auto-fallback, else
  ; surface to chat), initialize success (advance to thread/start),
  ; thread/{start,resume,fork} success (capture threadId).
  cond(
    (and(ACL_codexInflightSteerId equal(id ACL_codexInflightSteerId))
      ACL_codexHandleSteerResponse(errBody))
    (and(errBody ACL_codexResumeId null(ACL_codexThreadStarted))
      ACL_codexHandleStaleThread(errBody))
    (errBody
      let(((trigger ACL_findFallbackTrigger(nil ACL_jsonVal(errBody))))
        if(and(trigger ACL_fallbackEntry())
          ACL_scheduleFallbackRetry(trigger)
          progn(
            ACL_appendChat(sprintf(nil "\n[codex error id=%L: %s]\n"
              id ACL_jsonVal(errBody)))
            ACL_setStatus("Error")
            ACL_busy = nil))))
    (null(ACL_codexInitialized)
      ACL_codexInitialized = t
      ACL_codexSend("initialized" nil)
      ACL_codexIssueThread())
    (null(ACL_codexThreadStarted)
      ACL_codexCaptureThreadId(ACL_codexExtractThreadId(result)))))

procedure(ACL_codexHandleSteerResponse(errBody)
  ; Success: bank `inflightCount` for the next item/started to flush
  ; (the steered text is in codex's pending input but the model
  ; doesn't see it until its next LLM round). Failure: requeue the
  ; failed text at the head of the transport queue; display untouched.
  ; expectedTurnId mismatch is the routine race (turn ended between
  ; our send and codex's reply) and stays silent.
  letseq(((failedText ACL_codexInflightSteerText)
          (inflightCount ACL_codexInflightSteerCount))
    ACL_codexInflightSteerId = nil
    ACL_codexInflightSteerText = nil
    ACL_codexInflightSteerCount = 0
    if(errBody
      progn(
        unless(ACL_codexIsSteerRaceError(errBody)
          ACL_appendChat(sprintf(nil "\n[codex steer failed, requeued: %s]\n"
            ACL_jsonVal(errBody))))
        when(ACL_nonEmpty(failedText)
          ACL_codexPendingTurns = cons(failedText ACL_codexPendingTurns)))
      ACL_codexSteeredPendingFlush =
        ACL_codexSteeredPendingFlush + inflightCount)
    ACL_codexFlush()))

procedure(ACL_codexFlushSteeredQueue()
  ; Drain banked steered display entries. Called from item/started
  ; (model just began a new LLM round, has consumed the steer) and
  ; turn/completed (safety net for tool-less turns).
  let(((n ACL_codexSteeredPendingFlush))
    when(plusp(n)
      ACL_codexSteeredPendingFlush = 0
      for(i 1 n ACL_flushPendingChat(?one t)))))

procedure(ACL_codexIsSteerRaceError(errBody)
  ; expectedTurnId mismatch -- routine, the turn ended between our
  ; decision-to-steer and the request landing.
  let(((s ACL_jsonVal(errBody)))
    and(stringp(s) nindex(s "expectedTurnId") t)))

procedure(ACL_codexErrorMessage(err)
  ; Unwrap codex's nested error shape into a chat-friendly string.
  ; `err` is whatever sat in `params.error` / `errBody`; its
  ; `message` field is often itself JSON-encoded ({"error":{...}}).
  ; Peel one layer if present.
  if(null(err) "?"
    letseq(((raw or(ACL_jGet(err "message") ACL_jsonVal(err)))
            (inner when(and(stringp(raw)
                            equal(substring(raw 1 1) "{"))
                       car(errset(ACL_jParse(raw))))))
      if(inner
        let(((nested when(inner ACL_jGet(car(inner) "error"))))
          or(when(nested ACL_jGet(nested "message"))
             raw))
        or(raw "?")))))

procedure(ACL_codexHandleStaleThread(errBody)
  ; thread/resume or thread/fork rejected the sid we tried to attach
  ; to. Forget it and fall back to a fresh thread/start so the user
  ; lands in a working session instead of looping on the bad id.
  let(((bad ACL_codexResumeId))
    ACL_codexResumeId = nil
    ACL_codexResumeIsFork = nil
    ACL_dropStaleSession(bad "codex")
    ACL_codexIssueThread()))

procedure(ACL_codexIssueThread()
  let(((paramsObj ACL_codexBuildThreadParams()))
    cond(
      (and(ACL_codexResumeId ACL_codexResumeIsFork)
        ACL_codexSend("thread/fork"
          append(paramsObj list(list("threadId" ACL_codexResumeId)))
          ACL_codexAllocRpcId()))
      (ACL_codexResumeId
        ACL_codexSend("thread/resume"
          append(paramsObj list(list("threadId" ACL_codexResumeId)))
          ACL_codexAllocRpcId()))
      (t ACL_codexSend("thread/start" paramsObj
                       ACL_codexAllocRpcId())))))

procedure(ACL_codexBootstrapSessionDir(sid)
  ; Mirror the claude driver's session-dir setup so log file, MCP tag,
  ; and cmd_<N>.il logging work identically.
  let(((newDir strcat(ACL_logDir sid "/"))
       (oldDir when(ACL_codexResumeId
                    strcat(ACL_logDir ACL_codexResumeId "/"))))
    createDir(ACL_logDir)
    createDir(newDir)
    when(and(ACL_codexResumeIsFork oldDir isDir(oldDir))
      ACL_copyDirFiles(oldDir newDir))
    ACL_sessionLogDir = newDir
    ACL_logFileAppend("")
    ACL_refreshLogButtons()
    ACL_writeSessionTag()
    ACL_mcpCmdSeq = ACL_mcpScanMaxSeq(ACL_sessionLogDir)))

procedure(ACL_codexFlush()
  ; Drain ACL_codexPendingTurns through whichever wire is available
  ; right now:
  ;   * thread not started      -> no-op (thread/started will re-flush)
  ;   * steer in flight         -> no-op (its response will re-flush)
  ;   * gap window: inflight    -> no-op (turn/started will re-flush)
  ;     turn but no turn id
  ;   * active turn, known id   -> single batched turn/steer
  ;   * idle thread             -> single batched turn/start
  ; Every queueing site just calls this; one decision tree governs
  ; all transitions.
  letseq(((haveTurn and(ACL_codexInflightSend ACL_codexCurrentTurnId))
          (idle null(ACL_codexInflightSend))
          (canSend and(ACL_codexThreadStarted
                       null(ACL_codexInflightSteerId)
                       or(haveTurn idle))))
    when(and(ACL_codexPendingTurns canSend)
      letseq(((batch ACL_codexPendingTurns)
              (count length(batch))
              (body buildString(batch "\n\n")))
        ACL_codexPendingTurns = nil
        if(haveTurn
          ACL_codexIssueSteer(body count)
          ACL_codexIssueTurn(body))))))

procedure(ACL_codexConsumeAmbient(text)
  ; Prepend any buffered noQuery context to `text` and clear the
  ; ambient buffer. Both turn/start and turn/steer go through here
  ; so noQuery hints ride the next real send regardless of which
  ; wire it lands on.
  letseq(((body if(ACL_nonEmpty(ACL_codexPendingAmbient)
                strcat(ACL_codexPendingAmbient "\n\n" text)
                text)))
    ACL_codexPendingAmbient = ""
    body))

procedure(ACL_codexIssueTurn(text)
  ; Fire turn/start with `text` + any buffered ambient context. Pin
  ; status to "Thinking..." now since codex can take seconds to emit
  ; turn/started, and the user shouldn't see "Connected" / "Ready"
  ; meanwhile.
  let(((body ACL_codexConsumeAmbient(text)))
    ACL_codexInflightSend = t
    ACL_busy = t
    ACL_setStatus("Thinking...")
    ACL_codexSend("turn/start"
      list(list("threadId" ACL_codexThreadId)
           list("input" list(list(list("type" "text") list("text" body))))
           list("sandboxPolicy" list(list("type" "readOnly"))))
      ACL_codexAllocRpcId())))

procedure(ACL_codexIssueSteer(text count)
  ; Inject `text` into the active turn via turn/steer. `count` is the
  ; number of display-queue entries this steer represents so
  ; ACL_codexHandleSteerResponse can bank the matching display flush
  ; (success) or requeue (failure). Codex folds steered input into
  ; the active turn's next LLM round.
  letseq(((body ACL_codexConsumeAmbient(text))
          (rpcId ACL_codexAllocRpcId()))
    ACL_codexInflightSteerId = rpcId
    ACL_codexInflightSteerText = text
    ACL_codexInflightSteerCount = count
    ACL_codexSend("turn/steer"
      list(list("threadId" ACL_codexThreadId)
           list("expectedTurnId" ACL_codexCurrentTurnId)
           list("input" list(list(list("type" "text") list("text" body)))))
      rpcId)))

procedure(ACL_codexHandleNotification(method params)
  cond(
    (method == "thread/started"
      ACL_codexCaptureThreadId(ACL_codexExtractThreadId(params)))
    (method == "turn/started"
      let(((turn ACL_jGet(params "turn")))
        when(turn ACL_codexCurrentTurnId = ACL_jGet(turn "id")))
      ACL_busy = t
      ACL_setStatus("Thinking...")
      ; currentTurnId is now known; ACL_codexFlush can promote any
      ; gap-window queue to a steer.
      ACL_codexFlush())
    (method == "error"
      ; Async failure mid-turn (bad MCP call, malformed tool args,
      ; ...). Do NOT clear busy/status -- only turn/completed does
      ; that. Auto-fallback first so a provider rejection swaps the
      ; model instead of pasting raw JSON into chat.
      letseq(((err ACL_jGet(params "error"))
              (trigger when(err
                        ACL_findFallbackTrigger(nil ACL_jsonVal(err)))))
        if(and(trigger ACL_fallbackEntry())
          ACL_scheduleFallbackRetry(trigger)
          ACL_appendChat(sprintf(nil "\n[codex error: %s]\n"
            ACL_codexErrorMessage(err))))))
    (method == "turn/completed"
      ACL_codexInflightSend = nil
      ACL_codexCurrentTurnId = nil
      letseq(((turn ACL_jGet(params "turn"))
              (status when(turn ACL_jGet(turn "status")))
              (err when(turn ACL_jGet(turn "error"))))
        ACL_onResponseComplete()
        ; Failed/interrupted turns: surface the error and pin "Error"
        ; on the status bar instead of "Ready".
        when(and(status status != "completed")
          when(err
            ACL_appendChat(sprintf(nil "\n[codex turn %s: %s]\n"
              status ACL_codexErrorMessage(err))))
          ACL_setStatus(sprintf(nil "Turn %s" status))))
      ACL_codexFlush())
    (method == "thread/tokenUsage/updated"
      ; last.* = this turn, total.* = session cumulative. Weight
      ; per ACL_weightedTokens so the status bar has a single
      ; comparable figure when there's no $-cost.
      let(((tu ACL_jGet(params "tokenUsage")))
        when(tu
          let(((last  ACL_jGet(tu "last"))
               (total ACL_jGet(tu "total"))
               (win   ACL_jGet(tu "modelContextWindow")))
            when(integerp(win) ACL_lastContextWindow = win)
            when(last
              let(((tot ACL_jGet(last "totalTokens")))
                when(integerp(tot) ACL_lastContextTokens = tot)))
            when(total
              ACL_sessionWeightedTokens = ACL_weightedTokens(total))))))
    (method == "item/agentMessage/delta"
      letseq(((delta ACL_jGet(params "delta"))
              (itemId ACL_jGet(params "itemId")))
        when(stringp(delta)
          when(and(itemId null(assoc(itemId ACL_streamedMsgLen)))
            ACL_streamingMsgId = itemId
            ACL_streamedMsgLen = cons(list(itemId 0) ACL_streamedMsgLen))
          let(((entry when(itemId assoc(itemId ACL_streamedMsgLen))))
            when(entry
              rplaca(cdr(entry) (cadr(entry) + strlen(delta)))))
          ACL_responseBuf = strcat(ACL_responseBuf delta)
          ACL_streamToDisplay(delta)
          ACL_maybeSaveSession())))
    (method == "item/started"
      ; A new item means the model is starting a fresh LLM round and
      ; has consumed any banked steered input; flush "You: ..." now.
      ACL_codexFlushSteeredQueue()
      let(((item ACL_jGet(params "item"))
           itype)
        when(item
          itype = ACL_jGet(item "type")
          cond(
            (itype == "mcpToolCall"
              ; Match allegro tools by server name or `allegro_`
              ; prefix; rebuild the alist ACL_handleToolCall expects.
              letseq(((tool or(ACL_jGet(item "tool") ""))
                      (server or(ACL_jGet(item "server") ""))
                      (pfx "mcp__allegro__")
                      (isAllegro or(equal(server "allegro")
                                    pcreMatchp(ACL_codexAllegroToolRe tool))))
                ACL_hadToolUse = t
                ACL_setStatus(sprintf(nil "Using %s..."
                  if(isAllegro tool
                    if(ACL_nonEmpty(server)
                      sprintf(nil "%s/%s" server tool)
                      tool))))
                when(isAllegro
                  ACL_handleToolCall(list(
                    list("id" ACL_jGet(item "id"))
                    list("name" if(and(strlen(tool) >= strlen(pfx)
                                       substring(tool 1 strlen(pfx)) == pfx)
                                 tool
                                 strcat(pfx tool)))
                    list("input" ACL_jGet(item "arguments")))))))
            (itype == "commandExecution"
              ; Codex's built-in shell tool -- preview the command.
              let(((cmd or(ACL_jGet(item "command") "shell")))
                ACL_hadToolUse = t
                ACL_setStatus(sprintf(nil "Running: %s"
                  pcreReplace(ACL_collapseWSRe cmd " " 0)))))
            (itype == "agentMessage"
              when(ACL_logContent ACL_logWrite("\n\n"))
              ACL_hadToolUse = nil)))))
    (method == "item/completed"
      let(((item ACL_jGet(params "item"))
           itype)
        when(item
          itype = ACL_jGet(item "type")
          cond(
            (or(itype == "mcpToolCall" itype == "commandExecution")
              ; Reset to "Thinking..."; the next agentMessage delta
              ; (or item/started) takes over from here.
              ACL_setStatus("Thinking..."))
            (itype == "agentMessage"
              ; Final non-streaming form -- dedup vs the deltas.
              let((text seenLen entry newText itemId)
                itemId = ACL_jGet(item "id")
                entry = when(itemId assoc(itemId ACL_streamedMsgLen))
                text = or(ACL_jGet(item "text") "")
                seenLen = if(entry cadr(entry) strlen(text))
                when(strlen(text) > seenLen
                  newText = substring(text (seenLen + 1))
                  when(and(newText strlen(newText) > 0)
                    ACL_responseBuf = strcat(ACL_responseBuf newText)
                    ACL_streamToDisplay(newText))
                  when(entry rplaca(cdr(entry) strlen(text))))))))))))

procedure(ACL_codexDriverSend(text isSynthetic noQuery)
  ; noQuery -> buffer ambient; real sends append to the transport
  ; queue and let ACL_codexFlush pick the right wire. isSynthetic is
  ; unused (codex has no equivalent weighting hint).
  isSynthetic
  if(noQuery
    ACL_codexPendingAmbient = if(ACL_nonEmpty(ACL_codexPendingAmbient)
      strcat(ACL_codexPendingAmbient "\n\n" text)
      text)
    progn(
      ACL_codexPendingTurns = append1(ACL_codexPendingTurns text)
      ACL_codexFlush())))

; --- Generic send/ensure entry points ---

procedure(ACL_ensureAgent()
  when(and(ACL_proc null(ipcIsAliveProcess(ACL_proc)))
    printf("*Warning* ACL: agent process died (exit status: %L)\n"
      ACL_proc->exitStatus)
    ACL_proc = nil)
  unless(ACL_proc
    ACL_startAgent(ACL_sessionId)))

procedure(ACL_sendMessage(text @key (isSynthetic nil) (noQuery nil))
  ; isSynthetic tags the message as infrastructure-emitted, not user-typed,
  ; so the agent weights it accordingly in its own context. noQuery
  ; additionally tells the agent not to spend a turn responding (used
  ; for "here's some ambient state, fold it into your next reply"
  ; sidebar messages).
  ACL_ensureAgent()
  when(ACL_proc
    unless(noQuery ACL_busy = t)
    ; Snapshot so ACL_scheduleFallbackRetry can replay on API error.
    ACL_lastSent = list(text isSynthetic noQuery)
    let(((driver ACL_activeDriver()))
      cond(
        (driver == "claude" ACL_claudeDriverSend(text isSynthetic noQuery))
        (driver == "codex"  ACL_codexDriverSend(text isSynthetic noQuery))))))

; --- Model fallback on misbehaving API responses ---------------------
;
; Some API providers reject newer claude betas with errors that need a
; per-Allegro-session model swap. Each ACL_fallbackTriggers predicate
; tests one such failure pattern against the result event; the first
; match swaps ACL_activeEntry to its declared fallback entry, relaunches
; the agent (resuming on the same sid so prior turns survive), and
; replays the message that triggered the error.

procedure(ACL_isRoleSystemError(errStatus resText)
  ; Upstream provider rejected role:"system" inside messages[] -- some
  ; providers refuse Anthropic's mid-conversation-system beta this way.
  ; Triggers on the claude path (HTTP 422 + body) and the codex path
  ; (no HTTP status, JSON-encoded error body carries the same markers,
  ; possibly with escaped quotes).
  and(stringp(resText)
      pcreMatchp("\\\\?\"role\\\\?\"" resText)
      pcreMatchp("\\\\?\"system\\\\?\"" resText)
      or(equal(errStatus 422) null(errStatus))
      t))

procedure(ACL_findFallbackTrigger(errStatus resText)
  ; Returns the label of the first matching trigger, or nil.
  let((match)
    foreach(spec ACL_fallbackTriggers
      unless(match
        when(funcall(cadr(spec) errStatus resText)
          match = car(spec))))
    match))

procedure(ACL_scheduleFallbackRetry(triggerLabel)
  ; Stash the trigger and let the driver's data handler call
  ; ACL_fallbackRetry after returning from the current handler invocation
  ; (axlUIWTimerAdd doesn't fire under -nograph batch mode).
  ACL_fallbackRetryPending = or(triggerLabel t))

procedure(ACL_fallbackEntry()
  ; The next entry to swap to, or nil when none is declared.
  when(ACL_activeEntry
    let(((target ACL_entryField(ACL_activeEntry "fallback")))
      when(target ACL_modelById(target)))))

procedure(ACL_fallbackRetry()
  let(((trigger ACL_fallbackRetryPending)
       (sid ACL_sessionId)
       (replay ACL_lastSent)
       (next ACL_fallbackEntry()))
    ACL_fallbackRetryPending = nil
    when(next
      ACL_activeEntry = next
      printf("ACL: switching to %s after %L\n"
        ACL_entryLabel(next) trigger)
      ACL_appendChat(sprintf(nil
        "\n[Switched to %s after API error: %L]\n"
        ACL_entryLabel(next) trigger))
      ACL_stopAgent()
      ACL_startAgent(sid)
      when(replay
        ACL_sendMessage(car(replay)
          ?isSynthetic cadr(replay)
          ?noQuery     caddr(replay))))))

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
          (seq nil)
          (synErr nil))
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
      ; Pre-flight allegro_execute through the reader-only syntax
      ; check. Bad-syntax calls fail the same way whether the user
      ; approves them or not, so short-circuit before reaching the
      ; manual-mode approval gate.
      when(toolName == "mcp__allegro__allegro_execute"
        synErr = ACL_skillSyntaxCheckCode(ACL_jGet(input "code")))
      cond(
        (synErr
          ACL_finishToolResult(toolId toolName input seq
            sprintf(nil "*error* syntax check failed: %s" synErr)))
        (t
          ACL_mcpPending = append(ACL_mcpPending list(list(toolId toolName input seq)))
          ; In manual mode, hold the queue until the user types `approve`
          ; (or `reject`). Otherwise schedule a deferred drain.
          if(ACL_mode == "manual"
            ACL_setStatus(
              sprintf(nil "Manual: %d pending...waiting for you to \"approve\" or \"reject\"" length(ACL_mcpPending))
            )
            ACL_mcpScheduleDrain()))))))

procedure(ACL_toolPreview(toolName input)
  ; Human-readable representation of a tool call for the cmd_<N>.il
  ; log. allegro_execute logs the SKILL code; the file tools log a
  ; comment-prefixed summary plus any content/edit payloads. Returns
  ; nil for unknown tools.
  cond(
    (toolName == "mcp__allegro__allegro_execute"
      ACL_jGet(input "code"))
    (toolName == "mcp__allegro__allegro_read_file"
      letseq(((offset ACL_jGet(input "offset"))
              (length ACL_jGet(input "length"))
              (binary ACL_jGet(input "is_binary"))
              (modes ""))
        when(offset modes = strcat(modes sprintf(nil " offset=%L" offset)))
        when(length modes = strcat(modes sprintf(nil " length=%L" length)))
        when(binary modes = strcat(modes " binary"))
        sprintf(nil "; read_file %L%s" ACL_jGet(input "path") modes)))
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
              (result ACL_runTool(toolName input)))
        ACL_finishToolResult(toolId toolName input seq result)))))

procedure(ACL_finishToolResult(toolId toolName input seq result)
  ; Land the result for a tool call: writes the readable cmd_<seq>.out
  ; log entry and the three IPC sidecars (.req describes the call so
  ; codex can match it; .err is an empty marker that promotes the
  ; result to a JSON-RPC error -- codex ignores the spec's `isError`
  ; flag on a successful result and feeds the error text back as a
  ; normal observation; .out lands last so the MCP server never sees a
  ; stale match without its result).
  when(ACL_sessionLogDir
    letseq(((ipcOutPath sprintf(nil "%s/tool_%s.out" ACL_sessionLogDir toolId))
            (ipcErrPath sprintf(nil "%s/tool_%s.err" ACL_sessionLogDir toolId))
            (ipcReqPath sprintf(nil "%s/tool_%s.req" ACL_sessionLogDir toolId)))
      ACL_writeFile(sprintf(nil "%s/cmd_%d.out" ACL_sessionLogDir seq) result)
      ACL_writeFileAtomic(ipcReqPath ACL_jsonObj(
        list("name" ACL_stripMcpPrefix(toolName))
        list("arguments" or(input nil))))
      when(ACL_toolResultIsError(result)
        ACL_writeFileAtomic(ipcErrPath ""))
      ACL_writeFileAtomic(ipcOutPath result))))

defvar(ACL_toolErrPrefixRe pcreCompile("^\\*[Ee]rror\\*"))

procedure(ACL_toolResultIsError(result)
  and(stringp(result) pcreMatchp(ACL_toolErrPrefixRe result)))

procedure(ACL_stripMcpPrefix(toolName)
  ; The claude CLI exposes tools as `mcp__<server>__<tool>`. Codex
  ; exposes them as `mcp__<server>__.<tool>` (extra dot). Strip both
  ; back to the bare tool name for content matching.
  let(((bare pcreReplace(ACL_mcpToolPrefixRe toolName "" 0)))
    if(and(strlen(bare) > 0 substring(bare 1 1) == ".")
      substring(bare 2) bare)))

procedure(ACL_runTool(toolName input)
  ; Dispatch one tool call by name. Each branch handles its own arg
  ; extraction so adding a tool only touches this proc + ACL_toolPreview.
  cond(
    (toolName == "mcp__allegro__allegro_execute"
      let(((raw errset(ACL_execBlock(ACL_jGet(input "code")))))
        if(raw car(raw) "*error* SKILL execution failed unexpectedly")))
    (toolName == "mcp__allegro__allegro_read_file"
      ACL_toolReadFile(ACL_jGet(input "path")
                       or(ACL_jGet(input "offset") 0)
                       or(ACL_jGet(input "length") 2000)
                       and(ACL_jGet(input "is_binary") t)))
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

procedure(ACL_toolReadFile(path offset length isBinary)
  ; Read `length` lines (or bytes if isBinary) starting at `offset`
  ; lines (or bytes). offset/length default to 0/2000 at the caller
  ; site. Hard-caps the returned content at ACL_maxReadBytes (20KB)
  ; -- the model must chunk longer files by re-calling with smaller
  ; length and an advancing offset. On cap failure, return a message
  ; that includes the actual file size so the model can plan.
  or(ACL_validateFilePath("read_file" path t)
     when(or(null(integerp(offset)) offset < 0)
       sprintf(nil "*error* read_file: offset must be a non-negative integer, got %L" offset))
     when(or(null(integerp(length)) length <= 0)
       sprintf(nil "*error* read_file: length must be a positive integer, got %L" length))
     if(isBinary
       ACL_toolReadFileBinary(path offset length)
       ACL_toolReadFileLines(path offset length))))

procedure(ACL_toolReadFileBinary(path offset length)
  ; Byte-based read: seek then collect up to ACL_maxReadBytes chars.
  letseq(((sz fileLength(path))
          (cap ACL_maxReadBytes))
    cond(
      (length > cap
        sprintf(nil
          "*error* read_file: requested %d bytes but cap is %d; file size %d bytes. Re-call with smaller length, advancing offset by the previous length."
          length cap sz))
      (t
        let(((fp infile(path))
             chars c read)
          if(null(fp)
            sprintf(nil "*error* read_file: cannot open %s" path)
            progn(
              when(offset > 0 fileSeek(fp offset 0))
              chars = nil
              read = 0
              while(and(read < length (c = getc(fp)))
                chars = cons(c chars)
                read = read + 1)
              close(fp)
              buildString(reverse(chars) ""))))))))

procedure(ACL_toolReadFileLines(path offset length)
  ; Line-based read: skip offset lines, collect up to length more
  ; while total bytes stay within ACL_maxReadBytes.
  letseq(((sz fileLength(path))
          (cap ACL_maxReadBytes)
          (fp infile(path)))
    if(null(fp)
      sprintf(nil "*error* read_file: cannot open %s" path)
      let((line lines skipped taken chars capped)
        lines = nil
        skipped = 0
        taken = 0
        chars = 0
        capped = nil
        while(and(skipped < offset gets(line fp))
          skipped = skipped + 1)
        while(and(null(capped) taken < length gets(line fp))
          if(chars + strlen(line) > cap
            capped = t
            progn(
              lines = cons(line lines)
              chars = chars + strlen(line)
              taken = taken + 1)))
        close(fp)
        if(capped
          sprintf(nil
            "*error* read_file: lines [%d, %d) would exceed %d-byte cap (file size %d bytes). Re-call with smaller length, advancing offset by the previous length."
            offset (offset + length) cap sz)
          buildString(reverse(lines) ""))))))

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

defvar(ACL_readerLineColRe
  ; Match "at line N column N" anywhere -- the useful core of any
  ; reader/parser diagnostic regardless of which channel produced
  ; it. Used to pick a candidate line out of captured errport text.
  pcreCompile("at line \\d+ column \\d+"))

defvar(ACL_readerLineNoiseRe
  ; Strip the standard noisy parts that wrap a reader/parser line:
  ;   "*Error* lineread/read: "  -- routine prefix
  ;   " (in|of) file \*\S+\*"    -- "in file *stdin*" / "of file *string*"
  pcreCompile("^\\*Error\\* \\S+:\\s*|\\s+(in|of) file \\*\\S+\\*\\s*$"))

defvar(ACL_readerWarnHeadRe
  ; Match the reader-warning prefix on the first line; strip it so
  ; the message reads like a plain "a '(' at line N was still
  ; unclosed on EOF" or "string at line N was not terminated on
  ; EOF". The optional "*WARNING* " covers cases where Allegro
  ; includes it; muffleWarnings typically drops it.
  pcreCompile("^(\\s*\\*WARNING\\*)?\\s*\\(reader\\):\\s*"))

defvar(ACL_firstLineRe pcreCompile("\\n[\\s\\S]*"))

defvar(ACL_splitLinesRe pcreCompile("\\n"))

procedure(ACL_extractReaderErrMsg(errOut)
  ; Pull the most useful line out of captured reader/parser errport
  ; output. Different Allegro builds split the diagnostic across
  ; lines differently -- some put "at line N column N" on a
  ; "SYNTAX ERROR found..." prelude, others append it to the
  ; "*Error* lineread/read:" line itself. Find the first line that
  ; carries the line/column, strip routine noise, return the rest.
  when(ACL_nonEmpty(errOut)
    let((line cleaned)
      foreach(raw parseString(errOut "\n")
        when(and(null(cleaned) pcreMatchp(ACL_readerLineColRe raw))
          line = raw
          cleaned = pcreReplace(ACL_trimWSRe
                      pcreReplace(ACL_readerLineNoiseRe raw "" 0)
                      "" 0)))
      when(ACL_nonEmpty(cleaned) cleaned))))

procedure(ACL_skillSyntaxCheckCode(content)
  ; Reader-only structural check on a SKILL source block. Returns
  ; nil if well-formed, otherwise a short reason string. When the
  ; reader emits a line-numbered diagnostic (hard parse error on
  ; errport, or a soft warning via muffleWarnings), surface that
  ; instead of the generic reason. No eval -- nothing in `content`
  ; runs even if it tries to escape the wrapper. Wrap as
  ; `progn(<content>) ACL_synEOF__` and read top-level forms from
  ; a string port. Well-formed content gives exactly two: a list
  ; whose head is `progn`, then the EOF sentinel. Any other shape
  ; is a syntax error.
  ;
  ; Hard errors (parser raises) and soft errors (auto-recovers with
  ; a warning) take different channels:
  ;   hard -- printed to errport; "at line N column N" appears on
  ;           a "SYNTAX ERROR ..." line on some Allegro builds, on
  ;           the "*Error* lineread/read:" line on others.
  ;   soft -- captured by muffleWarnings; first warning's first
  ;           line has the line number (no column).
  let((p forms warns errPort errOut readerMsg reason)
    p = instring(strcat("progn(" content "\n) ACL_synEOF__"))
    errPort = outstring()
    errset(let(((errport errPort))
      forms = muffleWarnings(lineread(p))) t)
    warns = getMuffleWarnings()
    errOut = getOutstring(errPort)
    close(errPort)
    close(p)
    readerMsg = or(
      ACL_extractReaderErrMsg(errOut)
      ; Soft warning fallback: first line, prefix stripped.
      when(warns
        pcreReplace(ACL_trimWSRe
          pcreReplace(ACL_readerWarnHeadRe
            pcreReplace(ACL_firstLineRe car(warns) "" 0)
            "" 0)
          "" 0)))
    reason = cond(
      (or(null(forms) listp(forms) == nil)
        "syntax error")
      (length(forms) != 2
        "mismatched parens")
      (cadr(forms) != 'ACL_synEOF__
        "unterminated string or paren")
      (or(null(listp(car(forms))) car(car(forms)) != 'progn)
        "too many `)`"))
    when(reason
      if(ACL_nonEmpty(readerMsg) readerMsg reason))))

procedure(ACL_skillSyntaxCheck(path content)
  ; File-path wrapper: only runs on .il paths and tags the error
  ; with the path. Used by ACL_writeChecked.
  when(pcreMatchp(ACL_skillFileRe path)
    let(((err ACL_skillSyntaxCheckCode(content)))
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

procedure(ACL_processStreamLine(line)
  prog((parsed etype subtype sid event evtype delta text cblock)
    parsed = ACL_jParse(line)
    unless(parsed return(nil))
    parsed = car(parsed)
    etype = ACL_jGet(parsed "type")
    subtype = ACL_jGet(parsed "subtype")
    ; Only system/init carries the authoritative session id; other
    ; events either lack one or carry transient hook ids.
    sid = when(and(etype == "system" subtype == "init")
      ACL_jGet(parsed "session_id"))
    when(sid
      ; New sid (fresh session or fork) -- set up the log dir, copying
      ; parent files for forks. Same sid (resume) skips this branch
      ; and just re-stamps the tag / re-seeds cmd seq below.
      when(sid != ACL_sessionId
        let(((newDir strcat(ACL_logDir sid "/"))
             (oldDir when(ACL_sessionId strcat(ACL_logDir ACL_sessionId "/"))))
          ACL_sessionId = sid
          createDir(ACL_logDir)
          createDir(newDir)
          ; --fork-session: copy parent logs into the new dir. The
          ; parent's sessions.json entry stays; the fork registers
          ; itself on first text under the CURRENT board.
          when(and(ACL_resumeIsFork oldDir isDir(oldDir))
            ACL_copyDirFiles(oldDir newDir))
          ACL_sessionLogDir = newDir
          ; Drain any pre-init log buffer now that sessionLogDir is real.
          ACL_logFileAppend("")
          ACL_refreshLogButtons()))
      ACL_writeSessionTag()
      ; Seed cmd seq every init: critical for resume (sid unchanged
      ; so the block above is a no-op); harmless on fresh sessions.
      ACL_mcpCmdSeq = ACL_mcpScanMaxSeq(ACL_sessionLogDir))
    cond(
      ; System events (init, api_retry, etc.)
      (etype == "system"
        cond(
          (subtype == "init"
            ACL_setStatus("Connected"))
          (subtype == "status"
            ACL_busy = t
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
              ACL_busy = t
              ACL_setStatus("Responding..."))
            (evtype == "content_block_delta"
              delta = ACL_jGet(event "delta")
              when(and(delta ACL_jGet(delta "type") == "text_delta")
                text = ACL_jGet(delta "text")
                when(text
                  when(ACL_streamingMsgId
                    let(((entry assoc(ACL_streamingMsgId ACL_streamedMsgLen)))
                      when(entry
                        rplaca(cdr(entry) (cadr(entry) + strlen(text))))))
                  ACL_responseBuf = strcat(ACL_responseBuf text)
                  ACL_streamToDisplay(text)
                  ACL_maybeSaveSession())))
            (evtype == "content_block_start"
              cblock = ACL_jGet(event "content_block")
              cond(
                (and(cblock ACL_jGet(cblock "type") == "tool_use")
                  ACL_hadToolUse = t
                  ACL_setStatus(sprintf(nil "Using %s..."
                    pcreReplace(ACL_mcpToolPrefixRe
                      or(ACL_jGet(cblock "name") "tool") "" 0))))
                (and(cblock ACL_jGet(cblock "type") == "text")
                  ; Blank line before text that follows prior content.
                  when(ACL_logContent ACL_logWrite("\n\n"))
                  ACL_hadToolUse = nil)))
            (evtype == "content_block_stop"
              ACL_setStatus("Thinking...")))))
      ; Assistant message (complete, non-streaming). Dedup vs deltas
      ; by tracking streamedMsgLen per msgId.
      (etype == "assistant"
        let((msg content block msgId entry seenLen fullText newText u tot)
          msg = ACL_jGet(parsed "message")
          msgId = when(msg ACL_jGet(msg "id"))
          entry = when(msgId assoc(msgId ACL_streamedMsgLen))
          content = when(msg ACL_jGet(msg "content"))
          ; message.usage carries per-turn context; result events
          ; report the cumulative sum across internal turns, which is
          ; misleading for "how full is the window".
          u = when(msg ACL_jGet(msg "usage"))
          tot = or(ACL_jGet(u "input_tokens") 0)
              + or(ACL_jGet(u "cache_read_input_tokens") 0)
              + or(ACL_jGet(u "cache_creation_input_tokens") 0)
          when(plusp(tot) ACL_lastContextTokens = tot)
          when(content
            fullText = ""
            foreach(block content
              when(and(block ACL_jGet(block "type") == "text")
                text = ACL_jGet(block "text")
                when(text fullText = strcat(fullText text)))
              when(and(block ACL_jGet(block "type") == "tool_use"
                       pcreMatchp(ACL_mcpAllegroToolRe
                         or(ACL_jGet(block "name") "")))
                ACL_handleToolCall(block)))
            ; entry == nil means we missed message_start (resume
            ; mid-turn or partial capture); assume the whole text was
            ; already delivered via deltas to avoid duplicates.
            seenLen = if(entry cadr(entry) strlen(fullText))
            when(strlen(fullText) > seenLen
              newText = substring(fullText (seenLen + 1))
              when(and(newText strlen(newText) > 0)
                ACL_responseBuf = strcat(ACL_responseBuf newText)
                ACL_streamToDisplay(newText))
              when(entry
                rplaca(cdr(entry) strlen(fullText)))))))
      ; Result (response complete). Claude emits spurious empty
      ; result events on resume/init; only ones with a stop_reason
      ; or is_error are real turn ends.
      (etype == "result"
        let(((cost ACL_jGet(parsed "total_cost_usd"))
             (isErr ACL_jGet(parsed "is_error"))
             (errStatus ACL_jGet(parsed "api_error_status"))
             (errReason ACL_jGet(parsed "terminal_reason"))
             (stopReason ACL_jGet(parsed "stop_reason"))
             (resText ACL_jGet(parsed "result")))
          when(numberp(cost) ACL_sessionCostUsd = cost)
          ; modelUsage is keyed by model id; first entry's
          ; contextWindow drives the % ctx display.
          ACL_lastContextWindow =
            or(ACL_jGet(cadr(car(ACL_jGet(parsed "modelUsage"))) "contextWindow")
               ACL_lastContextWindow)
          ; Auto-fallback first: a matching trigger swaps the model
          ; and relaunches before the error reaches chat.
          let(((trigger when(isErr ACL_findFallbackTrigger(errStatus resText))))
            if(and(trigger ACL_fallbackEntry())
              ACL_scheduleFallbackRetry(trigger)
              progn(
                when(isErr
                  ACL_appendChat(sprintf(nil "\n[Error%s%s%s]\n"
                    if(errStatus sprintf(nil " %L" errStatus) "")
                    if(errReason sprintf(nil " %s" errReason) "")
                    if(and(stringp(resText) plusp(strlen(resText)))
                      sprintf(nil ": %s" resText) ""))))
                when(or(stopReason isErr)
                  ACL_onResponseComplete()))))))
      ; tool_result inside a user event = claude finished a tool
      ; call. Flush queued user msgs so they land before claude's
      ; next assistant message.
      (etype == "user"
        letseq(((msg ACL_jGet(parsed "message"))
                (content when(msg ACL_jGet(msg "content"))))
          when(and(listp(content)
                   exists(b content ACL_jGet(b "type") == "tool_result"))
            ACL_flushPendingChat()))))))

; ============================================================
; 8. Display Streaming
; ============================================================

procedure(ACL_streamToDisplay(text)
  ACL_gotText = t
  ACL_logWrite(text))

; ============================================================
; 9. SKILL Execution
; ============================================================

procedure(ACL_execBlock(code)
  ; Execute one SKILL block with error handling.
  ; Returns result string including any printed output.
  prog((result errInfo errMsg output port warnings shellMsgs jfile)
    when(or(null(code) strlen(code) == 0)
      return("(empty block)"))
    ; Reader-only structural check. Catches stray parens, unterminated
    ; strings, etc. before errsetstring runs and leaves partial state.
    let(((synErr ACL_skillSyntaxCheckCode(code)))
      when(synErr
        return(sprintf(nil "*error* syntax check failed: %s" synErr))))
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

procedure(ACL_weightedTokens(breakdown)
  ; Codex reports only raw token counts -- no $-cost. Roll the
  ; breakdown into a single comparable figure using output-tier
  ; pricing as the unit: output (and reasoning, billed at output
  ; rate) at 1x, fresh input at 1/8x, cache-hit input at 1/80x.
  ; Returns a float so successive turns can accumulate cleanly.
  letseq(((inp  or(ACL_jGet(breakdown "inputTokens") 0))
          (cin  or(ACL_jGet(breakdown "cachedInputTokens") 0))
          (out  or(ACL_jGet(breakdown "outputTokens") 0))
          (reas or(ACL_jGet(breakdown "reasoningOutputTokens") 0)))
    out + reas + (inp / 8.0) + (cin / 80.0)))

procedure(ACL_formatTokenCount(n)
  ; Render a token-equivalent count for the status bar in millions
  ; ("1.23Mt") regardless of magnitude, so the bar reads consistently
  ; across early-session and long-session usage.
  sprintf(nil "%.2fMt" (n / 1000000.0)))

procedure(ACL_readyStatus()
  ; "Ready" decorated with cumulative cost (when known) and live context
  ; % (when we have window+tokens). Falls back to a weighted-token total
  ; when no $-cost is available (codex). Bare "Ready" if neither lands.
  let(((hasCost plusp(ACL_sessionCostUsd))
       (hasWtok plusp(ACL_sessionWeightedTokens))
       (hasCtx and(ACL_lastContextWindow plusp(ACL_lastContextWindow)))
       (use ""))
    use = cond(
      (hasCost sprintf(nil "$%.2f" ACL_sessionCostUsd))
      (hasWtok ACL_formatTokenCount(ACL_sessionWeightedTokens))
      (t nil))
    cond(
      (and(use hasCtx)
        sprintf(nil "Ready  -  %s  -  %d%% ctx"
          use round(100.0 * ACL_lastContextTokens / ACL_lastContextWindow)))
      (use sprintf(nil "Ready  -  %s" use))
      (hasCtx
        sprintf(nil "Ready  -  %d%% ctx"
          round(100.0 * ACL_lastContextTokens / ACL_lastContextWindow)))
      (t "Ready"))))

procedure(ACL_onResponseComplete()
  ACL_responseBuf = ""
  ACL_busy = nil
  ; Display queue drains in lockstep with what the transport
  ; delivered. Codex: successful steers bank entries to flush at the
  ; next item/started (so the user sees "You: ..." land alongside the
  ; model's reaction); turn/completed sweeps the remainder (steered
  ; text on a tool-less turn that never produced another item).
  ; Claude takes one queued user msg per turn end, leaving the rest
  ; visible as "Queued:".
  when(ACL_activeDriver() == "codex"
    ACL_codexFlushSteeredQueue())
  if(ACL_activeDriver() == "codex"
    ACL_flushPendingChat()
    ACL_flushPendingChat(?one t))
  ACL_setStatus(ACL_readyStatus()))

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
    axlFormSetField(form "userinput" "")
    axlFormSetActiveField(form "userinput")
    cond(
      (and(inManual pcreMatchp(ACL_approveRe text))
        ACL_handleApprove(pcreSubstitute(ACL_approveRe "\\1")))
      (and(inManual pcreMatchp(ACL_rejectRe text))
        ACL_handleReject(pcreSubstitute(ACL_rejectRe "\\1")))
      (strlen(text) > 0
        ACL_enqueueChatLine(text)
        ACL_handleUserMessage(text)))))

; ============================================================
; 12. Message Handlers
; ============================================================

procedure(ACL_handleUserMessage(text)
  ACL_setStatus("Thinking...")
  ACL_responseBuf = ""
  ACL_busy = t
  ; Record that the user has now provided real input; ACL_maybeSaveSession
  ; gates on this so the synthetic boot-up turn alone doesn't persist
  ; an empty session entry.
  ACL_sessionUserMsgSeen = t
  let(((elapsed stringToTime(getCurrentTime()) - ACL_lastCmdTime))
    when(and(ACL_lastCmdTime elapsed > 60)
      ACL_sendMessage(
        "[NOTE, BUT DON'T ACKNOWLEDGE: The board may have been edited. Re-query instead of relying on memory.]"
        ?isSynthetic t ?noQuery t))
    ACL_sendMessage(text)))

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
  ; Recordings are a user-driven action -- count as real input.
  ACL_sessionUserMsgSeen = t
  ACL_sendMessage(strcat(
    "The user recorded this Allegro macro/journal:\n\n```\n"
    contents "\n```\n\n"
    "Analyze the commands. Explain what the user did step by step. "
    "Generate a reusable SKILL procedure that replicates this action "
    "with parameterized inputs where appropriate.")
    ?isSynthetic t))

; ============================================================
; 13. Session Management UI
; ============================================================

procedure(ACL_handleSessionPick()
  unless(axlGetDrawingName()
    ACL_appendChat("No board file loaded.")
    return(nil))
  unless(ACL_formIsAlive(ACL_sessionPickerForm)
    ACL_sessionPickerForm = nil
    axlFormCreate('ACL_sessionPickerForm
                  strcat(ACL_scriptDir "allegro_claude_sessions.form")
                  nil 'ACL_sessionPickerCB t t))
  when(ACL_sessionPickerForm
    ACL_renderSessionPicker()
    axlFormDisplay(ACL_sessionPickerForm)))

procedure(ACL_renderSessionPicker(@key (selectIdx 0))
  ; Rebuild the listbox from sessions.json. selectIdx is clamped to the
  ; new row count. The model dropdown is populated from the live
  ; registry and preselects whatever the last-used model was for new
  ; sessions.
  letseq(((form ACL_sessionPickerForm)
          (sessions when(form ACL_sortSessionsByTime(ACL_loadSessions())))
          (rows mapcar(lambda((entry)
                        ACL_sessionLabel(car(entry) cadr(entry)
                                         ?currentSid ACL_sessionId))
                       sessions))
          (allRows cons("+ New session" rows))
          (clamped min(selectIdx (length(allRows) - 1)))
          (registry ACL_models())
          (modelLabels mapcar('ACL_entryLabel registry))
          (activeIds mapcar('car registry))
          (activeTail member(ACL_activeId() activeIds))
          (activeIdx if(activeTail (length(activeIds) - length(activeTail)) 0))
          (preselect or(nth(activeIdx modelLabels) car(modelLabels))))
    when(form
      ACL_sessionPickerSids = cons(nil mapcar('car sessions))
      ACL_sessionPickerModelIds = mapcar('car registry)
      ACL_sessionPickerSelIdx = clamped
      axlFormListDeleteAll(form "sessionlist")
      axlFormListAddItem(form "sessionlist" allRows nil)
      axlFormListDeleteAll(form "modelchoice")
      axlFormListAddItem(form "modelchoice" modelLabels nil)
      axlFormListSelect(form "modelchoice" preselect)
      ; SetActiveField on a LIST resets the cursor; do it before select.
      axlFormSetActiveField(form "sessionlist")
      axlFormListSelect(form "sessionlist" nth(clamped allRows))
      ACL_updateSessionPickerButtons())))

procedure(ACL_selectedSessionSid()
  ; Index 0 is the "+ New session" pseudo-row (nil); real sids follow.
  nth(ACL_sessionPickerSelIdx ACL_sessionPickerSids))

procedure(ACL_selectedIsNewSession()
  ACL_sessionPickerSelIdx == 0)

procedure(ACL_updateSessionPickerButtons()
  ; Re-label and enable/disable Rename/Delete to match the highlighted
  ; row. "+ New session" and the current-session row both target the
  ; running session, so they share the "current session" label and the
  ; "no current session yet" disabled state. Any other row targets
  ; whichever entry is highlighted. The model dropdown is only
  ; meaningful for the "+ New session" row -- existing sessions lock
  ; to the model they were started with.
  letseq(((form ACL_sessionPickerForm)
          (selSid ACL_selectedSessionSid())
          (newRow ACL_selectedIsNewSession())
          (targetsCurrent or(newRow
                             and(selSid selSid == ACL_sessionId)))
          (currentInfo when(ACL_sessionId ACL_getSession(ACL_sessionId)))
          (haveCurrent and(ACL_sessionId currentInfo))
          (selInfo when(and(selSid null(newRow)) ACL_getSession(selSid))))
    when(form
      if(targetsCurrent then
        axlFormSetField(form "rename" "Rename current session")
        axlFormSetField(form "delete" "Delete current session")
        axlFormSetFieldEditable(form "rename" haveCurrent)
        axlFormSetFieldEditable(form "delete" haveCurrent)
      else
        axlFormSetField(form "rename" "Rename selected session")
        axlFormSetField(form "delete" "Delete selected session")
        axlFormSetFieldEditable(form "rename" t)
        axlFormSetFieldEditable(form "delete" t))
      axlFormSetField(form "restore"
        if(newRow "Create" "Open"))
      ; Highlight the locked-in model when an existing session is
      ; selected; otherwise leave whatever the user picked.
      letseq(((sessId when(selInfo ACL_sessionModel(selInfo)))
              (entry when(sessId ACL_modelById(sessId))))
        when(entry
          axlFormListSelect(form "modelchoice" ACL_entryLabel(entry))))
      axlFormSetFieldEditable(form "modelchoice" newRow))))

procedure(ACL_sessionPickerCB(form)
  prog((field val)
    when(form->doneState != 0
      ; Window-manager dismiss: clear refs so no later code touches a
      ; dead form.
      ACL_sessionPickerForm = nil
      ACL_sessionPickerSids = nil
      ACL_sessionPickerSelIdx = 0
      return(t))
    field = form->curField
    val = form->curValue
    cond(
      (field == "sessionlist"
        ; Cache the index; button clicks fire as their own field events
        ; and won't see the list's curValueInt.
        ACL_sessionPickerSelIdx = or(form->curValueInt 0)
        ACL_updateSessionPickerButtons())
      (field == "modelchoice"
        ; For "New session" the dropdown drives the active entry that
        ; ACL_handlePickerRestore will commit. Existing rows ignore it.
        ; Map the listbox index back to the id we recorded at render
        ; time -- the displayed value is the label, not the id.
        when(ACL_selectedIsNewSession()
          let(((id nth(or(form->curValueInt 0) ACL_sessionPickerModelIds)))
            when(id ACL_activeEntry = ACL_resolveModel(id)))))
      (field == "rename" ACL_handlePickerRename())
      (field == "delete" ACL_handlePickerDelete())
      (field == "restore" ACL_handlePickerRestore()))))

procedure(ACL_handlePickerRename()
  letseq(((newRow ACL_selectedIsNewSession())
          (sid if(newRow ACL_sessionId ACL_selectedSessionSid()))
          (info when(sid ACL_getSession(sid)))
          (curName when(info ACL_sessionName(info))))
    when(and(sid info)
      letseq(((label ACL_sessionLabel(sid info ?currentSid ACL_sessionId))
              (prompt sprintf(nil
                "New name for session\n  %s\n(blank to clear; Enter keeps existing)"
                label))
              ; axlUIPrompt shows curName as a bracketed default;
              ; bare Return returns it. No editable prefill exists.
              (entered axlUIPrompt(prompt or(curName ""))))
        ; nil = Cancel; empty string = explicit clear.
        if(entered ACL_setSessionName(sid entered))
        ; Re-render to restore focus (prompt stole it).
        ACL_renderSessionPicker(?selectIdx ACL_sessionPickerSelIdx)))))

procedure(ACL_handlePickerDelete()
  letseq(((newRow ACL_selectedIsNewSession())
          (sid if(newRow ACL_sessionId ACL_selectedSessionSid()))
          (info when(sid ACL_getSession(sid))))
    when(and(sid info)
      letseq(((label ACL_sessionLabel(sid info ?currentSid ACL_sessionId))
              (isCurrent sid == ACL_sessionId)
              (msg sprintf(nil
                "Delete this session?\n  %s\n\nThis removes the conversation log and cannot be undone.%s"
                label
                if(isCurrent
                  "\n\nThe active session will stop and a new session will start."
                  ""))))
        when(axlUIYesNo(msg)
          ACL_removeSession(sid)
          ACL_deleteSessionFiles(sid)
          if(isCurrent then
            axlFormClose(ACL_sessionPickerForm)
            ACL_sessionPickerForm = nil
            ; ACL_handleNewSession handles the process tear-down and
            ; state reset; no need to pre-stop ourselves.
            ACL_handleNewSession()
          else
            ; Keep cursor in place so it lands on the next session.
            ACL_renderSessionPicker(?selectIdx ACL_sessionPickerSelIdx)))))))

procedure(ACL_handlePickerRestore()
  ; Open the selected session: New, Restore-on-same-board, or
  ; Fork-from-another-board. Closes the picker before handing off.
  ; ACL_activeEntry was already updated by the modelchoice callback
  ; when the user picked a model; persist it for new sessions.
  letseq(((newRow ACL_selectedIsNewSession())
          (sid if(newRow nil ACL_selectedSessionSid()))
          (info when(sid ACL_getSession(sid)))
          (board when(info or(ACL_jGet(info "board") ""))))
    when(newRow
      ACL_saveSettings(ACL_settingsFile ACL_currentSettings()))
    axlFormClose(ACL_sessionPickerForm)
    ACL_sessionPickerForm = nil
    cond(
      (newRow ACL_handleNewSession())
      (and(sid info)
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

procedure(ACL_lockSessionModel(info)
  ; Pin ACL_activeEntry to the model the session was started with.
  ; Returns t on success, nil if the recorded model is no longer in
  ; the registry. Caller must abort the restore/fork on nil -- we
  ; can't silently fall back because a session is bound to its driver
  ; (claude can't pick up a codex thread id and vice versa).
  letseq(((want ACL_sessionModel(info))
          (entry and(ACL_nonEmpty(want) ACL_modelById(want))))
    when(entry
      ACL_activeEntry = entry
      t)))

procedure(ACL_handleNewSession()
  ACL_sessionId = nil
  ; Drop the previous session's dir so logFileAppend buffers into
  ; logUnflushed until the init handler assigns the new sid's dir.
  ; Otherwise the "Starting new session..." line and any warnings
  ; here land in the OLD session's log.txt while the agent is launching.
  ACL_sessionLogDir = ACL_logDir
  ACL_sessionSaved = nil
  ACL_sessionUserMsgSeen = nil
  ACL_pendingForkName = nil
  ACL_logReset()
  ACL_startAgent()
  ACL_appendChat("Starting new session...")
  ACL_setStatus("Starting...")
  ; Documentation handling: the cached doc (if it exists) is loaded
  ; into the system prompt by ACL_startAgent via --append-system-prompt-file,
  ; so we don't need to ask the agent to read it at runtime. If no cache
  ; exists, point the user at the external builder. Skip this hint when
  ; the active model can't host the cache anyway -- the warning would
  ; just be noise. (The cache is useful even on small-context models
  ; as an MCP-readable grep target, so we hint as long as fast mode
  ; is off.)
  unless(ACL_fast let((doc installRoot)
    doc = ACL_findOrPlanDocs()
    unless(isFile(doc)
      installRoot = ACL_axlGetPath("allegro_install_root")
      ACL_appendChat(ACL_replacePaths(strcat(
        "No Allegro documentation cache exists for this version. Without one, "
        "responses are less accurate.\n\n"
        "Generate it from a regular shell (outside Allegro):\n"
        "  python3 " ACL_scriptDir "../cache_builder/build_doc_cache.py \\\n"
        "    --install-root " installRoot " \\\n"
        "    --out " doc "\n\n"
        "The build runs unsupervised for a few hours and costs $1.2k+ in tokens. "
        "The cache will be loaded automatically on your next session.\n\n"
        "If you already have a pre-built cache file, place it at any of:\n"
        "  $ALLEGRO_CLAUDE_NOTES\n"
        "  $ALLEGRO_PCBENV\n"
        "  $ALLEGRO_SITE  (recommended)\n"
        "  " ACL_scriptDir "\n"
        "named " ACL_basename(doc) " or " pcreReplace(ACL_hotfixStripRe ACL_basename(doc) ".md" 0) ".\n\n"
        "To stop seeing this prompt, set ACL_fast = t\n"))))))
  ACL_sendMessage(sprintf(nil "Current board: %L\nSay hello" axlGetDrawingName())
    ?isSynthetic t))

procedure(ACL_handleRestoreSession(sid)
  letseq(((info ACL_getSession(sid))
          (modelOk and(info ACL_lockSessionModel(info))))
    cond(
      (null(info)
        ; Session not in our sessions.json -- nothing to restore.
        ACL_handleNewSession())
      (null(modelOk)
        ; Session was started with a model the current registry no
        ; longer knows about. We can't safely substitute -- the
        ; underlying driver might not be a match. Refuse and start
        ; fresh, surfacing why so the user can fix their config.
        letseq(((want or(ACL_sessionModel(info) "?")))
          ACL_handleNewSession()
          ACL_appendChat(sprintf(nil
            "\n[Session was started with model %L, which is not in the current registry. Started a new session instead. Restore the model in ACL_extraModels (see plans/site-model-overrides.md) if you want to keep using it.]\n"
            want))))
      (t
        ACL_sessionId = sid
        ACL_sessionLogDir = strcat(ACL_logDir ACL_sessionId "/")
        ACL_sessionSaved = t
        ACL_sessionUserMsgSeen = t
        ACL_logReset()
        ACL_logLoadFromFile()
        ACL_refreshLogButtons()
        ACL_applySettings(or(
          ACL_loadSettings(strcat(ACL_sessionLogDir "settings.json"))
          ACL_loadSettings(ACL_settingsFile)
          nil))
        ; Re-lock the model in case applySettings stomped on it.
        ACL_lockSessionModel(info)
        ACL_startAgent(sid)
        ; If the agent rejected the resume id, the stderr handler has
        ; already cleared ACL_sessionId. Recover into a fresh session
        ; instead of leaving the user staring at a blank dialog.
        if(null(ACL_sessionId) then
          ACL_handleNewSession()
        else
          letseq(((name ACL_sessionName(info))
                  (label if(name strcat("\"" name "\" (" sid ")") sid)))
            ACL_appendChat(strcat(
              "\n\nRestored session: " label "\n"
            "Continuing the conversation from where you left off on this board.\n"
            "If you want to start fresh, use the Session... button and choose 'New session'.")
            ?toFile nil))
        ACL_setStatus(ACL_readyStatus()))))))

procedure(ACL_handleForkSession(sid)
  prog((info oldBoard)
    info = ACL_getSession(sid)
    unless(info
      ACL_appendChat(sprintf(nil "Session not found: %s" sid))
      return(nil))
    ; Fork requires the parent's model to still be in the registry --
    ; a codex thread can't be forked from claude (and vice versa).
    ; Refuse and start fresh, surfacing why.
    unless(ACL_lockSessionModel(info)
      letseq(((want or(ACL_sessionModel(info) "?")))
        ACL_handleNewSession()
        ACL_appendChat(sprintf(nil
          "\n[Cannot fork: source session uses model %L, which is not in the current registry. Started a new session instead. Restore the model in ACL_extraModels (see plans/site-model-overrides.md) if you want to keep using it.]\n"
          want))
        return(nil)))
    oldBoard = or(ACL_jGet(info "board") "unknown")
    ; Seed sessionId with the parent so init can find the parent log
    ; dir to copy. Cleared sessionSaved makes the fork register under
    ; the CURRENT board on first text. pendingForkName carries the name.
    ; Reset sessionLogDir so pre-init chat lines (Forked message,
    ; target-board sendMessage) buffer rather than landing in parent.
    ACL_pendingForkName = ACL_sessionName(info)
    ACL_sessionId = sid
    ACL_sessionLogDir = ACL_logDir
    ACL_sessionSaved = nil
    ; A fork is user-initiated on the new board; the target-board
    ; sendMessage below counts as the real-input trigger so the fork's
    ; sessions.json entry can land on first reply.
    ACL_sessionUserMsgSeen = t
    ; Parent's model already locked above; ACL_lockSessionModel is
    ; idempotent so no need to re-call.
    ACL_logReset()
    ACL_startAgent(sid t)
    ; Stderr handler clears sessionId if the agent rejected the resume.
    if(null(ACL_sessionId) then
      ACL_handleNewSession()
    else
      ACL_responseBuf = ""
      ACL_appendChat(strcat("\n\nForked from session: "
        letseq(((name ACL_sessionName(info)))
          if(name strcat("\"" name "\" (" sid ")") sid)) "\n"
        "Continuing the conversation from where you left off on that other board."))
      ACL_sendMessage(sprintf(nil
        "The target board has changed from \"%s\" to \"%s\". Disregard any previous design-specific information and re-query the new design as needed."
        oldBoard axlGetDrawingName())
        ?isSynthetic t))))

; ============================================================
; 14. Open Panel & Registration
; ============================================================

procedure(ACL_openPanel(@rest args)
  prog((prompt)
    ; Any args become the initial prompt: typing `claude show me the netlist`
    ; opens the dialog with that text pre-populated and sends it.
    prompt = if(args buildString(args " ") "")
    when(ACL_formIsAlive(ACL_form)
      when(strlen(prompt) > 0
        axlFormSetField(ACL_form "userinput" prompt)
        ACL_doSend(ACL_form))
      return(t))
    ACL_form = nil
    ACL_form = axlFormCreate('ACL_form strcat(ACL_scriptDir "allegro_claude.form")
                             nil 'ACL_formCB t t)
    unless(ACL_form
      printf("*Warning* ACL: axlFormCreate returned nil; reload may have left a stale handle.\n"))
    when(ACL_form
      axlFormDefaultButton(ACL_form "send")
      ACL_applySettings(ACL_loadSettings(ACL_settingsFile))
      axlFormSetField(ACL_form "mode" ACL_mode)
      axlFormSetField(ACL_form "loglines" sprintf(nil "%d" ACL_logLineLimit))
      axlFormSetField(ACL_form "statuslabel" "Starting...")
      ACL_refreshLogButtons()
      axlFormDisplay(ACL_form)
      axlFormSetActiveField(ACL_form "userinput")
      if(ACL_sessionId then
        ACL_ensureAgent()
        ; Redisplay existing log and status after window reopen
        when(ACL_logContent
          axlFormSetField(ACL_form "chatlog"
            ACL_logTail(ACL_logLineLimit)))
        ACL_setStatus(if(and(ACL_proc ipcIsAliveProcess(ACL_proc))
          ACL_readyStatus() "Starting..."))
      else
        letseq(((board axlGetDrawingName())
                (sessions when(board ACL_getBoardSessions(board))))
          ; Auto-resume the most recent session for this board, if any.
          ; If the session id is stale, the stderr handler clears it and
          ; the next user action starts fresh via ACL_ensureAgent.
          if(sessions then
            ACL_handleRestoreSession(car(car(ACL_sortSessionsByTime(sessions))))
          else
            ACL_handleNewSession())))
      ; If a prompt was given on the command line, send it after setup.
      when(strlen(prompt) > 0
        axlFormSetField(ACL_form "userinput" prompt)
        ACL_doSend(ACL_form)))))

axlCmdRegister("claude" 'ACL_openPanel ?cmdType "general")
regExitBefore('ACL_stopAgent)

