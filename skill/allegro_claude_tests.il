; SPDX-FileCopyrightText: (C) 2026 Meta Platforms Inc.
; SPDX-License-Identifier: Apache-2.0
;
; allegro_claude_tests.il -- regression suite for allegro_claude.il
;
; Load this file from a SKILL prompt to run the entire suite. Tests
; execute immediately (no procedure wrapper); the load() call IS the
; test run. Results print to stdout in the form "PASS: <name>" /
; "FAIL: <name>" with a "=== Results: <p> passed, <f> failed ===" line
; at the end.
;
;   load(".../skill/allegro_claude.il")           ; driver under test
;   load(".../skill/allegro_claude_tests.il")     ; runs the suite
;
; allegro_claude.il must already be loaded -- the tests assume every
; ACL_* symbol it defines is available.

; Append (driver-label modelId path-probe-shell-cmd) triples here in
; test.il (or any site test-harness ilinit) to exercise extra drivers
; in the round-trip test. Empty by default.
ACL_defOpt(ACL_extraTestSpecs nil)

; Driver labels to skip in the per-driver round-trip section. Sites
; running close to the daemon's wall-clock budget can drop slow
; built-ins (`'("claude" "codex")`) to focus the run on the entries
; they added via ACL_extraTestSpecs.
ACL_defOpt(ACL_roundTripSkip nil)

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

ACL_testPass = 0
ACL_testFail = 0

; Quarantine sessions.json for the whole test run -- both the
; specific Sessions tests and the e2e agent tests (which set
; ACL_sessionUserMsgSeen=t to exercise ACL_maybeSaveSession) would
; otherwise scribble on the user's real sessions file. Restored
; below the final results line.
ACL_testSavedSessionsFile = ACL_sessionsFile
ACL_sessionsFile = strcat(ACL_homeDir "sessions_test_run.json")
errset(deleteFile(ACL_sessionsFile))

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
; Non-numeric tokens starting with `-` (e.g. CLI help text like `-h`,
; `--print-logs`) must NOT throw "unbound variable" via evalstring.
ACL_check("bad token: -h"             ACL_jParse("-h")             nil)
ACL_check("bad token: --print-logs"   ACL_jParse("--print-logs")   nil)
ACL_check("bad token: -hello world"   ACL_jParse("-hello world")   nil)

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
  ; Reader-only syntax pre-flight: stray paren, missing close, and
  ; unterminated string all fail with the reason in the message
  ; (matches the format used elsewhere: "syntax check failed: ...").
  let(((r ACL_execBlock("(plus 1 2)))")))
    ACL_checkTrue("exec syntax: extra close detected"
      pcreMatchp("syntax check failed" r)))
  let(((r ACL_execBlock("(plus 1 2")))
    ACL_checkTrue("exec syntax: missing close detected"
      pcreMatchp("syntax check failed" r))
    ACL_checkTrue("exec syntax: reader line surfaced"
      pcreMatchp("at line \\d+" r)))
  let(((r ACL_execBlock("(setq x \"open")))
    ACL_checkTrue("exec syntax: unterm string detected"
      pcreMatchp("syntax check failed" r))
    ACL_checkTrue("exec syntax: unterm string line surfaced"
      pcreMatchp("at line \\d+" r)))
  ; Hard parse errors (parser raises rather than auto-recovers --
  ; e.g. empty RHS) must also report the line/column, not just the
  ; generic "syntax error".
  let(((r ACL_execBlock("let((x)\n  x =\n)")))
    ACL_checkTrue("exec syntax: hard parse error detected"
      pcreMatchp("syntax check failed" r))
    ACL_checkTrue("exec syntax: hard parse error has line/column"
      pcreMatchp("line \\d+ column \\d+" r)))
  ; And critically: a syntax failure must not have executed any of
  ; the earlier forms in the block.
  ACL_execSynProbe = 'untouched
  ACL_execBlock("ACL_execSynProbe = 'ran\n(plus 1 2")
  ACL_check("exec syntax: nothing ran on failure"
    ACL_execSynProbe 'untouched)
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
  ACL_checkTrue("ipc success: no .err sidecar"
    null(isFile(strcat(ACL_sessionLogDir "tool_toolu_a.err"))))
  ; Error result must drop an empty .err sidecar so the MCP server
  ; can set isError=true on the JSON-RPC response.
  ACL_handleToolCall(list(list("id" "toolu_err") list("name" "mcp__allegro__allegro_execute")
                          list("input" list(list("code" "let((x)\n  x =\n)")))))
  ACL_mcpDrainPending()
  ACL_checkTrue("ipc err: .err sidecar present"
    isFile(strcat(ACL_sessionLogDir "tool_toolu_err.err")))
  ACL_check("ipc err: .err sidecar is empty marker"
    ACL_readFile(strcat(ACL_sessionLogDir "tool_toolu_err.err")) "")
  ACL_checkTrue("ipc err: .out still has the message"
    pcreMatchp("syntax check failed"
      ACL_readFile(strcat(ACL_sessionLogDir "tool_toolu_err.out"))))
  ; Direct helper coverage so future tool branches stay in sync.
  ACL_check("isError: bare *error*"
    ACL_toolResultIsError("*error* something broke") t)
  ACL_check("isError: SKILL *Error*"
    ACL_toolResultIsError("*Error* lineread/read: ...") t)
  ACL_check("isError: success ignored"
    ACL_toolResultIsError("Result: 42") nil)
  ACL_check("isError: non-string"
    ACL_toolResultIsError(nil) nil)
  ; Block missing required fields is ignored
  ACL_handleToolCall(list(list("name" "mcp__allegro__allegro_execute")
                          list("input" list(list("code" "(plus 9 9)")))))
  ACL_check("missing id ignored" ACL_mcpPending nil)
  ; ACL_mcpScanMaxSeq finds the highest existing N
  ACL_check("scan max seq sees existing"
    ACL_mcpScanMaxSeq(ACL_sessionLogDir) 4)
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

  ; Manual mode: syntax-broken allegro_execute must NOT enter the
  ; approval queue -- it fails the same way regardless, so reject it
  ; up front and skip the user's approval cost.
  let(((savedMode ACL_mode))
    ACL_mode = "manual"
    ACL_mcpPending = nil
    ACL_mcpExecTimer = nil
    ACL_handleToolCall(list(list("id" "toolu_manual_synbad")
                            list("name" "mcp__allegro__allegro_execute")
                            list("input" list(list("code" "(plus 1 2")))))
    ACL_check("manual syn: not queued" ACL_mcpPending nil)
    ACL_check("manual syn: no timer armed" ACL_mcpExecTimer nil)
    ACL_checkTrue("manual syn: .out written immediately"
      isFile(strcat(ACL_sessionLogDir "tool_toolu_manual_synbad.out")))
    ACL_checkTrue("manual syn: .err sidecar present"
      isFile(strcat(ACL_sessionLogDir "tool_toolu_manual_synbad.err")))
    ACL_checkTrue("manual syn: .out has syntax-error text"
      pcreMatchp("syntax check failed"
        ACL_readFile(strcat(ACL_sessionLogDir "tool_toolu_manual_synbad.out"))))
    ; Valid syntax still queues for approval -- guard against the
    ; bypass over-applying.
    ACL_handleToolCall(list(list("id" "toolu_manual_synok")
                            list("name" "mcp__allegro__allegro_execute")
                            list("input" list(list("code" "(plus 1 2)")))))
    ACL_check("manual syn: valid still queued" length(ACL_mcpPending) 1)
    ; .req must land at queue time so the codex MCP-server's content
    ; matcher can correlate while the call still sits in the manual
    ; approval queue (otherwise it would time out before approval).
    ACL_checkTrue("manual syn: queued .req present at queue time"
      isFile(strcat(ACL_sessionLogDir "tool_toolu_manual_synok.req")))
    ACL_check("manual syn: queued .out NOT yet written"
      isFile(strcat(ACL_sessionLogDir "tool_toolu_manual_synok.out")) nil)
    ACL_mcpPending = nil
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

printf("\n--- read_file offset/length/is_binary + cap ---\n")
let(((tmpDir strcat(ACL_homeDir "readfile_test/"))
     (savedCap ACL_maxReadBytes))
  ACL_createDirP(tmpDir)
  ; Create a multi-line file: 10 lines, each "lineNN\n" = 7 bytes.
  let(((p strcat(tmpDir "lines.txt"))
       (fp nil))
    fp = outfile(p)
    for(i 1 10 fprintf(fp "line%02d\n" i))
    close(fp)
    ; Default: first 2000 lines -> the whole 10-line file.
    ACL_check("read_file lines: default reads whole small file"
      ACL_toolReadFile(p 0 2000 nil)
      "line01\nline02\nline03\nline04\nline05\nline06\nline07\nline08\nline09\nline10\n")
    ; offset=3 length=2: lines 4 and 5.
    ACL_check("read_file lines: offset+length window"
      ACL_toolReadFile(p 3 2 nil)
      "line04\nline05\n")
    ; offset past EOF: empty result.
    ACL_check("read_file lines: offset past EOF"
      ACL_toolReadFile(p 100 5 nil)
      "")
    ; is_binary: byte offsets. Bytes 0-6 = "line01\n".
    ACL_check("read_file binary: first 7 bytes"
      ACL_toolReadFile(p 0 7 t)
      "line01\n")
    ; offset=7 length=7 = second line.
    ACL_check("read_file binary: offset 7 length 7"
      ACL_toolReadFile(p 7 7 t)
      "line02\n")
    ; Validation: negative offset.
    ACL_checkTrue("read_file: negative offset rejected"
      pcreMatchp("offset must be"
        ACL_toolReadFile(p -1 10 nil)))
    ; Validation: zero length.
    ACL_checkTrue("read_file: zero length rejected"
      pcreMatchp("length must be"
        ACL_toolReadFile(p 0 0 nil)))
    ; Cap: shrink to a tiny cap, then exercise it.
    ACL_maxReadBytes = 14   ; just two lines worth
    ACL_check("read_file lines: under-cap reads succeed"
      ACL_toolReadFile(p 0 2 nil)
      "line01\nline02\n")
    ACL_checkTrue("read_file lines: over-cap returns error"
      pcreMatchp("would exceed"
        ACL_toolReadFile(p 0 5 nil)))
    ACL_checkTrue("read_file lines: cap error mentions file size"
      pcreMatchp("file size 70 bytes"
        ACL_toolReadFile(p 0 5 nil)))
    ; Binary: length-> bytes; over-cap fails up-front.
    ACL_checkTrue("read_file binary: over-cap rejected"
      pcreMatchp("requested 100 bytes but cap is 14"
        ACL_toolReadFile(p 0 100 t)))
    ; Missing file (validateFilePath path).
    ACL_checkTrue("read_file: missing path"
      pcreMatchp("not a file"
        ACL_toolReadFile(strcat(tmpDir "nope.txt") 0 2000 nil))))
  ; Dispatch through the MCP tool path uses default offset/length/binary.
  let(((p strcat(tmpDir "lines.txt"))
       (savedCap2 ACL_maxReadBytes))
    ACL_maxReadBytes = 20480  ; back to default-ish so MCP path returns
    ACL_check("read_file via runTool: defaults yield whole file"
      ACL_runTool("mcp__allegro__allegro_read_file" list(list("path" p)))
      "line01\nline02\nline03\nline04\nline05\nline06\nline07\nline08\nline09\nline10\n")
    ACL_check("read_file via runTool: explicit offset/length"
      ACL_runTool("mcp__allegro__allegro_read_file"
        list(list("path" p) list("offset" 2) list("length" 1)))
      "line03\n")
    ACL_check("read_file via runTool: is_binary"
      ACL_runTool("mcp__allegro__allegro_read_file"
        list(list("path" p) list("offset" 0) list("length" 4)
             list("is_binary" t)))
      "line"))
  ; Cleanup
  ACL_maxReadBytes = savedCap
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

printf("\n--- Model registry (JSON dict + extras + placement) ---\n")
let(((savedExtra ACL_extraModels) (savedBuiltins ACL_useBuiltinModels))
  ; Built-ins parse and have the expected ids.
  ACL_extraModels = ""
  ACL_useBuiltinModels = t
  ACL_checkTrue("registry: parsed built-ins"
    and(ACL_modelById("opus-1m") ACL_modelById("gpt-5-5")))
  ACL_check("registry: no surprise built-ins"
    ACL_modelById("does-not-exist") nil)
  ACL_check("registry: built-in has expected label"
    ACL_entryLabel(ACL_modelById("gpt-5-5")) "Codex GPT-5.5")
  ; Site can append new entries via ACL_extraModels.
  ACL_extraModels = "{'site-local':{'label':'Site Local','driver':'claude',
                                    'model':'x','context':1000}}"
  ACL_checkTrue("registry: site extra appended"
    ACL_modelById("site-local"))
  ; A site entry whose id matches a built-in replaces it (and a
  ; bare lookup by id finds the override's fields, not the builtin's).
  ACL_extraModels = "{'gpt-5-5':{'label':'Codex Override','driver':'codex',
                                     'model':'override','context':42,
                                     'args':'--with-proxy http://override.example/'}}"
  let(((e ACL_modelById("gpt-5-5")))
    ACL_check("registry: override model"
      ACL_entryField(e "model") "override")
    ACL_check("registry: override context"
      ACL_entryField(e "context") 42)
    ACL_check("registry: override args"
      ACL_entryField(e "args") "--with-proxy http://override.example/")
    ACL_check("registry: override label"
      ACL_entryLabel(e) "Codex Override")
    ; Built-in entries carry an effort string the launchers pick up.
    ACL_check("registry: built-in effort field"
      ACL_entryField(ACL_modelById("opus-1m") "effort") "max"))
  ; Built-in entries before the override are preserved.
  ACL_checkTrue("registry: built-ins preserved alongside override"
    ACL_modelById("opus-1m"))
  ; Standard JSON with literal `"` quotes still parses.
  ACL_extraModels = "{\"std-json\":{\"label\":\"Std JSON\",\"driver\":\"claude\",
                                     \"model\":\"y\",\"context\":2000}}"
  ACL_checkTrue("registry: literal-quote JSON still works"
    ACL_modelById("std-json"))
  ; Malformed JSON: warn, skip extras, keep built-ins.
  ACL_extraModels = "{not valid json}"
  ACL_checkTrue("registry: malformed extras dropped, built-ins kept"
    ACL_modelById("opus-1m"))
  ; Bare entries without surrounding {} are accepted so site ilinits
  ; can concatenate fragments without each one balancing braces.
  ACL_useBuiltinModels = 'last
  ACL_extraModels = "'unwrapped':{'label':'Unwrapped','driver':'claude',
                                  'model':'u','context':500}"
  ACL_checkTrue("registry: bare entries auto-wrapped"
    ACL_modelById("unwrapped"))
  ACL_extraModels = "   \n'multi-a':{'label':'A','driver':'claude','model':'a','context':500},
                        'multi-b':{'label':'B','driver':'claude','model':'b','context':500}\n   "
  ACL_checkTrue("registry: bare multi-entry, whitespace tolerated, A"
    ACL_modelById("multi-a"))
  ACL_checkTrue("registry: bare multi-entry, whitespace tolerated, B"
    ACL_modelById("multi-b"))
  ; ACL_useBuiltinModels = nil suppresses built-ins entirely.
  ACL_useBuiltinModels = nil
  ACL_extraModels = "{'only':{'label':'Only','driver':'claude',
                              'model':'x','context':500}}"
  ACL_check("registry: nil hides built-ins"
    ACL_modelById("opus-1m") nil)
  ACL_checkTrue("registry: nil keeps extras"
    ACL_modelById("only"))
  ACL_check("registry: nil default is extras' first entry"
    car(ACL_defaultModelEntry()) "only")
  ; Placement: 'last (the default) puts user entries first, built-ins
  ; after. The default model entry should come from the user list.
  ACL_useBuiltinModels = 'last
  ACL_extraModels = "{'site-first':{'label':'Site First','driver':'claude',
                                    'model':'x','context':1000}}"
  ACL_check("registry: 'last makes user the default entry"
    car(ACL_defaultModelEntry()) "site-first")
  ACL_checkTrue("registry: 'last still keeps built-ins available"
    ACL_modelById("opus-1m"))
  ; Placement: t puts built-ins first; default reverts to the first
  ; built-in entry even when extras exist.
  ACL_useBuiltinModels = t
  ACL_check("registry: t makes the first built-in the default"
    car(ACL_defaultModelEntry()) "opus-1m")
  ; User override always wins on id collision, regardless of order.
  ACL_extraModels = "{'opus-1m':{'label':'My Opus','driver':'claude',
                                 'model':'x','context':1000}}"
  ACL_useBuiltinModels = 'last
  ACL_check("registry: user wins on collision ('last)"
    ACL_entryLabel(ACL_modelById("opus-1m")) "My Opus")
  ACL_useBuiltinModels = t
  ACL_check("registry: user wins on collision (t)"
    ACL_entryLabel(ACL_modelById("opus-1m")) "My Opus")
  ACL_useBuiltinModels = savedBuiltins
  ACL_extraModels = savedExtra)

printf("\n--- Stale-model handling on session restore ---\n")
let(((savedActive ACL_activeEntry)
     (defaultId car(ACL_defaultModelEntry())))
  ; lockSessionModel returns t on known model and locks active entry.
  ACL_activeEntry = nil
  ACL_check("lock: known model returns t"
    ACL_lockSessionModel(list(list("model" defaultId))) t)
  ACL_check("lock: active entry pinned"
    car(ACL_activeEntry) defaultId)
  ; lockSessionModel returns nil when model is missing; does NOT
  ; mutate activeEntry. Caller is responsible for the user-visible
  ; refusal -- a session is bound to its driver, so a silent swap
  ; would break the restore.
  ACL_activeEntry = nil
  ACL_check("lock: missing model returns nil"
    ACL_lockSessionModel(list(list("model" "no-such-id-12345"))) nil)
  ACL_check("lock: active entry untouched"
    ACL_activeEntry nil)
  ACL_activeEntry = savedActive)

printf("\n--- Doc cache gating by context-window ratio ---\n")
let(((savedActive ACL_activeEntry) (savedFast ACL_fast)
     (savedRatio ACL_docCacheRatio)
     big small unknown)
  big     = list("big" list(list("driver" "claude")
                            list("model" "x") list("context" 1000000)))
  small   = list("small" list(list("driver" "claude")
                              list("model" "x") list("context" 200000)))
  unknown = list("unknown" list(list("driver" "claude")
                                list("model" "x")))
  ACL_docCacheRatio = 1.8
  ; 1.5MB cache vs 1M-token context -> 1.5 bytes/token <= 1.8 -> fits.
  ACL_check("docCacheFits big" ACL_docCacheFits(big 1500000) t)
  ; 1.5MB cache vs 200K-token context -> 7.5 bytes/token > 1.8 -> nope.
  ACL_check("docCacheFits small" ACL_docCacheFits(small 1500000) nil)
  ; Missing context defaults to "yes" so legacy entries don't break.
  ACL_check("docCacheFits unknown -> yes"
    ACL_docCacheFits(unknown 1500000) t)
  ACL_docCacheRatio = savedRatio
  ACL_fast = savedFast
  ACL_activeEntry = savedActive)

printf("\n--- Doc cache truncation (byte budget + section backoff) ---\n")
let((sample bigEnough)
  ; Cache shaped like a reordered output: leading preamble, tier
  ; markers between chapter groups, chapters of `# header` + `### `
  ; entries. Use small chapters and a tight budget so we can predict
  ; which cut wins.
  sample = strcat(
    "<!-- generator preamble -->\n\n"
    "<!-- ACL_TIER_BOUNDARY tier=1 -->\n\n"
    "# chap_one\n"
    "### entry_a `() => t`\nFirst entry body.\n\n"
    "### entry_b `() => t`\nSecond entry body.\n\n"
    "<!-- ACL_TIER_BOUNDARY tier=2 -->\n\n"
    "# chap_two\n"
    "### entry_c `() => t`\nThird entry body.\n\n"
    "<!-- ACL_TIER_BOUNDARY tier=end -->\n")

  ; nil budget -> no cap, return content unchanged + no meta.
  let(((r ACL_truncateDocContent(sample nil)))
    ACL_check("trunc nil-budget: full content"
      car(r) sample)
    ACL_check("trunc nil-budget: no meta"
      cadr(r) nil))

  ; Budget bigger than content -> no truncation.
  let(((r ACL_truncateDocContent(sample 10000)))
    ACL_check("trunc oversize: full content"
      car(r) sample)
    ACL_check("trunc oversize: no meta" cadr(r) nil))

  ; Budget below the first chapter header -> falls back to a chapter
  ; cut at the only `# ` line, dropping the body but keeping the
  ; preamble + chapter header.
  bigEnough = strcat(
    "<!-- preamble line one -->\n"
    "<!-- preamble line two -->\n\n"
    "# chap_solo\n"
    "### entry `() => t`\nA body.\n\n"
    "### entry2 `() => t`\nAnother body.\n")
  let(((budget nindex(bigEnough "### entry2") - 1))
    let(((r ACL_truncateDocContent(bigEnough budget)))
      ACL_checkTrue("trunc chapter: meta present" cadr(r))
      ACL_check("trunc chapter: cutAt is chapter"
        cadr(assoc('cutAt cadr(r))) "chapter")
      ACL_check("trunc chapter: head ends before entry2"
        nindex(car(r) "entry2") nil)))

  ; No chapter header at all; only section markers within prose.
  ; Section cut must win.
  let(((noChap strcat(
          "Just some prose\n"
          "### entry_x `() => t`\nbody x\n"
          "### entry_y `() => t`\nbody y\n"
          "### entry_z `() => t`\nbody z\n"))
       budget r)
    budget = nindex(noChap "entry_y") - 1
    r = ACL_truncateDocContent(noChap budget)
    ACL_checkTrue("trunc section: meta present" cadr(r))
    ACL_check("trunc section: cutAt is section"
      cadr(assoc('cutAt cadr(r))) "section")
    ACL_check("trunc section: head ends before entry_y"
      nindex(car(r) "entry_y") nil))

  ; Note generator wraps the cut location with file size info.
  let(((meta list(list('cutBytes 12345)
                   list('cutLine 678)
                   list('totalBytes 99999)
                   list('totalLines 1234)
                   list('cutAt "chapter"))))
    let(((note ACL_docTruncationNote("/path/to/cache.md" meta)))
      ACL_checkTrue("trunc note: contains path"
        nindex(note "/path/to/cache.md"))
      ACL_checkTrue("trunc note: contains cut bytes"
        nindex(note "12345"))
      ACL_checkTrue("trunc note: contains cut line"
        nindex(note "678"))
      ACL_checkTrue("trunc note: contains total bytes"
        nindex(note "99999"))
      ACL_checkTrue("trunc note: names the boundary"
        nindex(note "chapter"))))
)

printf("\n--- Doc cache budget derivation ---\n")
let(((savedActive ACL_activeEntry) (savedRatio ACL_docCacheRatio))
  ACL_docCacheRatio = 1.8
  ; Active model carries a context; budget = ratio * context (bytes).
  ACL_activeEntry = list("e" list(list("driver" "claude")
                                   list("model" "x")
                                   list("context" 200000)))
  ACL_check("budget: small ctx -> capped"
    ACL_docCacheBudget() 360000)
  ACL_activeEntry = list("e" list(list("driver" "claude")
                                   list("model" "x")
                                   list("context" 1000000)))
  ACL_check("budget: big ctx -> generous"
    ACL_docCacheBudget() 1800000)
  ; Missing context -> nil budget (treat as no cap).
  ACL_activeEntry = list("e" list(list("driver" "claude")
                                   list("model" "x")))
  ACL_check("budget: unknown -> nil"
    ACL_docCacheBudget() nil)
  ACL_docCacheRatio = savedRatio
  ACL_activeEntry = savedActive)

printf("\n--- Long-op progress helpers ---\n")
let(((savedStatus ACL_statusText) (savedActive ACL_progressActive)
     (savedDone ACL_progressDone) (savedTotal ACL_progressTotal)
     (savedLabel ACL_progressLabel) (savedMark ACL_progressMark)
     (savedRO ACL_progressReadOnly) (savedForm ACL_form)
     (savedMode ACL_mode) (savedPending ACL_mcpPending))
  ACL_form = nil  ; setStatus updates ACL_statusText regardless
  ACL_mode = "auto"
  ACL_mcpPending = nil
  ACL_progressActive = nil
  ; Duration formatter
  ACL_check("progress: duration 0s"
    ACL_progressFormatDuration(0) "0s")
  ACL_check("progress: duration 45s"
    ACL_progressFormatDuration(45) "45s")
  ACL_check("progress: duration 90s"
    ACL_progressFormatDuration(90) "1m30s")
  ACL_check("progress: duration 3725s"
    ACL_progressFormatDuration(3725) "1h2m5s")
  ; Zero total -> nil, no state change.
  ACL_check("progress: zero total -> nil"
    ACL_progressBegin("Test" 0 ?readOnly t) nil)
  ACL_check("progress: zero total stays inactive"
    ACL_progressActive nil)
  ; Read-only begin succeeds and seeds state + status.
  ACL_check("progress: readOnly begin -> t"
    ACL_progressBegin("Counting" 10 ?readOnly t) t)
  ACL_checkTrue("progress: begin sets active" ACL_progressActive)
  ACL_check("progress: begin sets total" ACL_progressTotal 10)
  ACL_check("progress: begin sets done=0" ACL_progressDone 0)
  ACL_checkTrue("progress: status reflects label"
    pcreMatchp("Counting" ACL_statusText))
  ACL_checkTrue("progress: status reflects 0/10"
    pcreMatchp("0/10" ACL_statusText))
  ; Tick advances done.
  ACL_progressTick()
  ACL_check("progress: tick increments done" ACL_progressDone 1)
  ACL_progressTick(?count 5)
  ACL_check("progress: tick count advances by N" ACL_progressDone 6)
  ; Nested begin while one is active -> nil.
  ACL_check("progress: nested begin -> nil"
    ACL_progressBegin("Other" 5 ?readOnly t) nil)
  ACL_check("progress: nested begin leaves state intact"
    ACL_progressTotal 10)
  ; End cleanly (?readOnly skipped transaction so commit short-circuits to t).
  ACL_check("progress: end success -> t"
    ACL_progressEnd() t)
  ACL_check("progress: end clears active" ACL_progressActive nil)
  ACL_checkTrue("progress: end status names label and outcome"
    pcreMatchp("Counting: done" ACL_statusText))
  ; Cancelled end -> nil and status names the cancel point.
  ACL_progressBegin("Cleanup" 3 ?readOnly t)
  ACL_progressTick()
  ACL_check("progress: end cancelled -> nil"
    ACL_progressEnd(?cancelled t) nil)
  ACL_checkTrue("progress: end cancelled status"
    pcreMatchp("cancelled at 1/3" ACL_statusText))
  ; Failed count shows up in the final status line.
  ACL_progressBegin("Sweep" 4 ?readOnly t)
  ACL_progressTick()
  ACL_progressEnd(?failed 2)
  ACL_checkTrue("progress: failed count in status"
    pcreMatchp("2 failed" ACL_statusText))
  ; Tick without active context warns and returns nil so callers
  ; that `unless`-gate the loop terminate cleanly.
  ACL_check("progress: stray tick returns nil"
    ACL_progressTick() nil)
  ; Active tick returns t while no cancel has been requested.
  ACL_progressBegin("Loop" 5 ?readOnly t)
  ACL_check("progress: tick returns t while active"
    ACL_progressTick() t)
  ACL_progressEnd()
  ; allegro_execute auto-closes a progress context the agent's code
  ; opened but didn't end (e.g. SKILL error or simple omission), so a
  ; leaked transaction can't leave the panel stuck.
  ACL_runTool("mcp__allegro__allegro_execute"
              list(list("code"
                        "ACL_progressBegin(\"Leaked\" 3 ?readOnly t)")))
  ACL_check("progress: runTool auto-ends leaked context"
    ACL_progressActive nil)
  ACL_checkTrue("progress: auto-end status says cancelled"
    pcreMatchp("Leaked: cancelled" ACL_statusText))
  ; End without active context returns nil cleanly.
  ACL_check("progress: stray end returns nil"
    ACL_progressEnd() nil)
  ; Restore globals so later tests aren't perturbed.
  ACL_progressActive = savedActive
  ACL_progressDone = savedDone
  ACL_progressTotal = savedTotal
  ACL_progressLabel = savedLabel
  ACL_progressMark = savedMark
  ACL_progressReadOnly = savedRO
  ACL_statusText = savedStatus
  ACL_form = savedForm
  ACL_mode = savedMode
  ACL_mcpPending = savedPending)

printf("\n--- Shell quoting (ipcBeginProcess two-pass safe) ---\n")
; ACL_shellQuote must round-trip arbitrary text through ipcBeginProcess
; on Linux, where pass-1 interprets \X and "..." regions BEFORE handing
; to the real sh. Probe by echoing the quoted value through a tiny shell
; command and comparing the captured argv to the input.
let(((savedWin ACL_isWindows))
  ACL_isWindows = nil
  foreach(s list("plain" "has space" "with 'single' quotes"
                 "with \"double\" quotes" "back\\slash" "mix \"\\'all"
                 "key=\"val\"" "")
    letseq(((tmpOut strcat(ACL_homeDir "quote_test.out"))
            (cmd sprintf(nil "printf %%s %s > %s"
                          ACL_shellQuote(s) tmpOut)))
      ipcWait(ipcBeginProcess(cmd "" nil nil nil
                              strcat(ACL_homeDir "quote_test.log")))
      ACL_check(sprintf(nil "shellQuote round-trip %L" s)
        ACL_readFile(tmpOut) s)
      errset(deleteFile(tmpOut))
      errset(deleteFile(strcat(ACL_homeDir "quote_test.log")))))
  ; Windows arg-escape rules (verified shape; cannot exec cmd.exe from
  ; Linux). Per MSVC CRT: backslashes before a " double, the " becomes
  ; \", trailing backslashes (before the wrapping ") double; applied
  ; TWICE to survive both ipcBeginProcess and cmd.exe's tokenizers.
  ; Wrap uses \"...\" (escaped quotes) so ipcBeginProcess's bare-`"`
  ; strip leaves the wrap intact.
  ACL_isWindows = t
  ACL_check("win shellQuote plain"
    ACL_shellQuote("plain") "\\\"plain\\\"")
  ACL_check("win shellQuote space"
    ACL_shellQuote("has space") "\\\"has space\\\"")
  ACL_check("win shellQuote single quote (passthrough)"
    ACL_shellQuote("it's") "\\\"it's\\\"")
  ; "x" -> pass 1: \"x\" (4); pass 2: \\\"x\\\" (8); wrap with \".."\"
  ACL_check("win shellQuote embedded double-quote"
    ACL_shellQuote("\"x\"") "\\\"\\\\\\\"x\\\\\\\"\\\"")
  ; back\slash: no quotes nearby, BS not affected; result is back\slash
  ACL_check("win shellQuote backslash mid-string"
    ACL_shellQuote("back\\slash") "\\\"back\\slash\\\"")
  ; Trailing backslash: must double each pass.
  ACL_check("win shellQuote trailing backslash"
    ACL_shellQuote("path\\") "\\\"path\\\\\\\\\\\"")
  ; ACL_wrapCmd no-ops on Linux, wraps in `cmd /c "..."` on Windows
  ACL_isWindows = nil
  ACL_check("wrapCmd linux passthrough"
    ACL_wrapCmd("foo bar") "foo bar")
  ACL_isWindows = t
  ACL_check("wrapCmd windows wrap"
    ACL_wrapCmd("foo bar") "cmd /c \"foo bar\"")
  ACL_isWindows = savedWin)

printf("\n--- Codex command builder ---\n")
; ACL_codexBuildCmd assembles the codex CLI invocation inline (no
; launcher file). Each `-c key=value` arg must survive the two-pass
; shell handling so codex sees a valid TOML literal.
let(((savedActive ACL_activeEntry) (savedExtra ACL_extraModels)
     (savedBuiltins ACL_useBuiltinModels) (savedTag ACL_sessionTag)
     (savedArgs ACL_codexArgs))
  ACL_useBuiltinModels = nil
  ACL_extraModels = "{'cbtest':{'driver':'codex','model':'x',
                                'effort':'low'}}"
  ACL_activeEntry = ACL_modelById("cbtest")
  ACL_sessionTag = "tag-abc"
  ACL_codexArgs = ""
  let(((cmd ACL_codexBuildCmd("/tmp/mcp.py" "")))
    ACL_checkTrue("codex cmd: has app-server"
      nindex(cmd "app-server"))
    ACL_checkTrue("codex cmd: command TOML preserved across passes"
      nindex(cmd "mcp_servers.allegro.command="))
    ACL_checkTrue("codex cmd: args TOML present"
      nindex(cmd "/tmp/mcp.py"))
    ACL_checkTrue("codex cmd: session tag present"
      nindex(cmd "tag-abc"))
    ACL_checkTrue("codex cmd: effort from registry"
      nindex(cmd "model_reasoning_effort=low"))
    ACL_check("codex cmd: no leftover launcher reference"
      nindex(cmd "codex_launch") nil)
    ; codex's default per-server tool timeout is 300s, but Meta's
    ; environment also caches sub-300s overrides on some servers; we
    ; pin allegro's well past any realistic SKILL call so long
    ; ACL_progress sweeps aren't killed mid-flight.
    ACL_checkTrue("codex cmd: allegro tool_timeout_sec overridden"
      nindex(cmd "mcp_servers.allegro.tool_timeout_sec=10000000")))
  ; Without effort, no -c model_reasoning_effort flag.
  ACL_extraModels = "{'cbtest':{'driver':'codex','model':'x'}}"
  ACL_activeEntry = ACL_modelById("cbtest")
  let(((cmd ACL_codexBuildCmd("/tmp/mcp.py" "")))
    ACL_check("codex cmd: effort absent when unset"
      nindex(cmd "model_reasoning_effort") nil))
  ; Per-entry args (e.g. --with-proxy) land before app-server.
  ACL_extraModels = "{'cbtest':{'driver':'codex','model':'x'}}"
  ACL_activeEntry = ACL_modelById("cbtest")
  let(((cmd ACL_codexBuildCmd("/tmp/mcp.py" "--with-proxy http://p/")))
    ACL_checkTrue("codex cmd: entry args precede app-server"
      let(((proxyPos nindex(cmd "--with-proxy"))
           (asPos nindex(cmd "app-server")))
        and(proxyPos asPos proxyPos < asPos))))
  ACL_codexArgs = savedArgs
  ACL_sessionTag = savedTag
  ACL_useBuiltinModels = savedBuiltins
  ACL_extraModels = savedExtra
  ACL_activeEntry = savedActive)

printf("\n--- Tool prefix substitution ---\n")
let(((savedActive ACL_activeEntry))
  ; Per-driver helper picks the right prefix.
  ACL_check("toolPrefix claude" ACL_toolPrefix("claude") "mcp__allegro__allegro_")
  ACL_check("toolPrefix codex"  ACL_toolPrefix("codex")  "allegro_")
  ; The replacement substitutes everywhere $MCP_ appears.
  ACL_activeEntry = car(setof(e ACL_models()
                              ACL_entryField(e "driver") == "claude"))
  ACL_check("replace $MCP_ (claude)"
    ACL_replacePaths("call $MCP_execute and $MCP_read_file")
    "call mcp__allegro__allegro_execute and mcp__allegro__allegro_read_file")
  ACL_activeEntry = car(setof(e ACL_models()
                              ACL_entryField(e "driver") == "codex"))
  ACL_check("replace $MCP_ (codex)"
    ACL_replacePaths("call $MCP_execute and $MCP_read_file")
    "call allegro_execute and allegro_read_file")
  ; The whole system prompt should contain the rendered prefix once
  ; per occurrence of $MCP_ in PROMPT.md.
  ACL_activeEntry = car(setof(e ACL_models()
                              ACL_entryField(e "driver") == "claude"))
  ACL_checkTrue("buildSystemPrompt embeds claude prefix"
    nindex(ACL_buildSystemPrompt() "mcp__allegro__allegro_execute"))
  ACL_check("buildSystemPrompt has no raw placeholder (claude)"
    nindex(ACL_buildSystemPrompt() "$MCP_") nil)
  ACL_activeEntry = car(setof(e ACL_models()
                              ACL_entryField(e "driver") == "codex"))
  ACL_check("buildSystemPrompt has no raw placeholder (codex)"
    nindex(ACL_buildSystemPrompt() "$MCP_") nil)
  ACL_activeEntry = savedActive)

printf("\n--- Form File ---\n")
letseq(((formPath strcat(ACL_scriptDir "allegro_claude.form"))
        (formHandle axlFormCreate('ACL_testForm formPath nil nil nil)))
  ACL_checkTrue("form parse" formHandle)
  when(formHandle axlFormClose(formHandle)))
letseq(((formPath strcat(ACL_scriptDir "allegro_claude_sessions.form"))
        (formHandle axlFormCreate('ACL_testSessForm formPath nil nil nil)))
  ACL_checkTrue("sessions form parse" formHandle)
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
     (savedClaudeArgs ACL_claudeArgs)
     (savedCodexArgs ACL_codexArgs)
     (savedActive ACL_activeEntry))
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
  ACL_codexArgs = ""
  ACL_activeEntry = ACL_defaultModelEntry()
  ACL_check("currentSettings" ACL_currentSettings()
    list(list("mode" "quiet")
         list("fast" 'false)
         list("claudeArgs" "")
         list("codexArgs" "")
         list("model" car(ACL_defaultModelEntry()))))
  ; applySettings updates ACL_mode
  ACL_applySettings(list(list("mode" "manual")))
  ACL_check("applySettings" ACL_mode "manual")
  ; claudeArgs round-trips
  ACL_applySettings(list(list("claudeArgs" "--debug api,hooks")))
  ACL_check("applySettings claudeArgs" ACL_claudeArgs "--debug api,hooks")
  ; codexArgs round-trips
  ACL_applySettings(list(list("codexArgs" "--verbose")))
  ACL_check("applySettings codexArgs" ACL_codexArgs "--verbose")
  ; model id resolves through the registry
  let(((secondId car(cadr(ACL_models()))))
    ACL_applySettings(list(list("model" secondId)))
    ACL_check("applySettings model" car(ACL_activeEntry) secondId))
  ; Unknown model falls back to the first entry.
  ACL_applySettings(list(list("model" "no-such-id-12345")))
  ACL_check("applySettings model unknown -> default"
    car(ACL_activeEntry) car(ACL_defaultModelEntry()))
  ; Load nonexistent file returns nil
  ACL_check("load missing" ACL_loadSettings("/tmp/nonexistent_acl_test.json") nil)
  ; Cleanup
  deleteFile(tmpFile)
  ACL_activeEntry = savedActive
  ACL_codexArgs = savedCodexArgs
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

printf("\n--- Session names ---\n")
let(((savedFile ACL_sessionsFile) (savedLogDir ACL_logDir)
     (savedSid ACL_sessionId)
     tmpDir lbl1 lbl2 lbl3 sample dir)
  ACL_sessionsFile = strcat(ACL_homeDir "sessions_name_test.json")
  tmpDir = strcat(ACL_homeDir "logs_name_test/")
  ACL_createDirP(tmpDir)
  ACL_logDir = tmpDir
  sample = list(
    list("named-sid" list(list("board" "/tmp/x.brd") list("time" "100")
                          list("name" "my favourite")))
    list("plain-sid" list(list("board" "/tmp/y.brd") list("time" "200"))))
  ACL_saveSessions(sample)
  ACL_check("name field read back"
    ACL_sessionName(ACL_getSession("named-sid")) "my favourite")
  ACL_check("name absent -> nil"
    ACL_sessionName(ACL_getSession("plain-sid")) nil)
  ACL_setSessionName("plain-sid" "renamed")
  ACL_check("setSessionName persists"
    ACL_sessionName(ACL_getSession("plain-sid")) "renamed")
  ACL_setSessionName("plain-sid" "")
  ACL_check("blank clears name"
    ACL_sessionName(ACL_getSession("plain-sid")) nil)
  ACL_setSessionName("no-such-sid" "ignored")
  ACL_check("no entry created for missing sid"
    assoc("no-such-sid" ACL_loadSessions()) nil)
  lbl1 = ACL_sessionLabel("named-sid" ACL_getSession("named-sid"))
  ACL_checkTrue("label uses name when set"
    nindex(lbl1 "my favourite"))
  lbl2 = ACL_sessionLabel("plain-sid" ACL_getSession("plain-sid"))
  ACL_checkTrue("label falls back to uuid prefix"
    nindex(lbl2 "plain-si"))
  lbl3 = ACL_sessionLabel("named-sid" ACL_getSession("named-sid")
                           ?currentSid "named-sid")
  ACL_checkTrue("label marks current"
    nindex(lbl3 "(current)"))
  dir = strcat(ACL_logDir "named-sid/")
  ACL_createDirP(dir)
  ACL_writeFile(strcat(dir "log.txt") "old log\n")
  ACL_writeFile(strcat(dir "cmd_1.il") "(plus 1 1)")
  ACL_deleteSessionFiles("named-sid")
  ACL_check("deleteSessionFiles removes dir" isDir(dir) nil)
  ACL_deleteSessionFiles("no-dir-sid")
  ACL_check("deleteSessionFiles no-op on missing dir" t t)
  deleteFile(ACL_sessionsFile)
  when(isDir(tmpDir) deleteDir(tmpDir))
  ACL_sessionsFile = savedFile
  ACL_logDir = savedLogDir
  ACL_sessionId = savedSid)

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

printf("\n--- Session tag handshake ---\n")
let(((savedSid ACL_sessionId) (savedLogDir ACL_sessionLogDir)
     (savedTag ACL_sessionTag) (savedWritten ACL_sessionTagWritten)
     sid logDir tagPath)
  sid = "tag-handshake-test"
  logDir = strcat(ACL_logDir sid "/")
  tagPath = strcat(logDir "acl_tag")
  errset(deleteFile(tagPath))
  errset(deleteDir(logDir))
  let(((t1 ACL_makeSessionTag()))
    ACL_checkTrue("tag: nonempty" and(stringp(t1) strlen(t1) > 0)))
  ; Init lands the tag in the per-session dir.
  ACL_sessionTag = "acl-test-tag-handshake"
  ACL_sessionTagWritten = nil
  ACL_sessionId = nil
  ACL_sessionLogDir = ACL_logDir
  ACL_processStreamLine(sprintf(nil
    "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"%s\"}" sid))
  ACL_check("tag: file written" isFile(tagPath) t)
  ACL_check("tag: file contents match" ACL_readFile(tagPath) ACL_sessionTag)
  ACL_check("tag: written flag set" ACL_sessionTagWritten t)
  ; Second init (resume) is a no-op -- writeSessionTag short-circuits.
  ACL_writeFile(tagPath "")
  ACL_processStreamLine(sprintf(nil
    "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"%s\"}" sid))
  ACL_check("tag: idempotent on second init" ACL_readFile(tagPath) "")
  errset(deleteFile(tagPath))
  errset(deleteDir(logDir))
  ACL_sessionTagWritten = savedWritten
  ACL_sessionTag = savedTag
  ACL_sessionLogDir = savedLogDir
  ACL_sessionId = savedSid)

printf("\n--- Codex session lifecycle ---\n")
; Drive ACL_codexProcessLine with synthetic JSON-RPC messages and
; verify session-id capture, log-dir bootstrap, tag handshake, fork
; file-copy, and resume-without-rewrite path. No real codex process
; involved.
let(((savedSid ACL_sessionId) (savedLogDir ACL_sessionLogDir)
     (savedFile ACL_sessionsFile) (savedTag ACL_sessionTag)
     (savedWritten ACL_sessionTagWritten) (savedSeq ACL_mcpCmdSeq)
     (savedFork ACL_resumeIsFork) (savedThreadId ACL_codexThreadId)
     (savedThreadStarted ACL_codexThreadStarted)
     (savedResumeId ACL_codexResumeId)
     (savedResumeFork ACL_codexResumeIsFork)
     (savedActive ACL_activeEntry)
     sid newDir parentDir)
  ACL_sessionsFile = strcat(ACL_homeDir "codex_sessions_test.json")
  ; --- Fresh session: thread/started captures id + bootstraps dir ---
  sid = "019e0000-fresh-7000-0000-000000000001"
  newDir = strcat(ACL_logDir sid "/")
  errset(deleteDir(newDir))
  ACL_sessionTag = "acl-test-codex-fresh"
  ACL_sessionTagWritten = nil
  ACL_codexThreadStarted = nil
  ACL_codexResumeId = nil
  ACL_codexResumeIsFork = nil
  ACL_codexThreadId = nil
  ACL_sessionId = nil
  ACL_sessionLogDir = ACL_logDir
  ACL_codexProcessLine(sprintf(nil
    "{\"method\":\"thread/started\",\"params\":{\"thread\":{\"id\":\"%s\"}}}"
    sid))
  ACL_check("codex fresh: sessionId captured" ACL_sessionId sid)
  ACL_check("codex fresh: threadId mirrored" ACL_codexThreadId sid)
  ACL_check("codex fresh: thread started flag" ACL_codexThreadStarted t)
  ACL_check("codex fresh: log dir created" isDir(newDir) t)
  ACL_check("codex fresh: tag file written"
    ACL_readFile(strcat(newDir "acl_tag")) "acl-test-codex-fresh")
  ; cleanup
  foreach(f ACL_listDirFiles(newDir)
    errset(deleteFile(strcat(newDir f))))
  errset(deleteDir(newDir))

  ; --- Fork: resume id + isFork copies parent files into new dir ---
  parentDir = strcat(ACL_logDir "019e0000-parent-7000-0000-000000000001/")
  sid = "019e0000-fork-7000-0000-000000000002"
  newDir = strcat(ACL_logDir sid "/")
  errset(deleteDir(newDir))
  ACL_createDirP(parentDir)
  let(((fp outfile(strcat(parentDir "cmd_5.il"))))
    when(fp fprintf(fp "(plus 3 3)") close(fp))
    fp = outfile(strcat(parentDir "cmd_5.out"))
    when(fp fprintf(fp "Result: 6") close(fp)))
  ACL_sessionTag = "acl-test-codex-fork"
  ACL_sessionTagWritten = nil
  ACL_codexThreadStarted = nil
  ACL_codexThreadId = nil
  ACL_codexResumeId = "019e0000-parent-7000-0000-000000000001"
  ACL_codexResumeIsFork = t
  ACL_sessionId = nil
  ACL_sessionLogDir = ACL_logDir
  ACL_codexProcessLine(sprintf(nil
    "{\"method\":\"thread/started\",\"params\":{\"thread\":{\"id\":\"%s\"}}}"
    sid))
  ACL_check("codex fork: new id captured" ACL_sessionId sid)
  ACL_check("codex fork: new dir created" isDir(newDir) t)
  ACL_checkTrue("codex fork: parent cmd copied"
    isFile(strcat(newDir "cmd_5.il")))
  ACL_check("codex fork: copied content matches"
    ACL_readFile(strcat(newDir "cmd_5.il")) "(plus 3 3)")
  ACL_check("codex fork: seq seeded from copied files" ACL_mcpCmdSeq 5)
  ACL_check("codex fork: parent dir preserved" isDir(parentDir) t)
  ; cleanup
  foreach(d list(parentDir newDir)
    foreach(f ACL_listDirFiles(d)
      errset(deleteFile(strcat(d f))))
    errset(deleteDir(d)))

  ; --- Resume: thread/started for an existing dir doesn't clobber it ---
  sid = "019e0000-resume-7000-0000-000000000003"
  newDir = strcat(ACL_logDir sid "/")
  ACL_createDirP(newDir)
  let(((fp outfile(strcat(newDir "cmd_9.il"))))
    when(fp fprintf(fp "(plus 4 4)") close(fp)))
  ACL_sessionTag = "acl-test-codex-resume"
  ACL_sessionTagWritten = nil
  ACL_codexThreadStarted = nil
  ACL_codexThreadId = nil
  ACL_codexResumeId = sid
  ACL_codexResumeIsFork = nil
  ACL_sessionId = nil
  ACL_sessionLogDir = ACL_logDir
  ACL_codexProcessLine(sprintf(nil
    "{\"method\":\"thread/started\",\"params\":{\"thread\":{\"id\":\"%s\"}}}"
    sid))
  ACL_check("codex resume: sessionId captured" ACL_sessionId sid)
  ACL_check("codex resume: seq seeded from existing" ACL_mcpCmdSeq 9)
  ACL_checkTrue("codex resume: existing file untouched"
    isFile(strcat(newDir "cmd_9.il")))
  ; cleanup
  foreach(f ACL_listDirFiles(newDir)
    errset(deleteFile(strcat(newDir f))))
  errset(deleteDir(newDir))

  deleteFile(ACL_sessionsFile)
  ACL_activeEntry = savedActive
  ACL_codexResumeIsFork = savedResumeFork
  ACL_codexResumeId = savedResumeId
  ACL_codexThreadStarted = savedThreadStarted
  ACL_codexThreadId = savedThreadId
  ACL_resumeIsFork = savedFork
  ACL_mcpCmdSeq = savedSeq
  ACL_sessionTagWritten = savedWritten
  ACL_sessionTag = savedTag
  ACL_sessionsFile = savedFile
  ACL_sessionLogDir = savedLogDir
  ACL_sessionId = savedSid)

printf("\n--- Codex stale-thread recovery ---\n")
; thread/resume against a sid the live agent no longer knows must
; remove the entry from sessions.json, drop sessionId, and continue
; with a fresh thread/start instead of looping on the bad id.
let(((savedSid ACL_sessionId) (savedFile ACL_sessionsFile)
     (savedResumeId ACL_codexResumeId) (savedFork ACL_codexResumeIsFork)
     (savedStarted ACL_codexThreadStarted) (savedInit ACL_codexInitialized)
     (savedRpc ACL_codexNextRpcId) (savedProc ACL_proc)
     (savedLogDir ACL_sessionLogDir)
     (proc ipcBeginProcess(if(ACL_isWindows "cmd /c more" "cat") ""))
     sid badResp)
  when(proc
    ACL_proc = proc
    ACL_sessionLogDir = nil
    sid = "019e0000-stale-7000-0000-000000000099"
    ACL_sessionsFile = strcat(ACL_homeDir "codex_stale_test.json")
    errset(deleteFile(ACL_sessionsFile))
    ACL_addSession(sid list(list("board" "/tmp/x.brd") list("time" "1")
                            list("model" "gpt-5-5")))
    ACL_sessionId = sid
    ACL_codexResumeId = sid
    ACL_codexResumeIsFork = nil
    ACL_codexInitialized = t  ; pretend init handshake already happened
    ACL_codexThreadStarted = nil
    ACL_codexNextRpcId = 50
    badResp = sprintf(nil
      "{\"id\":42,\"error\":{\"code\":-32602,\"message\":\"unknown thread id\"}}")
    ACL_codexProcessLine(badResp)
    ACL_check("stale: sid removed from sessions.json"
      ACL_getSession(sid) nil)
    ACL_check("stale: sessionId cleared" ACL_sessionId nil)
    ACL_check("stale: resumeId cleared" ACL_codexResumeId nil)
    errset(deleteFile(ACL_sessionsFile))
    ipcKillProcess(proc))
  ACL_sessionLogDir = savedLogDir
  ACL_proc = savedProc
  ACL_codexNextRpcId = savedRpc
  ACL_codexInitialized = savedInit
  ACL_codexThreadStarted = savedStarted
  ACL_codexResumeIsFork = savedFork
  ACL_codexResumeId = savedResumeId
  ACL_sessionsFile = savedFile
  ACL_sessionId = savedSid
  ACL_logUnflushed = "")

printf("\n--- Codex agent error notification keeps turn alive ---\n")
; turn-state invariants: codex `error` notifications must NOT reset
; busy/status. Only turn/completed does that. Regression guard for
; the bug where mid-turn errors flipped the status to "Ready".
let(((savedBusy ACL_busy) (savedLogDir ACL_sessionLogDir))
  ACL_sessionLogDir = nil  ; mute appendChat
  ACL_busy = t
  ACL_codexProcessLine(strcat(
    "{\"method\":\"error\",\"params\":{\"error\":{\"message\":\"boom\"}}}"))
  ACL_check("codex error: busy still t" ACL_busy t)
  ; turn/completed clears it.
  ACL_codexProcessLine(strcat(
    "{\"method\":\"turn/completed\",\"params\":{\"threadId\":\"x\","
    "\"turn\":{\"id\":\"y\"}}}"))
  ACL_check("codex turn/completed: busy cleared" ACL_busy nil)
  ACL_sessionLogDir = savedLogDir
  ACL_busy = savedBusy
  ACL_logUnflushed = "")

printf("\n--- Codex error-message unwrap + failed turn ---\n")
let(((savedLog ACL_logContent) (savedUnflushed ACL_logUnflushed)
     (savedStatus ACL_statusText) (savedForm ACL_form)
     (savedBusy ACL_busy) (savedLogDir ACL_sessionLogDir)
     (savedSend ACL_codexInflightSend) (savedTurnId ACL_codexCurrentTurnId))
  ACL_form = nil
  ACL_sessionLogDir = strcat(ACL_homeDir "errfmt_test/")
  ACL_createDirP(ACL_sessionLogDir)
  ; Bare string: passes through unchanged.
  ACL_check("errorMessage: bare string passes through"
    ACL_codexErrorMessage(list(list("message" "plain text")))
    "plain text")
  ; Nested JSON: peels one layer to get inner .error.message.
  ACL_check("errorMessage: peels nested JSON"
    ACL_codexErrorMessage(list(list("message"
      "{\"error\":{\"code\":\"invalid_request_error\",\"message\":\"actual message\"}}")))
    "actual message")
  ; No message at all: returns "?" rather than nil/crash.
  ACL_check("errorMessage: nil err -> ?"
    ACL_codexErrorMessage(nil) "?")
  ; --- turn/completed with status=failed surfaces the error + status
  ACL_logContent = nil
  ACL_logUnflushed = ""
  ACL_busy = t
  ACL_codexInflightSend = t
  ACL_codexCurrentTurnId = "t1"
  ACL_codexProcessLine(strcat(
    "{\"method\":\"turn/completed\",\"params\":{\"threadId\":\"th\","
    "\"turn\":{\"id\":\"t1\",\"status\":\"failed\","
    "\"error\":{\"message\":"
    "\"{\\\"error\\\":{\\\"message\\\":\\\"Provider HTTP 400\\\"}}\"}}}}"))
  ACL_check("failed turn: status reports Turn failed"
    ACL_statusText "Turn failed")
  ACL_checkTrue("failed turn: chat shows unwrapped message"
    nindex(ACL_logString() "Provider HTTP 400"))
  ACL_check("failed turn: busy cleared" ACL_busy nil)
  ; Cleanup
  foreach(f ACL_listDirFiles(ACL_sessionLogDir)
    errset(deleteFile(strcat(ACL_sessionLogDir f))))
  errset(deleteDir(ACL_sessionLogDir))
  ACL_codexCurrentTurnId = savedTurnId
  ACL_codexInflightSend = savedSend
  ACL_sessionLogDir = savedLogDir
  ACL_busy = savedBusy
  ACL_form = savedForm
  ACL_statusText = savedStatus
  ACL_logUnflushed = savedUnflushed
  ACL_logContent = savedLog)

printf("\n--- Codex server-initiated requests ---\n")
; A message with BOTH method and id is a request from codex; we must
; reply or codex stalls. commandExecution/requestApproval auto-accepts;
; anything else gets an error reply.
let(((savedProc ACL_proc) (savedStatus ACL_statusText) (savedForm ACL_form)
     (savedLogDir ACL_sessionLogDir) (savedRaw ACL_enableRawLog)
     (rawPath strcat(ACL_homeDir "raw.log"))
     (proc ipcBeginProcess(if(ACL_isWindows "cmd /c more" "cat") "")))
  when(proc
    ACL_form = nil
    ACL_sessionLogDir = nil
    ACL_proc = proc
    ACL_enableRawLog = t
    errset(deleteFile(rawPath))
    ; commandExecution approval auto-accepts.
    ACL_codexProcessLine(strcat(
      "{\"id\":7,\"method\":\"item/commandExecution/requestApproval\","
      "\"params\":{\"command\":\"echo  hi\\nworld\","
      "\"availableDecisions\":[\"accept\",\"cancel\"]}}"))
    ACL_check("approval: status set to Running"
      ACL_statusText "Running: echo hi world")
    letseq(((wire ACL_readFile(rawPath)))
      ACL_checkTrue("approval: replied with id"
        pcreMatchp("\"id\":7" wire))
      ACL_checkTrue("approval: replied accept"
        pcreMatchp("\"decision\":\"accept\"" wire)))
    ; Unknown request: error reply.
    errset(deleteFile(rawPath))
    ACL_codexProcessLine("{\"id\":8,\"method\":\"some/future/thing\",\"params\":{}}")
    letseq(((wire ACL_readFile(rawPath)))
      ACL_checkTrue("approval: unknown method gets error reply"
        pcreMatchp("\"id\":8" wire))
      ACL_checkTrue("approval: error carries -32601"
        pcreMatchp("-32601" wire)))
    errset(deleteFile(rawPath))
    ipcKillProcess(proc))
  ACL_enableRawLog = savedRaw
  ACL_sessionLogDir = savedLogDir
  ACL_form = savedForm
  ACL_statusText = savedStatus
  ACL_proc = savedProc)

printf("\n--- Codex tool-complete returns to Thinking ---\n")
; mcpToolCall item/started flips status to "Using X..."; the matching
; item/completed must flip it back to "Thinking..." so the bar doesn't
; stay pinned to a stale tool name while the model reasons.
let(((savedStatus ACL_statusText) (savedForm ACL_form))
  ACL_form = nil  ; setStatus updates ACL_statusText regardless
  ACL_codexProcessLine(strcat(
    "{\"method\":\"item/started\",\"params\":{\"item\":"
    "{\"type\":\"mcpToolCall\",\"server\":\"allegro\","
    "\"tool\":\"allegro_execute\",\"id\":\"i1\"}}}"))
  ACL_check("status during tool call" ACL_statusText "Using allegro_execute...")
  ACL_codexProcessLine(strcat(
    "{\"method\":\"item/completed\",\"params\":{\"item\":"
    "{\"type\":\"mcpToolCall\",\"server\":\"allegro\","
    "\"tool\":\"allegro_execute\",\"id\":\"i1\"}}}"))
  ACL_check("status after tool returns" ACL_statusText "Thinking...")
  ; Non-allegro MCP tool (e.g. my_core): status shows server/tool
  ; but our handleToolCall does NOT fire (we don't own the tool).
  ACL_codexProcessLine(strcat(
    "{\"method\":\"item/started\",\"params\":{\"item\":"
    "{\"type\":\"mcpToolCall\",\"server\":\"my_core\","
    "\"tool\":\"search_files\",\"id\":\"m1\"}}}"))
  ACL_check("status during non-allegro MCP tool"
    ACL_statusText "Using my_core/search_files...")
  ACL_codexProcessLine(strcat(
    "{\"method\":\"item/completed\",\"params\":{\"item\":"
    "{\"type\":\"mcpToolCall\",\"server\":\"my_core\","
    "\"tool\":\"search_files\",\"id\":\"m1\"}}}"))
  ACL_check("status after non-allegro MCP returns"
    ACL_statusText "Thinking...")
  ; commandExecution: codex's built-in shell tool. Status shows the
  ; (whitespace-collapsed) command.
  ACL_codexProcessLine(strcat(
    "{\"method\":\"item/started\",\"params\":{\"item\":"
    "{\"type\":\"commandExecution\","
    "\"command\":\"echo  hello\\nworld\",\"id\":\"c1\"}}}"))
  ACL_check("status during commandExecution"
    ACL_statusText "Running: echo hello world")
  ACL_codexProcessLine(strcat(
    "{\"method\":\"item/completed\",\"params\":{\"item\":"
    "{\"type\":\"commandExecution\","
    "\"command\":\"echo hello\",\"id\":\"c1\"}}}"))
  ACL_check("status after commandExecution returns"
    ACL_statusText "Thinking...")
  ACL_statusText = savedStatus
  ACL_form = savedForm)

printf("\n--- Codex initial-turn status ---\n")
; A queued user turn must read "Thinking..." through captureThreadId
; and issueTurn, not flicker through "Connected" / "Ready".
let(((savedStatus ACL_statusText) (savedForm ACL_form)
     (savedStarted ACL_codexThreadStarted) (savedThreadId ACL_codexThreadId)
     (savedQueue ACL_codexPendingTurns) (savedInflight ACL_codexInflightSend)
     (savedBusy ACL_busy) (savedProc ACL_proc)
     (savedAmbient ACL_codexPendingAmbient) (savedSid ACL_sessionId)
     (savedLogDir ACL_sessionLogDir)
     (proc ipcBeginProcess(if(ACL_isWindows "cmd /c more" "cat") "")))
  when(proc
    ACL_proc = proc
    ACL_form = nil
    ACL_codexPendingTurns = list("hi")
    ACL_codexThreadStarted = nil
    ACL_codexInflightSend = nil
    ACL_codexPendingAmbient = ""
    ACL_busy = nil
    ACL_setStatus("Ready")
    ; captureThreadId: queued turn, so it MUST NOT downgrade to Connected.
    ACL_codexCaptureThreadId("thread-init-status")
    ACL_check("captureThreadId keeps Thinking when drain pending"
      ACL_statusText "Thinking...")
    ACL_check("captureThreadId flagged busy via issueTurn"
      ACL_busy t)
    ipcKillProcess(proc))
  ACL_codexThreadId = savedThreadId
  ACL_codexThreadStarted = savedStarted
  ACL_codexPendingTurns = savedQueue
  ACL_codexInflightSend = savedInflight
  ACL_codexPendingAmbient = savedAmbient
  ACL_busy = savedBusy
  ACL_proc = savedProc
  ACL_sessionId = savedSid
  ACL_sessionLogDir = savedLogDir
  ACL_form = savedForm
  ACL_statusText = savedStatus)

printf("\n--- Codex tokenUsage notification ---\n")
; thread/tokenUsage/updated lands cumulative + per-turn counts and
; the model's context window. last.totalTokens drives "current %"
; in the bar; total.* gets folded into the weighted-token figure
; when there's no $-cost to display.
let(((savedTok ACL_lastContextTokens) (savedWin ACL_lastContextWindow)
     (savedWtok ACL_sessionWeightedTokens))
  ACL_lastContextTokens = 0
  ACL_lastContextWindow = nil
  ACL_sessionWeightedTokens = 0.0
  ACL_codexProcessLine(strcat(
    "{\"method\":\"thread/tokenUsage/updated\","
    "\"params\":{\"threadId\":\"t\",\"turnId\":\"u\","
    "\"tokenUsage\":{\"last\":{\"inputTokens\":1000,\"outputTokens\":200,"
    "\"cachedInputTokens\":50,\"reasoningOutputTokens\":40,"
    "\"totalTokens\":1290},"
    "\"total\":{\"inputTokens\":10000,\"outputTokens\":2000,"
    "\"cachedInputTokens\":500,\"reasoningOutputTokens\":400,"
    "\"totalTokens\":12900},"
    "\"modelContextWindow\":256000}}}"))
  ACL_check("codex tokenUsage: per-turn tokens captured"
    ACL_lastContextTokens 1290)
  ACL_check("codex tokenUsage: window captured"
    ACL_lastContextWindow 256000)
  ; Weighted: 2000*1 + 400*1 + 10000/8 + 500/80 = 3656.25
  ACL_checkTrue("codex tokenUsage: weighted total computed"
    and(plusp(ACL_sessionWeightedTokens)
        abs(ACL_sessionWeightedTokens - 3656.25) < 0.01))
  ACL_lastContextTokens = savedTok
  ACL_lastContextWindow = savedWin
  ACL_sessionWeightedTokens = savedWtok)

printf("\n--- weightedTokens / formatTokenCount ---\n")
ACL_check("weighted: empty breakdown" ACL_weightedTokens(nil) 0.0)
ACL_checkTrue("weighted: cached only is heavily discounted"
  abs(ACL_weightedTokens(list(list("cachedInputTokens" 800)
                              list("inputTokens" 0)
                              list("outputTokens" 0)
                              list("reasoningOutputTokens" 0))) - 10.0) < 0.01)
ACL_check("format: small"   ACL_formatTokenCount(234.0) "0.00Mt")
ACL_check("format: kt-range" ACL_formatTokenCount(12300.0) "0.01Mt")
ACL_check("format: Mt"       ACL_formatTokenCount(1234567.0) "1.23Mt")

printf("\n--- readyStatus formatting ---\n")
let(((savedCost ACL_sessionCostUsd) (savedTok ACL_lastContextTokens)
     (savedWin ACL_lastContextWindow) (savedWtok ACL_sessionWeightedTokens))
  ACL_sessionCostUsd = 0.0
  ACL_sessionWeightedTokens = 0.0
  ACL_lastContextTokens = 0
  ACL_lastContextWindow = nil
  ACL_check("readyStatus: bare" ACL_readyStatus() "Ready")
  ACL_lastContextTokens = 12900
  ACL_lastContextWindow = 256000
  ACL_check("readyStatus: ctx only"
    ACL_readyStatus() "Ready  -  5% ctx")
  ACL_sessionWeightedTokens = 1234567.0
  ACL_check("readyStatus: weighted-tokens + ctx"
    ACL_readyStatus() "Ready  -  1.23Mt  -  5% ctx")
  ACL_sessionCostUsd = 1.234
  ACL_check("readyStatus: cost wins over weighted"
    ACL_readyStatus() "Ready  -  $1.23  -  5% ctx")
  ACL_lastContextWindow = nil
  ACL_check("readyStatus: cost only"
    ACL_readyStatus() "Ready  -  $1.23")
  ACL_sessionCostUsd = 0.0
  ACL_check("readyStatus: weighted-tokens only"
    ACL_readyStatus() "Ready  -  1.23Mt")
  ACL_sessionCostUsd = savedCost
  ACL_sessionWeightedTokens = savedWtok
  ACL_lastContextTokens = savedTok
  ACL_lastContextWindow = savedWin)

printf("\n--- Codex send-side queue + drain ---\n")
; Send dispatch:
;   pre-thread sends queue, drainPending at thread/started batches
;     them into ONE fresh turn
;   noQuery messages bypass the queue and ride along in ambient
;     context with the next real turn
;   gap window (turn/start fired, turn/started not yet): queue,
;     then turn/started drains as a steer against the now-known
;     turn id
;   active turn with known turn id: fire as steer immediately,
;     batched with anything else already queued
;   queued items still pending at turn/completed (codex deferred
;     them past turn end): drainPending fires as a fresh turn
let(((savedStarted ACL_codexThreadStarted)
     (savedInflight ACL_codexInflightSend)
     (savedThreadId ACL_codexThreadId)
     (savedTurnId ACL_codexCurrentTurnId)
     (savedSteerId ACL_codexInflightSteerId)
     (savedSteerText ACL_codexInflightSteerText)
     (savedSteerCount ACL_codexInflightSteerCount)
     (savedPendingFlush ACL_codexSteeredPendingFlush)
     (savedQueue ACL_codexPendingTurns)
     (savedAmbient ACL_codexPendingAmbient)
     (savedRpcId ACL_codexNextRpcId)
     (savedProc ACL_proc)
     (proc ipcBeginProcess(if(ACL_isWindows "cmd /c more" "cat") "")))
  when(proc
    ACL_proc = proc
    ACL_codexThreadStarted = nil
    ACL_codexInflightSend = nil
    ACL_codexCurrentTurnId = nil
    ACL_codexInflightSteerId = nil
    ACL_codexInflightSteerText = nil
    ACL_codexInflightSteerCount = 0
    ACL_codexSteeredPendingFlush = 0
    ACL_codexThreadId = "thread-queue-test"
    ACL_codexPendingTurns = nil
    ACL_codexPendingAmbient = ""
    ACL_codexNextRpcId = 500

    ; --- Pre-thread: real sends queue, noQuery buffers ambient ---
    ACL_codexDriverSend("first" nil nil)
    ACL_codexDriverSend("second" nil nil)
    ACL_check("pre-thread: real sends queued"
      length(ACL_codexPendingTurns) 2)
    ACL_codexDriverSend("ambient note" t t)
    ACL_check("pre-thread: noQuery did NOT add to turn queue"
      length(ACL_codexPendingTurns) 2)
    ACL_check("pre-thread: noQuery buffered ambient"
      ACL_codexPendingAmbient "ambient note")

    ; --- thread/started: flush fires ONE batched turn ---
    ACL_codexThreadStarted = t
    ACL_codexFlush()
    ACL_check("thread/started: queue fully drained"
      ACL_codexPendingTurns nil)
    ACL_check("thread/started: turn now in flight"
      ACL_codexInflightSend t)
    ACL_check("thread/started: ambient buffer cleared"
      ACL_codexPendingAmbient "")

    ; --- Quick hi/bye gap-window race ---
    ACL_codexInflightSend = nil
    ACL_codexCurrentTurnId = nil
    ACL_codexInflightSteerId = nil
    ACL_codexInflightSteerText = nil
    ACL_codexInflightSteerCount = 0
    ACL_codexSteeredPendingFlush = 0
    ACL_codexPendingTurns = nil
    ACL_codexPendingAmbient = ""
    ACL_codexDriverSend("hi" nil nil)
    ACL_check("gap: hi fired a turn"
      ACL_codexInflightSend t)
    ACL_check("gap: currentTurnId not yet known"
      ACL_codexCurrentTurnId nil)
    ACL_codexDriverSend("bye" nil nil)
    ACL_check("gap: bye queued (no fresh turn fired)"
      ACL_codexPendingTurns (list "bye"))
    ACL_check("gap: no steer in flight yet"
      ACL_codexInflightSteerId nil)
    ; turn/started arrives -> drain the gap-window queue as a steer
    ACL_codexProcessLine(strcat(
      "{\"method\":\"turn/started\","
      "\"params\":{\"threadId\":\"thread-queue-test\","
      "\"turn\":{\"id\":\"turn-hi\"}}}"))
    ACL_check("gap: turn/started set currentTurnId"
      ACL_codexCurrentTurnId "turn-hi")
    ACL_check("gap: turn/started drained queue"
      ACL_codexPendingTurns nil)
    ACL_check("gap: bye fired as steer"
      ACL_codexInflightSteerText "bye")
    ACL_check("gap: steer carries 1 item"
      ACL_codexInflightSteerCount 1)

    ; --- More sends while steer in flight: queue (serialize) ---
    ACL_codexDriverSend("queued-A" nil nil)
    ACL_codexDriverSend("queued-B" nil nil)
    ACL_check("queue-during-steer: both queued"
      ACL_codexPendingTurns (list "queued-A" "queued-B"))
    ACL_check("queue-during-steer: in-flight steer unchanged"
      ACL_codexInflightSteerText "bye")

    ; --- Steer success: re-batches A+B into next steer ---
    letseq(((firstSteerId ACL_codexInflightSteerId))
      ACL_codexProcessLine(sprintf(nil
        "{\"id\":%d,\"result\":{\"turnId\":\"turn-hi\"}}" firstSteerId))
      ACL_check("steer success: queue drained"
        ACL_codexPendingTurns nil)
      ACL_check("steer success: A+B batched into next steer"
        ACL_codexInflightSteerText "queued-A\n\nqueued-B")
      ACL_check("steer success: new steer id differs"
        (ACL_codexInflightSteerId == firstSteerId) nil)
      ACL_check("steer success: bye banked for tool-end flush"
        ACL_codexSteeredPendingFlush 1))

    ; --- Idle send fires fresh turn (after current turn ended) ---
    ACL_codexInflightSteerId = nil
    ACL_codexInflightSteerText = nil
    ACL_codexInflightSteerCount = 0
    ACL_codexSteeredPendingFlush = 0
    ACL_codexInflightSend = nil
    ACL_codexCurrentTurnId = nil
    ACL_codexPendingTurns = nil
    ACL_codexDriverSend("idle send" nil nil)
    ACL_check("send idle: queue empty (fired as turn)"
      ACL_codexPendingTurns nil)
    ACL_check("send idle: inflight set"
      ACL_codexInflightSend t)

    ; --- Race classifier ---
    ACL_check("race: expectedTurnId mismatch flagged"
      ACL_codexIsSteerRaceError("expectedTurnId mismatch") t)
    ACL_check("race: other error not flagged"
      ACL_codexIsSteerRaceError("rate limited") nil)

    ipcKillProcess(proc))
  ACL_proc = savedProc
  ACL_codexNextRpcId = savedRpcId
  ACL_codexPendingAmbient = savedAmbient
  ACL_codexPendingTurns = savedQueue
  ACL_codexSteeredPendingFlush = savedPendingFlush
  ACL_codexInflightSteerCount = savedSteerCount
  ACL_codexInflightSteerText = savedSteerText
  ACL_codexInflightSteerId = savedSteerId
  ACL_codexCurrentTurnId = savedTurnId
  ACL_codexThreadId = savedThreadId
  ACL_codexInflightSend = savedInflight
  ACL_codexThreadStarted = savedStarted)


printf("\n--- Codex steered display flushes at next item start ---\n")
; A successful steer banks display entries to flush at the NEXT
; item/started (the model began a new LLM round that consumed our
; steered pending input). turn/completed is a safety net.
let(((savedQueue ACL_pendingChatQueue) (savedLog ACL_logContent)
     (savedUnflushed ACL_logUnflushed) (savedBusy ACL_busy)
     (savedForm ACL_form) (savedActive ACL_activeEntry)
     (savedExtra ACL_extraModels) (savedBuiltins ACL_useBuiltinModels)
     (savedPendingFlush ACL_codexSteeredPendingFlush)
     (savedSteerId ACL_codexInflightSteerId)
     (savedSteerText ACL_codexInflightSteerText)
     (savedSteerCount ACL_codexInflightSteerCount)
     (savedInflight ACL_codexInflightSend)
     (savedTurnId ACL_codexCurrentTurnId)
     (savedThreadStarted ACL_codexThreadStarted))
  ACL_useBuiltinModels = nil
  ACL_extraModels = "{'csftest':{'driver':'codex','model':'x'}}"
  ACL_activeEntry = ACL_modelById("csftest")
  ACL_form = nil
  ACL_busy = t
  ACL_codexThreadStarted = t
  ACL_codexCurrentTurnId = "turn-X"
  ACL_codexInflightSend = t

  ; A steer for "bye" succeeds: 1 entry banked, display unchanged.
  ACL_logContent = nil
  ACL_logUnflushed = ""
  ACL_pendingChatQueue = list("bye")
  ACL_codexInflightSteerId = 9
  ACL_codexInflightSteerText = "bye"
  ACL_codexInflightSteerCount = 1
  ACL_codexSteeredPendingFlush = 0
  ACL_codexProcessLine("{\"id\":9,\"result\":{\"turnId\":\"turn-X\"}}")
  ACL_check("steer ack: banked 1 for next item start"
    ACL_codexSteeredPendingFlush 1)
  ACL_check("steer ack: display NOT yet drained"
    ACL_pendingChatQueue (list "bye"))

  ; A new item starts (any type) -> flush. Use a reasoning item to
  ; show that this isn't tied to mcpToolCall specifically.
  ACL_codexProcessLine(strcat(
    "{\"method\":\"item/started\",\"params\":{\"item\":"
    "{\"type\":\"reasoning\",\"id\":\"r1\"}}}"))
  ACL_check("next item: deferred flush drained"
    ACL_pendingChatQueue nil)
  ACL_check("next item: pending counter reset"
    ACL_codexSteeredPendingFlush 0)
  ACL_checkTrue("next item: bye landed in log"
    nindex(ACL_logString() "You: bye"))

  ; mcpToolCall start also triggers the flush (independent path).
  ACL_logContent = nil
  ACL_logUnflushed = ""
  ACL_pendingChatQueue = list("later")
  ACL_codexSteeredPendingFlush = 1
  ACL_codexProcessLine(strcat(
    "{\"method\":\"item/started\",\"params\":{\"item\":"
    "{\"type\":\"mcpToolCall\",\"server\":\"allegro\","
    "\"tool\":\"allegro_execute\",\"id\":\"c1\",\"arguments\":{\"code\":\"42\"}}}}"))
  ACL_check("tool start: deferred flush drained"
    ACL_pendingChatQueue nil)
  ACL_checkTrue("tool start: later landed in log"
    nindex(ACL_logString() "You: later"))

  ; Safety net: explicit flush call drains anything banked
  ACL_logContent = nil
  ACL_logUnflushed = ""
  ACL_pendingChatQueue = list("orphan")
  ACL_codexSteeredPendingFlush = 1
  ACL_busy = t
  ACL_codexFlushSteeredQueue()
  ACL_check("safety: explicit flush call drains"
    ACL_pendingChatQueue nil)
  ACL_check("safety: pending counter reset"
    ACL_codexSteeredPendingFlush 0)

  ACL_codexThreadStarted = savedThreadStarted
  ACL_codexCurrentTurnId = savedTurnId
  ACL_codexInflightSend = savedInflight
  ACL_codexInflightSteerCount = savedSteerCount
  ACL_codexInflightSteerText = savedSteerText
  ACL_codexInflightSteerId = savedSteerId
  ACL_codexSteeredPendingFlush = savedPendingFlush
  ACL_useBuiltinModels = savedBuiltins
  ACL_extraModels = savedExtra
  ACL_activeEntry = savedActive
  ACL_busy = savedBusy
  ACL_logUnflushed = savedUnflushed
  ACL_logContent = savedLog
  ACL_pendingChatQueue = savedQueue
  ACL_form = savedForm)

printf("\n--- Codex display-queue drain on turn end ---\n")
; Regression guard: when codex batches every queued user message
; into ONE fresh turn at turn/completed, the display "Queued:"
; labels for those messages must clear in lockstep -- otherwise
; they pile up forever even though the transport already delivered
; them.
let(((savedQueue ACL_pendingChatQueue) (savedCodexQueue ACL_codexPendingTurns)
     (savedLog ACL_logContent) (savedUnflushed ACL_logUnflushed)
     (savedBusy ACL_busy) (savedForm ACL_form)
     (savedActive ACL_activeEntry) (savedExtra ACL_extraModels)
     (savedBuiltins ACL_useBuiltinModels) (savedSent ACL_lastSent)
     (savedStatus ACL_statusText))
  ACL_useBuiltinModels = nil
  ACL_extraModels = "{'cqtest':{'driver':'codex','model':'x'}}"
  ACL_activeEntry = ACL_modelById("cqtest")
  ACL_form = nil
  ACL_logContent = nil
  ACL_logUnflushed = ""
  ACL_busy = t

  ; Three messages queued during the just-finished turn. At turn end,
  ; drainPending will fire all three as one new turn, so the display
  ; should also clear in one go.
  ACL_pendingChatQueue = list("1" "2" "3")
  ACL_codexPendingTurns = list("1" "2" "3")
  ACL_onResponseComplete()
  ACL_check("codex: drains every queued line at turn end"
    ACL_pendingChatQueue nil)
  ACL_checkTrue("codex: drained lines reached log as You:"
    and(nindex(ACL_logString() "You: 1")
        nindex(ACL_logString() "You: 2")
        nindex(ACL_logString() "You: 3")))

  ; Claude path is unchanged -- only one per turn end.
  ACL_extraModels = "{'cqclaude':{'driver':'claude','model':'x'}}"
  ACL_activeEntry = ACL_modelById("cqclaude")
  ACL_pendingChatQueue = list("a" "b" "c")
  ACL_logContent = nil
  ACL_logUnflushed = ""
  ACL_busy = t
  ACL_onResponseComplete()
  ACL_check("claude: drains exactly one per turn end"
    ACL_pendingChatQueue (list "b" "c"))

  ACL_statusText = savedStatus
  ACL_lastSent = savedSent
  ACL_useBuiltinModels = savedBuiltins
  ACL_extraModels = savedExtra
  ACL_activeEntry = savedActive
  ACL_busy = savedBusy
  ACL_logUnflushed = savedUnflushed
  ACL_logContent = savedLog
  ACL_codexPendingTurns = savedCodexQueue
  ACL_pendingChatQueue = savedQueue
  ACL_form = savedForm)

printf("\n--- Session save / restore round-trip ---\n")
; Exercises the persistence path the driver-abstraction work
; touched: model id is stamped into the entry, restore re-locks
; ACL_activeEntry, and a stale (removed-from-registry) id is
; refused rather than silently demoted to a default.
let(((savedFile ACL_sessionsFile) (savedActive ACL_activeEntry)
     (savedExtra ACL_extraModels) (savedBuiltins ACL_useBuiltinModels)
     (savedSid ACL_sessionId) (savedSaved ACL_sessionSaved)
     (savedSeen ACL_sessionUserMsgSeen)
     (savedLogDir ACL_sessionLogDir)
     (savedFork ACL_pendingForkName)
     (savedPicker ACL_sessionPickerForm)
     (savedProc ACL_proc)
     (savedLastSent ACL_lastSent)
     (savedBusy ACL_busy)
     (proc ipcBeginProcess(if(ACL_isWindows "cmd /c more" "cat") ""))
     sid info entry)
  when(proc
    ACL_proc = proc       ; absorb the synthetic ACL_sendMessage write
    ACL_sessionsFile = strcat(ACL_homeDir "codex_saveload_test.json")
    errset(deleteFile(ACL_sessionsFile))
    ACL_useBuiltinModels = nil
    ACL_extraModels = "{
      'codex-saveload': {'driver':'codex','model':'codex-m','label':'X'},
      'claude-saveload': {'driver':'claude','model':'claude-m','label':'Y'}
    }"

    ; --- codex round-trip: save stamps id, restore re-locks entry ---
    sid = "019e0000-codex-save-0000-000000000010"
    ACL_activeEntry = ACL_modelById("codex-saveload")
    ACL_sessionId = sid
    ACL_sessionSaved = nil
    ACL_sessionUserMsgSeen = t
    ACL_sessionLogDir = ACL_logDir
    ACL_pendingForkName = nil
    ACL_sessionPickerForm = nil
    ACL_maybeSaveSession()
    info = ACL_getSession(sid)
    ACL_check("save: entry persisted" listp(info) t)
    ACL_check("save: model id stamped"
      ACL_jGet(info "model") "codex-saveload")
    ACL_check("save: idempotent (no double-write)" ACL_sessionSaved t)
    ACL_activeEntry = nil
    ACL_check("restore: lock succeeds" ACL_lockSessionModel(info) t)
    entry = ACL_activeEntry
    ACL_check("restore: id matches" car(entry) "codex-saveload")
    ACL_check("restore: driver matches"
      ACL_entryField(entry "driver") "codex")

    ; --- stale-id refusal: drop the model from registry ---
    ACL_extraModels = "{
      'claude-saveload': {'driver':'claude','model':'claude-m','label':'Y'}
    }"
    ACL_activeEntry = nil
    ACL_check("restore: stale id refused" ACL_lockSessionModel(info) nil)
    ACL_check("restore: active untouched on refusal" ACL_activeEntry nil)

    ; --- save defers until the user actually types something ---
    sid = "019e0000-codex-save-0000-000000000011"
    ACL_extraModels = "{
      'codex-saveload': {'driver':'codex','model':'codex-m','label':'X'}
    }"
    ACL_activeEntry = ACL_modelById("codex-saveload")
    ACL_sessionId = sid
    ACL_sessionSaved = nil
    ACL_sessionUserMsgSeen = nil
    ACL_maybeSaveSession()
    ACL_check("defer: no entry for synthetic-only session"
      ACL_getSession(sid) nil)
    ACL_check("defer: sessionSaved stays nil" ACL_sessionSaved nil)
    ACL_sessionUserMsgSeen = t
    ACL_maybeSaveSession()
    ACL_checkTrue("defer: entry appears after first user message"
      ACL_getSession(sid))

    ; --- fork preserves the parent's driver+model id ---
    sid = "019e0000-codex-save-0000-000000000012"
    ACL_activeEntry = ACL_modelById("codex-saveload")
    ACL_sessionId = sid
    ACL_sessionSaved = nil
    ACL_sessionUserMsgSeen = t
    ACL_pendingForkName = "Fork name"
    ACL_maybeSaveSession()
    info = ACL_getSession(sid)
    ACL_check("fork: name stamped" ACL_jGet(info "name") "Fork name")
    ACL_check("fork: model id stamped"
      ACL_jGet(info "model") "codex-saveload")

    errset(deleteFile(ACL_sessionsFile))
    ipcKillProcess(proc))
  ACL_busy = savedBusy
  ACL_lastSent = savedLastSent
  ACL_proc = savedProc
  ACL_sessionPickerForm = savedPicker
  ACL_pendingForkName = savedFork
  ACL_sessionLogDir = savedLogDir
  ACL_sessionUserMsgSeen = savedSeen
  ACL_sessionSaved = savedSaved
  ACL_sessionId = savedSid
  ACL_useBuiltinModels = savedBuiltins
  ACL_extraModels = savedExtra
  ACL_activeEntry = savedActive
  ACL_sessionsFile = savedFile)

printf("\n--- Codex stderr filter ---\n")
; ANSI-stripped, noise-suppressed; MCP-router errors counted.
let(((savedCount ACL_codexMcpErrorCount))
  ACL_codexMcpErrorCount = 0
  ACL_check("stderr: noise suppressed"
    ACL_codexCleanStderr("BatchLogProcessor.ExportError happened") nil)
  ACL_check("stderr: web_search_mode dropped"
    ACL_codexCleanStderr("warning about web_search_mode") nil)
  ACL_check("stderr: ANSI stripped"
    ACL_codexCleanStderr(strcat(ACL_byte(0x1b) "[31mhello" ACL_byte(0x1b) "[0m"))
    "hello")
  ; Only tools/call errors against allegro count -- everything
  ; else (resources/read, update_plan misuse, etc.) is model noise.
  ACL_checkTrue("stderr: unrelated router error passes through"
    ACL_codexCleanStderr("foo codex_core::tools::router: error=missing field plan"))
  ACL_check("stderr: unrelated router error not counted"
    ACL_codexMcpErrorCount 0)
  ACL_check("stderr: unknown MCP server hallucinations dropped"
    ACL_codexCleanStderr("foo router: error=resources/read failed: unknown MCP server 'mcp__allegro__'") nil)
  ACL_check("stderr: hallucinated server not counted"
    ACL_codexMcpErrorCount 0)
  ; A real allegro tools/call failure IS counted.
  ACL_checkTrue("stderr: MCP-router error returned"
    ACL_codexCleanStderr("foo router: error=tools/call 'allegro_execute' failed: nope"))
  ACL_check("stderr: MCP-router error counted"
    ACL_codexMcpErrorCount 1)
  ACL_codexMcpErrorCount = savedCount)

printf("\n--- Model fallback on error ---\n")
let(((savedActive ACL_activeEntry)
     (savedPending ACL_fallbackRetryPending)
     (savedLastSent ACL_lastSent)
     (savedLogDir ACL_sessionLogDir)
     (savedTriggers ACL_fallbackTriggers)
     (savedExtra ACL_extraModels)
     (savedBuiltins ACL_useBuiltinModels)
     (errBody "API Error: 422 {\"detail\":[{\"type\":\"enum\",\"loc\":[\"body\",\"messages\",1,\"role\"],\"msg\":\"Input should be 'user' or 'assistant'\",\"input\":\"system\"}]}")
     primary fallback errEvent err500Event)
  ; Synthetic two-entry registry so the test is self-contained.
  ACL_useBuiltinModels = nil
  ACL_extraModels = "{
    'test-primary':  {'driver':'claude','model':'test-primary-model',
                      'fallback':'test-fallback'},
    'test-fallback': {'driver':'claude','model':'test-fallback-model'}
  }"
  primary  = ACL_modelById("test-primary")
  fallback = ACL_modelById("test-fallback")
  ; Surface-normal branches call appendChat; mute it so we don't
  ; pollute a real session log.
  ACL_sessionLogDir = nil
  errEvent = strcat(
    "{\"type\":\"result\",\"is_error\":true,\"api_error_status\":422,"
    "\"terminal_reason\":\"completed\","
    "\"result\":" ACL_jsonEscStr(errBody) "}")
  err500Event = strcat(
    "{\"type\":\"result\",\"is_error\":true,\"api_error_status\":500,"
    "\"terminal_reason\":\"completed\",\"result\":\"oops\"}")
  ; Detector: triggers on the role+system marker. Status can be the
  ; HTTP code (claude path) or nil/JSON-RPC (codex passes the upstream
  ; body verbatim, no HTTP wrapper).
  ACL_check("detect: 422 role/system" ACL_isRoleSystemError(422 errBody) t)
  ACL_check("detect: 422 unrelated body" ACL_isRoleSystemError(422 "other 422") nil)
  ACL_check("detect: 500 ignored" ACL_isRoleSystemError(500 errBody) nil)
  ACL_check("detect: nil status accepted (codex path)"
    ACL_isRoleSystemError(nil errBody) t)
  ACL_check("detect: nil body ignored" ACL_isRoleSystemError(422 nil) nil)
  ; findFallbackTrigger returns the trigger label or nil.
  ACL_checkTrue("trigger lookup: hit"
    ACL_findFallbackTrigger(422 errBody))
  ACL_check("trigger lookup: miss" ACL_findFallbackTrigger(500 errBody) nil)
  ; Stream event with the 422 arms the retry-pending flag (storing
  ; the trigger label) and does NOT surface the error to chat.
  ACL_activeEntry = primary
  ACL_fallbackRetryPending = nil
  ACL_processStreamLine(errEvent)
  ACL_checkTrue("trigger: retry pending" ACL_fallbackRetryPending)
  ACL_check("trigger: pending holds label"
    stringp(ACL_fallbackRetryPending) t)
  ACL_fallbackRetryPending = nil
  ; If already on the fallback (no further fallback declared), another
  ; error must NOT loop -- surface normally.
  ACL_activeEntry = fallback
  ACL_processStreamLine(errEvent)
  ACL_check("no retry when already on fallback"
    ACL_fallbackRetryPending nil)
  ; An error not matching any trigger stays on the normal surface path.
  ACL_activeEntry = primary
  ACL_processStreamLine(err500Event)
  ACL_check("no retry on untriggered error" ACL_fallbackRetryPending nil)
  ; Custom trigger gets picked up just by mutating ACL_fallbackTriggers.
  ACL_fallbackTriggers = list(list("custom-500-oops"
    lambda((s r) and(equal(s 500) stringp(r) nindex(r "oops") t))))
  ACL_activeEntry = primary
  ACL_fallbackRetryPending = nil
  ACL_processStreamLine(err500Event)
  ACL_check("custom trigger: pending label"
    ACL_fallbackRetryPending "custom-500-oops")
  ACL_useBuiltinModels = savedBuiltins
  ACL_extraModels = savedExtra
  ACL_lastSent = savedLastSent
  ACL_fallbackRetryPending = savedPending
  ACL_activeEntry = savedActive
  ACL_sessionLogDir = savedLogDir
  ACL_fallbackTriggers = savedTriggers
  ; Drop anything appendChat buffered while sessionLogDir was nil so
  ; it doesn't leak into the next real session's log.txt.
  ACL_logUnflushed = "")

printf("\n--- Codex auto-fallback on errBody ---\n")
; Codex carries no HTTP status, so fallback triggers must fire on the
; JSON-encoded error body alone. Verify both the response-error path
; (ACL_codexHandleResponse) and the mid-turn error notification arm
; ACL_fallbackRetryPending.
let(((savedActive ACL_activeEntry) (savedPending ACL_fallbackRetryPending)
     (savedTriggers ACL_fallbackTriggers) (savedExtra ACL_extraModels)
     (savedBuiltins ACL_useBuiltinModels)
     (savedLogDir ACL_sessionLogDir)
     (savedResume ACL_codexResumeId)
     (savedStarted ACL_codexThreadStarted)
     (savedInit ACL_codexInitialized)
     primary fallback)
  ACL_useBuiltinModels = nil
  ACL_extraModels = "{
    'cprim': {'driver':'codex','model':'p','fallback':'cback'},
    'cback': {'driver':'codex','model':'b'}
  }"
  primary  = ACL_modelById("cprim")
  fallback = ACL_modelById("cback")
  ACL_sessionLogDir = nil
  ACL_codexResumeId = nil
  ACL_codexThreadStarted = t
  ACL_codexInitialized = t

  ; Response error with the role/system marker arms the retry.
  ACL_activeEntry = primary
  ACL_fallbackRetryPending = nil
  ACL_codexProcessLine(strcat(
    "{\"id\":9,\"error\":{\"code\":-32000,"
    "\"message\":\"upstream API Error: invalid \\\"role\\\":\\\"system\\\" inside messages[]\"}}"))
  ACL_checkTrue("codex errBody: trigger pending"
    ACL_fallbackRetryPending)

  ; Mid-turn `error` notification arms the retry too.
  ACL_activeEntry = primary
  ACL_fallbackRetryPending = nil
  ACL_codexProcessLine(strcat(
    "{\"method\":\"error\",\"params\":{\"error\":"
    "{\"message\":\"upstream rejected \\\"role\\\":\\\"system\\\"\"}}}"))
  ACL_checkTrue("codex error notification: trigger pending"
    ACL_fallbackRetryPending)

  ; Unrelated codex error stays on the chat path; no auto-swap.
  ACL_activeEntry = primary
  ACL_fallbackRetryPending = nil
  ACL_codexProcessLine(strcat(
    "{\"id\":10,\"error\":{\"code\":-32601,"
    "\"message\":\"Unknown method: foo\"}}"))
  ACL_check("codex unrelated error: no retry"
    ACL_fallbackRetryPending nil)

  ACL_codexInitialized = savedInit
  ACL_codexThreadStarted = savedStarted
  ACL_codexResumeId = savedResume
  ACL_sessionLogDir = savedLogDir
  ACL_useBuiltinModels = savedBuiltins
  ACL_extraModels = savedExtra
  ACL_fallbackTriggers = savedTriggers
  ACL_fallbackRetryPending = savedPending
  ACL_activeEntry = savedActive
  ACL_logUnflushed = "")

printf("\n--- ACP JSON empty-array sentinel ---\n")
ACL_check("empty-array sentinel renders as []"
  ACL_jsonVal(ACL_jsonEmptyArray) "[]")
ACL_check("nil still renders as null"
  ACL_jsonVal(nil) "null")
ACL_check("sentinel nested in object"
  ACL_jsonVal(list(list("mcpServers" ACL_jsonEmptyArray)
                   list("cwd" "/tmp")))
  "{\"mcpServers\":[],\"cwd\":\"/tmp\"}")

printf("\n--- Driver type resolution ---\n")
let(((savedActive ACL_activeEntry)
     (savedExtra ACL_extraModels)
     (savedBuiltins ACL_useBuiltinModels))
  ACL_useBuiltinModels = nil
  ACL_extraModels = "{
    'cl':  {'driver':'claude','model':'m'},
    'cx':  {'driver':'codex','model':'m'},
    'ap':  {'driver':'my-acp-cli serve','model':'acme/x'},
    'ap2': {'driver':'/abs/path/agent --flag','model':'acme/y'}
  }"
  ACL_activeEntry = ACL_modelById("cl")
  ACL_check("resolve: claude literal" ACL_activeDriver() "claude")
  ACL_check("resolve: claude raw" ACL_activeDriverRaw() "claude")
  ACL_activeEntry = ACL_modelById("cx")
  ACL_check("resolve: codex literal" ACL_activeDriver() "codex")
  ACL_check("resolve: codex raw" ACL_activeDriverRaw() "codex")
  ACL_activeEntry = ACL_modelById("ap")
  ACL_check("resolve: spawn command -> acp" ACL_activeDriver() "acp")
  ACL_check("resolve: spawn command kept verbatim"
    ACL_activeDriverRaw() "my-acp-cli serve")
  ACL_activeEntry = ACL_modelById("ap2")
  ACL_check("resolve: abs-path spawn command -> acp"
    ACL_activeDriver() "acp")
  ACL_check("resolve: abs-path spawn command kept verbatim"
    ACL_activeDriverRaw() "/abs/path/agent --flag")
  ACL_useBuiltinModels = savedBuiltins
  ACL_extraModels = savedExtra
  ACL_activeEntry = savedActive)

printf("\n--- ACP utilities ---\n")
let(((savedNextId ACL_acpNextRpcId))
  ACL_acpNextRpcId = 0
  ACL_check("acpAllocRpcId starts at 1" ACL_acpAllocRpcId() 1)
  ACL_check("acpAllocRpcId monotonic" ACL_acpAllocRpcId() 2)
  ACL_acpNextRpcId = savedNextId)

let(((savedCaps ACL_acpAgentCaps))
  ACL_acpAgentCaps = list(list("loadSession" t)
                          list("sessionCapabilities"
                            list(list("fork" list())
                                 list("resume" list())))
                          list("mcpCapabilities"
                            list(list("http" t)
                                 list("sse" t))))
  ACL_check("acpAgentSupports top-level true"
    and(ACL_acpAgentSupports('("loadSession")) t) t)
  ACL_check("acpAgentSupports nested truthy"
    and(ACL_acpAgentSupports('("sessionCapabilities" "fork")) t) t)
  ACL_check("acpAgentSupports missing"
    ACL_acpAgentSupports('("loadFork")) nil)
  ACL_check("acpAgentSupports nested missing"
    ACL_acpAgentSupports('("sessionCapabilities" "nope")) nil)
  ACL_acpAgentCaps = savedCaps)

let(((savedAmbient ACL_acpPendingAmbient))
  ACL_acpPendingAmbient = ""
  ACL_check("acpConsumeAmbient no-op when empty"
    ACL_acpConsumeAmbient("hello") "hello")
  ACL_check("acpConsumeAmbient clears buffer after no-op"
    ACL_acpPendingAmbient "")
  ACL_acpPendingAmbient = "context note"
  ACL_check("acpConsumeAmbient prepends"
    ACL_acpConsumeAmbient("user msg") "context note\n\nuser msg")
  ACL_check("acpConsumeAmbient clears buffer after consume"
    ACL_acpPendingAmbient "")
  ACL_acpPendingAmbient = savedAmbient)

printf("\n--- ACP send-side queue + flush ---\n")
let(((savedProc ACL_proc)
     (savedPending ACL_acpPendingTurns)
     (savedInflight ACL_acpInflightPromptId)
     (savedStarted ACL_acpSessionStarted)
     (savedSid ACL_sessionId)
     (savedNextId ACL_acpNextRpcId)
     (savedRaw ACL_enableRawLog)
     (savedSent ACL_acpSystemPromptSent)
     (proc ipcBeginProcess(if(ACL_isWindows "cmd /c more" "cat") "")))
  when(proc
    ACL_proc = proc
    ACL_enableRawLog = nil
    ACL_acpSystemPromptSent = t   ; skip prompt-prepend wire shape
    ; No session yet -> queue but don't fire.
    ACL_acpSessionStarted = nil
    ACL_acpInflightPromptId = nil
    ACL_acpPendingTurns = nil
    ACL_acpNextRpcId = 0
    ACL_acpDriverSend("hi" nil nil)
    ACL_check("flush: pre-session keeps queue"
      ACL_acpPendingTurns '("hi"))
    ACL_check("flush: pre-session no in-flight"
      ACL_acpInflightPromptId nil)
    ; Active session, no in-flight -> the next send fires.
    ACL_acpSessionStarted = t
    ACL_sessionId = "test-sid"
    ACL_acpDriverSend("there" nil nil)
    ACL_check("flush: idle session drained"
      ACL_acpPendingTurns nil)
    ACL_check("flush: in-flight id set"
      and(ACL_acpInflightPromptId t) t)
    ACL_check("flush: in-flight count covers batch"
      ACL_acpInflightPromptCount 2)
    ; While in flight, additional sends queue and don't fire.
    ACL_acpDriverSend("more" nil nil)
    ACL_check("flush: in-flight keeps new queue"
      ACL_acpPendingTurns '("more"))
    ; noQuery routes through ambient buffer instead of the turn queue.
    ACL_acpDriverSend("ambient note" nil t)
    ACL_check("flush: noQuery buffers ambient"
      ACL_acpPendingAmbient "ambient note")
    ACL_check("flush: noQuery doesn't touch turn queue"
      ACL_acpPendingTurns '("more"))
    ipcKillProcess(proc))
  ACL_acpSystemPromptSent = savedSent
  ACL_enableRawLog = savedRaw
  ACL_acpNextRpcId = savedNextId
  ACL_sessionId = savedSid
  ACL_acpSessionStarted = savedStarted
  ACL_acpInflightPromptId = savedInflight
  ACL_acpInflightPromptCount = 0
  ACL_acpPendingTurns = savedPending
  ACL_acpPendingAmbient = ""
  ACL_proc = savedProc)

printf("\n--- ACP system-prompt prepend ---\n")
let(((savedSent ACL_acpSystemPromptSent)
     (savedResume ACL_acpResumeId)
     (savedFast ACL_fast))
  ACL_fast = t            ; skip doc-cache block for predictable shape
  ; Fresh session: first prompt prepends system block.
  ACL_acpSystemPromptSent = nil
  ACL_acpResumeId = nil
  letseq(((blocks ACL_acpBuildPromptInput("hello"))
          (block car(blocks))
          (text ACL_jGet(block "text")))
    ACL_check("prompt: first send wraps with markers"
      and(pcreMatchp("\\[SYSTEM_PROMPT_BEGIN\\]" text)
          pcreMatchp("\\[SYSTEM_PROMPT_END\\]" text)
          pcreMatchp("hello$" text)) t)
    ACL_check("prompt: flag flips after first send"
      ACL_acpSystemPromptSent t))
  ; Second send: plain text, no prepend.
  letseq(((blocks ACL_acpBuildPromptInput("again"))
          (block car(blocks))
          (text ACL_jGet(block "text")))
    ACL_check("prompt: subsequent send is plain text"
      text "again"))
  ; Resume path: system prompt never prepended.
  ACL_acpSystemPromptSent = nil
  ACL_acpResumeId = "some-prior-id"
  letseq(((blocks ACL_acpBuildPromptInput("resumed"))
          (block car(blocks))
          (text ACL_jGet(block "text")))
    ACL_check("prompt: resume skips prepend" text "resumed")
    ACL_check("prompt: resume leaves flag untouched"
      ACL_acpSystemPromptSent nil))
  ACL_fast = savedFast
  ACL_acpResumeId = savedResume
  ACL_acpSystemPromptSent = savedSent)

printf("\n--- ACP line dispatch ---\n")
let(((savedInit ACL_acpInitialized)
     (savedCaps ACL_acpAgentCaps)
     (savedAuth ACL_acpAuthMethods)
     (savedStarted ACL_acpSessionStarted)
     (savedSid ACL_sessionId)
     (savedLogDir ACL_sessionLogDir)
     (savedProc ACL_proc)
     (savedRaw ACL_enableRawLog)
     (savedPending ACL_acpPendingTurns)
     (savedInflight ACL_acpInflightPromptId)
     (savedResume ACL_acpResumeId)
     (savedSysSent ACL_acpSystemPromptSent)
     (proc ipcBeginProcess(if(ACL_isWindows "cmd /c more" "cat") "")))
  when(proc
    ACL_proc = proc
    ACL_enableRawLog = nil
    ACL_sessionLogDir = nil
    ACL_acpResumeId = nil
    ACL_acpInitialized = nil
    ACL_acpAgentCaps = nil
    ACL_acpAuthMethods = nil
    ACL_acpSessionStarted = nil
    ACL_acpPendingTurns = nil
    ACL_acpInflightPromptId = nil
    ACL_acpSystemPromptSent = t   ; avoid the buildSystemPrompt path
    ; initialize response captures caps and triggers session/new.
    ACL_acpProcessLine(strcat(
      "{\"id\":1,\"result\":{\"protocolVersion\":1,"
      "\"agentCapabilities\":{\"loadSession\":true},"
      "\"authMethods\":[]}}"))
    ACL_check("dispatch: initialize sets initialized"
      ACL_acpInitialized t)
    ACL_check("dispatch: initialize captures caps"
      ACL_jGet(ACL_acpAgentCaps "loadSession") t)
    ; session/new response (or whatever issue-session fired) lands.
    ACL_sessionId = nil
    ACL_acpProcessLine(strcat(
      "{\"id\":2,\"result\":{\"sessionId\":\"sess-abc\"}}"))
    ACL_check("dispatch: session captures sessionId"
      ACL_sessionId "sess-abc")
    ACL_check("dispatch: sessionStarted flips"
      ACL_acpSessionStarted t)
    ; session/prompt response with stopReason triggers turn end.
    ACL_acpInflightPromptId = 3
    ACL_acpInflightPromptCount = 1
    ACL_busy = t
    ACL_acpProcessLine(strcat(
      "{\"id\":3,\"result\":{\"stopReason\":\"end_turn\"}}"))
    ACL_check("dispatch: prompt clears in-flight"
      ACL_acpInflightPromptId nil)
    ACL_check("dispatch: prompt onResponseComplete clears busy"
      ACL_busy nil)
    ipcKillProcess(proc))
  ACL_acpSystemPromptSent = savedSysSent
  ACL_acpResumeId = savedResume
  ACL_acpInflightPromptId = savedInflight
  ACL_acpInflightPromptCount = 0
  ACL_acpPendingTurns = savedPending
  ACL_enableRawLog = savedRaw
  ACL_proc = savedProc
  ACL_sessionLogDir = savedLogDir
  ACL_sessionId = savedSid
  ACL_acpSessionStarted = savedStarted
  ACL_acpAuthMethods = savedAuth
  ACL_acpAgentCaps = savedCaps
  ACL_acpInitialized = savedInit)

printf("\n--- ACP tool-name normalization ---\n")
; The agent's exposed tool name might be `allegro_execute`,
; `mcp__allegro__allegro_execute`, `<server>_allegro_execute`, etc.
; ACL_acpAllegroTailRe extracts the bare `allegro_<verb>` suffix.
foreach(pair '(("allegro_execute"                  "allegro_execute")
               ("mcp__allegro__allegro_execute"    "allegro_execute")
               ("allegro_allegro_execute"          "allegro_execute")
               ("mcp__allegro__.allegro_execute"   "allegro_execute")
               ("weird_prefix_allegro_read_file"   "allegro_read_file")
               ("allegro_multi_edit_file"          "allegro_multi_edit_file")
               ("nothing-allegro-here"             nil))
  letseq(((input car(pair))
          (want cadr(pair))
          (got when(pcreMatchp(ACL_acpAllegroTailRe input)
            pcreSubstitute(ACL_acpAllegroTailRe "\\1"))))
    ACL_check(strcat("normalize: " input)
      got want)))

printf("\n--- ACP session/{fork,load,new} dispatch ---\n")
let(((savedProc ACL_proc)
     (savedRaw ACL_enableRawLog)
     (savedCaps ACL_acpAgentCaps)
     (savedResume ACL_acpResumeId)
     (savedFork ACL_acpResumeIsFork)
     (savedSent ACL_acpSystemPromptSent)
     (savedNextId ACL_acpNextRpcId)
     (savedHome ACL_homeDir)
     (savedLogContent ACL_logContent)
     (savedUnflushed ACL_logUnflushed)
     (proc ipcBeginProcess(if(ACL_isWindows "cmd /c more" "cat") "")))
  when(proc
    ACL_proc = proc
    ACL_enableRawLog = nil
    ACL_acpSystemPromptSent = t  ; skip prompt-prepend wire shape
    ; Capture the first wire write by intercepting the helper's
    ; raw-log mirror -- enableRawLog already nil, so we tap the
    ; proc-write path indirectly by re-checking ACL_acpNextRpcId
    ; and the in-flight state instead.
    ; --- fork path: caps advertise sessionCapabilities.fork ---
    ACL_acpAgentCaps = list(list("loadSession" t)
                            list("sessionCapabilities"
                              list(list("fork" t)
                                   list("resume" t))))
    ACL_acpResumeId = "parent-sid"
    ACL_acpResumeIsFork = t
    ACL_acpNextRpcId = 0
    ACL_acpIssueSession()
    ACL_check("dispatch: fork allocates an rpc id"
      ACL_acpNextRpcId 1)
    ; --- load path: fork cap missing, loadSession present ---
    ACL_acpAgentCaps = list(list("loadSession" t)
                            list("sessionCapabilities"
                              list(list("resume" t))))
    ACL_acpResumeId = "parent-sid"
    ACL_acpResumeIsFork = t      ; agent doesn't support fork, falls to load
    ACL_acpNextRpcId = 0
    ACL_acpIssueSession()
    ACL_check("dispatch: load allocates an rpc id"
      ACL_acpNextRpcId 1)
    ; --- new path: no fork, no load, resumeId DROPPED via dropStaleSession ---
    ACL_acpAgentCaps = list()
    ACL_acpResumeId = "parent-sid"
    ACL_acpResumeIsFork = nil
    ACL_acpNextRpcId = 0
    ; dropStaleSession appends a chat note; mute by stubbing logDir
    letseq(((savedSidFile ACL_sessionsFile))
      ACL_sessionsFile = strcat(ACL_homeDir "acp_dispatch_test.json")
      errset(deleteFile(ACL_sessionsFile))
      ACL_acpIssueSession()
      errset(deleteFile(ACL_sessionsFile))
      ACL_sessionsFile = savedSidFile)
    ACL_check("dispatch: fallback path resets resumeId" ACL_acpResumeId nil)
    ACL_check("dispatch: fallback path still allocates an rpc id"
      ACL_acpNextRpcId 1)
    ipcKillProcess(proc))
  ACL_logUnflushed = savedUnflushed
  ACL_logContent = savedLogContent
  ACL_acpNextRpcId = savedNextId
  ACL_acpSystemPromptSent = savedSent
  ACL_acpResumeIsFork = savedFork
  ACL_acpResumeId = savedResume
  ACL_acpAgentCaps = savedCaps
  ACL_enableRawLog = savedRaw
  ACL_proc = savedProc)

printf("\n--- ACP server-initiated requests ---\n")
let(((savedProc ACL_proc)
     (savedRaw ACL_enableRawLog)
     (proc ipcBeginProcess(if(ACL_isWindows "cmd /c more" "cat") "")))
  when(proc
    ACL_proc = proc
    ACL_enableRawLog = nil
    ; session/request_permission: pick allow_once when present.
    ACL_acpHandleRequest(11 "session/request_permission"
      list(list("toolCall" list(list("toolCallId" "tc1")
                                list("options" list(
                                  list(list("optionId" "deny")
                                       list("name" "Deny")
                                       list("kind" "reject_once"))
                                  list(list("optionId" "ok")
                                       list("name" "Allow Once")
                                       list("kind" "allow_once"))))))))
    ; Spec also supports top-level options[] -- exercise that path.
    ACL_acpHandleRequest(12 "session/request_permission"
      list(list("options" list(
                 list(list("optionId" "first")
                      list("name" "First option")
                      list("kind" "reject_always"))
                 list(list("optionId" "second")
                      list("name" "Second")
                      list("kind" "reject_once"))))))
    ; fs/read_text_file: serve the file via toolReadFileLines.
    letseq(((tmp strcat(ACL_homeDir "acp_fs_read_test.txt")))
      ACL_writeFile(tmp "line one\nline two\nline three\n")
      ACL_acpHandleRequest(13 "fs/read_text_file" list(list("path" tmp)))
      ACL_acpHandleRequest(14 "fs/read_text_file"
        list(list("path" strcat(ACL_homeDir "no_such_file_acp.txt"))))
      errset(deleteFile(tmp)))
    ; Unknown method: returns -32601.
    ACL_acpHandleRequest(15 "weird/method" list())
    ; All writes go to the dummy proc; just confirm we didn't crash.
    ACL_check("requests: handlers run without error" t t)
    ipcKillProcess(proc))
  ACL_enableRawLog = savedRaw
  ACL_proc = savedProc)

printf("\n--- ACP session/update dispatch ---\n")
let(((savedLog ACL_logContent)
     (savedQueue ACL_pendingChatQueue)
     (savedUnflushed ACL_logUnflushed)
     (savedForm ACL_form)
     (savedBuf ACL_responseBuf)
     (savedGot ACL_gotText)
     (savedStreaming ACL_streamingMsgId)
     (savedStreamedLen ACL_streamedMsgLen)
     (savedTokens ACL_lastContextTokens)
     (savedWindow ACL_lastContextWindow)
     (savedCost ACL_sessionCostUsd))
  ACL_form = nil
  ACL_logContent = nil
  ACL_pendingChatQueue = nil
  ACL_logUnflushed = ""
  ACL_responseBuf = ""
  ACL_gotText = nil
  ACL_streamingMsgId = nil
  ACL_streamedMsgLen = nil
  ACL_lastContextTokens = 0
  ACL_lastContextWindow = nil
  ACL_sessionCostUsd = 0.0
  ; agent_message_chunk appends text.
  ACL_acpHandleNotification("session/update"
    list(list("update" list(
      list("sessionUpdate" "agent_message_chunk")
      list("messageId" "msg-1")
      list("content" list(list("type" "text")
                          list("text" "hello ")))))))
  ACL_acpHandleNotification("session/update"
    list(list("update" list(
      list("sessionUpdate" "agent_message_chunk")
      list("messageId" "msg-1")
      list("content" list(list("type" "text")
                          list("text" "world")))))))
  ACL_check("update: text accumulated in responseBuf"
    ACL_responseBuf "hello world")
  ACL_check("update: gotText set on first chunk"
    ACL_gotText t)
  ; usage_update populates tokens/window/cost globals.
  ACL_acpHandleNotification("session/update"
    list(list("update" list(
      list("sessionUpdate" "usage_update")
      list("used" 1234)
      list("size" 200000)
      list("cost" 0.025)))))
  ACL_check("update: usage used -> lastContextTokens"
    ACL_lastContextTokens 1234)
  ACL_check("update: usage size -> lastContextWindow"
    ACL_lastContextWindow 200000)
  ACL_check("update: usage cost -> sessionCostUsd"
    ACL_sessionCostUsd 0.025)
  ; Unknown sessionUpdate falls through silently.
  ACL_acpHandleNotification("session/update"
    list(list("update" list(list("sessionUpdate" "future_thing")))))
  ACL_check("update: unknown variant doesn't crash" t t)
  ACL_sessionCostUsd = savedCost
  ACL_lastContextWindow = savedWindow
  ACL_lastContextTokens = savedTokens
  ACL_streamedMsgLen = savedStreamedLen
  ACL_streamingMsgId = savedStreaming
  ACL_gotText = savedGot
  ACL_responseBuf = savedBuf
  ACL_form = savedForm
  ACL_logUnflushed = savedUnflushed
  ACL_pendingChatQueue = savedQueue
  ACL_logContent = savedLog)

printf("\n--- ACP auto-fallback on errBody ---\n")
let(((savedActive ACL_activeEntry) (savedPending ACL_fallbackRetryPending)
     (savedTriggers ACL_fallbackTriggers) (savedExtra ACL_extraModels)
     (savedBuiltins ACL_useBuiltinModels)
     (savedLogDir ACL_sessionLogDir)
     (savedResume ACL_acpResumeId)
     (savedStarted ACL_acpSessionStarted)
     (savedInit ACL_acpInitialized)
     primary fallback)
  ACL_useBuiltinModels = nil
  ACL_extraModels = "{
    'aprim': {'driver':'p-acp-cmd','model':'p','fallback':'aback'},
    'aback': {'driver':'b-acp-cmd','model':'b'}
  }"
  primary  = ACL_modelById("aprim")
  fallback = ACL_modelById("aback")
  ACL_sessionLogDir = nil
  ACL_acpResumeId = nil
  ACL_acpSessionStarted = t
  ACL_acpInitialized = t
  ACL_activeEntry = primary
  ACL_fallbackRetryPending = nil
  ACL_acpProcessLine(strcat(
    "{\"id\":7,\"error\":{\"code\":-32000,"
    "\"message\":\"upstream rejected \\\"role\\\":\\\"system\\\"\"}}"))
  ACL_checkTrue("acp errBody: trigger pending"
    ACL_fallbackRetryPending)
  ACL_activeEntry = primary
  ACL_fallbackRetryPending = nil
  ACL_acpProcessLine(strcat(
    "{\"id\":8,\"error\":{\"code\":-32601,\"message\":\"nope\"}}"))
  ACL_check("acp unrelated error: no retry"
    ACL_fallbackRetryPending nil)
  ACL_acpInitialized = savedInit
  ACL_acpSessionStarted = savedStarted
  ACL_acpResumeId = savedResume
  ACL_sessionLogDir = savedLogDir
  ACL_useBuiltinModels = savedBuiltins
  ACL_extraModels = savedExtra
  ACL_fallbackTriggers = savedTriggers
  ACL_fallbackRetryPending = savedPending
  ACL_activeEntry = savedActive
  ACL_logUnflushed = "")

printf("\n--- sendMessage snapshots replay payload ---\n")
; sendMessage records the last (text, isSynthetic, noQuery) so the
; fallback retry can replay it after relaunching with the new model.
let(((savedLastSent ACL_lastSent)
     (savedProc ACL_proc)
     (proc ipcBeginProcess(if(ACL_isWindows "cmd /c more" "cat") "")))
  when(proc
    ACL_proc = proc
    ACL_lastSent = nil
    ACL_sendMessage("hello world")
    ACL_check("snapshot: text" car(ACL_lastSent) "hello world")
    ACL_check("snapshot: not synthetic" cadr(ACL_lastSent) nil)
    ACL_check("snapshot: not noQuery" caddr(ACL_lastSent) nil)
    ACL_sendMessage("ambient" ?isSynthetic t ?noQuery t)
    ACL_check("snapshot: synthetic" cadr(ACL_lastSent) t)
    ACL_check("snapshot: noQuery" caddr(ACL_lastSent) t)
    ipcKillProcess(proc))
  ACL_proc = savedProc
  ACL_lastSent = savedLastSent)

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

printf("\n--- Busy-time chat queue ---\n")
let(((savedQueue ACL_pendingChatQueue) (savedLog ACL_logContent)
     (savedUnflushed ACL_logUnflushed) (savedBusy ACL_busy)
     (savedForm ACL_form))
  ACL_form = nil
  ACL_logContent = nil
  ACL_logUnflushed = ""
  ACL_pendingChatQueue = nil
  ; Idle: enqueue auto-flushes straight to log.
  ACL_busy = nil
  ACL_enqueueChatLine("idle msg")
  ACL_check("queue: idle auto-flushed" ACL_pendingChatQueue nil)
  ACL_check("queue: idle wrote You:"
    ACL_logString() "\nYou: idle msg\n")
  ; Busy: enqueue holds in queue, log unchanged.
  ACL_logContent = nil
  ACL_logUnflushed = ""
  ACL_busy = t
  ACL_enqueueChatLine("first queued")
  ACL_enqueueChatLine("second queued")
  ACL_enqueueChatLine("third queued")
  ACL_check("queue: busy logContent empty" ACL_logContent nil)
  ACL_check("queue: busy tail shows queued"
    ACL_logTail(50) "\n\nQueued: first queued\nQueued: second queued\nQueued: third queued\n")
  ; ?one flushes the oldest only.
  ACL_flushPendingChat(?one t)
  ACL_check("queue: one leaves remainder"
    ACL_pendingChatQueue '("second queued" "third queued"))
  ACL_check("queue: one wrote first"
    ACL_logString() "\nYou: first queued\n")
  ; Plain flush drains everything.
  ACL_flushPendingChat()
  ACL_check("queue: cleared after flush" ACL_pendingChatQueue nil)
  ACL_check("queue: flushed as You:"
    ACL_logString() "\nYou: first queued\n\nYou: second queued\n\nYou: third queued\n")
  ; Drop discards without writing.
  ACL_logContent = nil
  ACL_logUnflushed = ""
  ACL_enqueueChatLine("discard me")
  ACL_dropPendingChat()
  ACL_check("queue: drop clears" ACL_pendingChatQueue nil)
  ACL_check("queue: drop wrote nothing" ACL_logContent nil)
  ACL_form = savedForm
  ACL_busy = savedBusy
  ACL_logUnflushed = savedUnflushed
  ACL_logContent = savedLog
  ACL_pendingChatQueue = savedQueue)

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

printf("\n--- Agent Process (per-driver) ---\n")
; End-to-end smoke for every driver on PATH; missing tools just skip.
; Codex tests can flake because gpt-5-5 sometimes invents non-
; existent MCP methods (resources/*, update_plan) before our tool.
let(((savedFast ACL_fast)
     (savedClaudeArgs ACL_claudeArgs)
     (savedActive ACL_activeEntry))
  ACL_fast = t
  ACL_claudeArgs = strcat(
    if(ACL_nonEmpty(ACL_claudeArgs) strcat(ACL_claudeArgs " ") "")
    "--no-session-persistence")
  foreach(spec append(
      list(
        list("claude" "opus-4-7-1m"
             if(ACL_isWindows "where claude >NUL 2>&1"
               "env -u LD_LIBRARY_PATH which claude > /dev/null 2>&1"))
        list("codex"  "gpt-5-5"
             if(ACL_isWindows "where codex >NUL 2>&1"
               "env -u LD_LIBRARY_PATH which codex > /dev/null 2>&1")))
      ACL_extraTestSpecs)
    letseq(((driver car(spec))
            (modelId cadr(spec))
            (probe caddr(spec))
            (entry ACL_modelById(modelId))
            (have errset(system(probe)))
            (skip member(driver ACL_roundTripSkip)))
      cond(
        (skip
          printf("  SKIP: %s (in ACL_roundTripSkip)\n" driver))
      (and(entry have car(have) == 0)
        ; Pin to the chosen entry; never exercise auto-retry here
        ; (--no-session-persistence breaks --resume which fallback uses).
        ACL_activeEntry = entry
        ACL_streamErrorCount = 0
        ACL_codexMcpErrorCount = 0
        ; Hard-reset session state so the per-driver scan can't see
        ; cmd_*.il files from the previous driver's session dir.
        ACL_sessionId = nil
        ACL_sessionLogDir = ACL_logDir
        ACL_sessionSaved = nil
        ACL_sessionUserMsgSeen = nil
        ACL_startAgent()
        ACL_checkTrue(strcat(driver ": start")
          and(ACL_proc ipcIsAliveProcess(ACL_proc)))
        printf("  Testing SKILL execution round-trip for %s...\n" driver)
        ACL_responseBuf = ""
        ACL_gotText = nil
        ; Test acts as the "real user" so ACL_maybeSaveSession fires.
        ACL_sessionUserMsgSeen = t
        ; Stash a fresh SKILL global the model has no way to guess,
        ; then ask it to fetch the value via allegro_execute. Works
        ; in both -nograph and -graphic Allegro and doesn't depend on
        ; any design or runtime state we don't control. This single
        ; round-trip exercises: process spawn, MCP server handshake,
        ; system-prompt $MCP_ prefix substitution (wrong prefix =>
        ; the tool is uncallable), stream parsing, drain, IPC, and
        ; final-text capture.
        let(((expected sprintf(nil "ACL-PROBE-%d" stringToTime(getCurrentTime())))
             (before strlen(ACL_logString()))
             (cmdSeqBefore ACL_mcpScanMaxSeq(ACL_sessionLogDir)))
          ; Tool-availability probe: before invoking allegro_execute,
          ; confirm the model can see it in its tool list. The check
          ; both reads the model's text reply (DONE / MISSING) AND
          ; verifies a new cmd_<n>.il appeared during the probe --
          ; otherwise a model that hallucinates DONE without calling
          ; the tool would slip through.
          ACL_gotText = nil
          let(((logBefore strlen(ACL_logString())))
            ACL_sendMessage(strcat(
              "Call the allegro_execute tool with the argument "
              "{\"code\": \"42\"} and then reply with the exact word "
              "DONE. If the tool is not available, reply MISSING."))
            ; Wait for BOTH the tool call to land AND text streamed
            ; after it -- some models emit preamble before invoking
            ; the tool, so an "exit N seconds after first text" gate
            ; can race the actual DONE reply.
            letseq(((availDeadline 180)
                    (graceAfterText 12)
                    (availBaseSeq ACL_mcpScanMaxSeq(ACL_sessionLogDir))
                    (availExec nil)
                    (availExecAt nil)
                    (textAt nil)
                    (availDone nil))
              for(i 1 availDeadline
                unless(availDone
                  ACL_mcpDrainPending()
                  when(null(availExec)
                    when(ACL_mcpScanMaxSeq(ACL_sessionLogDir) > availBaseSeq
                      availExec = t
                      availExecAt = i))
                  when(and(ACL_gotText null(textAt))
                    textAt = i)
                  when(and(availExec textAt availExecAt
                           (i - max(textAt availExecAt)) > graceAfterText)
                    availDone = t)
                  ipcSleep(1))))
            let(((reply or(substring(ACL_logString() logBefore + 1) ""))
                 (cmdSeqAfter ACL_mcpScanMaxSeq(ACL_sessionLogDir)))
              ACL_checkTrue(strcat(driver ": tool advertised to model")
                and(pcreMatchp("(?i)\\bDONE\\b" reply)
                    null(pcreMatchp("(?i)\\bMISSING\\b" reply))
                    cmdSeqAfter > cmdSeqBefore))))
          ACL_runtimeProbe = expected
          ACL_responseBuf = ""
          ACL_gotText = nil
          ACL_sendMessage(strcat(
            "I set the SKILL variable `ACL_runtimeProbe` earlier. "
            "What's its current value? Use allegro_execute to look "
            "it up, then tell me the value (plain text only, no quotes)."))
          ; Wait for the tool to be called AND for a final text
          ; reply to land. graceAfterText starts ticking once BOTH
          ; have happened; the loop exits when the grace expires
          ; (the streaming reply is fully landed) or we hit the
          ; outer deadline.
          letseq(((deadline 180)
                  (graceAfterText 8)
                  (probeBaseSeq ACL_mcpScanMaxSeq(ACL_sessionLogDir))
                  (foundExec nil)
                  (execAtSec nil)
                  (textAtSec nil)
                  (done nil))
            for(i 1 deadline
              unless(done
                ; axlUIWTimerAdd doesn't fire in -nograph test mode,
                ; so the drain has to happen by hand every tick.
                ACL_mcpDrainPending()
                when(null(foundExec)
                  when(ACL_mcpScanMaxSeq(ACL_sessionLogDir) > probeBaseSeq
                    foundExec = t
                    execAtSec = i))
                when(and(ACL_gotText null(textAtSec))
                  textAtSec = i)
                ; Only declare done once we've seen the MCP call AND
                ; the grace-after-text window has closed -- the
                ; model's reply text comes after the tool fires.
                if(and(foundExec textAtSec execAtSec
                       (i - max(textAtSec execAtSec)) > graceAfterText)
                  done = t
                  ipcSleep(1))))
            ACL_check(strcat(driver ": skill exec response")
              or(ACL_gotText foundExec) t)
            ACL_check(strcat(driver ": mcp tool called") foundExec t)
            let(((tail or(substring(ACL_logString() before + 1) "")))
              ACL_checkTrue(strcat(driver ": reply contains probe value")
                and(stringp(expected)
                    ACL_nonEmpty(expected)
                    nindex(tail expected))))))
        ACL_stopAgent()
        ACL_check(strcat(driver ": stop") ACL_proc nil)
        ACL_check(strcat(driver ": no stream errors")
          ACL_streamErrorCount 0)
        ; codex-only: tool-router error lines on stderr signal
        ; model-side MCP confusion. Claude never emits them.
        when(ACL_activeDriver() == "codex"
          ACL_check(strcat(driver ": no MCP-router errors")
            ACL_codexMcpErrorCount 0)))
        (t
          printf("  SKIP: %s not in PATH\n" driver)))))
  ACL_fast = savedFast
  ACL_claudeArgs = savedClaudeArgs
  ACL_activeEntry = savedActive)

printf("\n=== Results: %d passed, %d failed ===\n\n" ACL_testPass ACL_testFail)

; Tear down the sessions-file quarantine. If something exploded mid-
; suite the temp file stays for inspection; the user's real sessions
; file is untouched either way.
errset(deleteFile(ACL_sessionsFile))
ACL_sessionsFile = ACL_testSavedSessionsFile
