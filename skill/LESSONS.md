# Arc segment API

## axlPathArcCenter creates a true arc segment, but the endpoint AND center MUST be exactly equidistant from the start
If the center isn't equidistant from start and end (within Allegro's accuracy tolerance), the arc silently degrades to a straight-line segment — segment will exist on the net, but `seg->arcCenter` and `seg->arcRadius` will be nil and `seg->objType` will be `"line"` instead of `"arc"`. Compute the perpendicular bisector center carefully. Verify after creation by reading `seg->objType` (looking for `"arc"`) or `seg->xy` (the arc center).

## Arc path segments use `xy` for center, `radius` for radius, `isClockwise` for direction
Despite the function being called axlPath**Arc**Center, the resulting segment's center is read via `seg->xy` not `seg->arcCenter`. Other arc properties: `seg->radius`, `seg->isClockwise`, `seg->isCircle`, `seg->objType == "arc"`.

## Arc bow direction follows from center side AND clockwise flag — easy to get backwards
For an arc from p1 to p2 with center C, the SHORT (minor) arc passes through the apex on the OPPOSITE side of the chord from C. To make the arc bow toward direction D from the chord, place center C in direction -D from the chord midpoint. Then to actually trace the minor arc:
- If center is "above" chord (north) and you're going west→east: use **CCW** (g_clockwise=nil) — minor arc bows south
- If center is "above" chord and you're going east→west: use **CW** (g_clockwise=t) — minor arc bows south
- General rule: CW vs CCW depends on which endpoint is "first" relative to center; trial-and-error after computing center is fastest.

Verify by reading back `seg->bBox` after creation: if the apex bbox is on the wrong side, flip the g_clockwise flag and retry.

# Routing strategies

## Use Allegro's interactive `add connect` engine when DRC-clean diff pair routing matters
Programmatic SKILL routing is good for: completing simple stubs, mirroring partner geometry mostly-correctly, bridging gaps in mostly-routed nets. For DRC-clean diff pair routing across a complex board, use `add connect` interactively — it knows about gather, swap, gap maintenance, length matching, and pad keepouts.

## When connecting across two component layers at the same XY, you need a fanout
Two SMD components on opposite layers can have a pin at exactly the same (x, y) but on different copper layers. They're not electrically connected — you need:
- A short trace fanning OUT to free space on the source layer
- A through via at the fanout endpoint
- A trace coming back IN on the destination layer
The fanout direction must avoid neighboring component pads. Check `comp->symbol->layer` for the layer (TOP / BOTTOM) — the design symbol layer tells you which side the SMD pads land on.

## Mirror a partner net's path as the route plan, then only edit what doesn't fit
For diff pair routing where the partner is fully routed, the cleanest programmatic approach is:
1. Chain the partner's segments end-to-end starting from the partner's pin nearest your start pin
2. Generate the parallel offset path (see "parallel offset construction" below)
3. Add entry/exit stubs from your pins to the offset path (small arcs work well)
4. Address remaining DRCs by tweaking specific segments

This gets you to "geometry close enough that Allegro's interactive `slide` / `add connect replace etch` can finish it" much faster than building from scratch.

## Parallel offset construction (the math that actually works)

For each segment of the partner, generate a corresponding parallel segment offset by `gap_centerline` to one side ("right of travel" or "left of travel"):

**Line segment** from `s` to `e`:
- Travel direction: `d = (e - s) / |e - s|`
- Right perpendicular (rotate travel vector 90° CW): `n = (d.y, -d.x)`
- Offset endpoints: `s' = s + offset * n`, `e' = e + offset * n`

**Arc segment** with center `C`, radius `r`, going CCW (or CW):
- Same center, new radius
- For "P right of N traveling forward":
  - CCW arc: right of travel = outside the curve → `r' = r + offset`
  - CW arc: right of travel = inside the curve → `r' = r - offset`
- New start: `s' = C + (s - C) * (r' / r)` (project along radius vector)
- New end: `e' = C + (e - C) * (r' / r)`
- Same direction flag

When chaining the partner's segments end-to-end and a segment is found in reverse direction, **flip the cw flag** along with swapping start/end (an arc traversed backward looks CW↔CCW reversed).

If you do this correctly with proper line/arc differentiation, gap is constant along the parallel run — zero DiffPair Minimum Gap violations.

## Naively offsetting all vertices in X by a constant doesn't work
Shifting all of N's vertices by `+0.31` in X gives correct gap only where N runs vertically. Where N is diagonal, the perpendicular distance to N is `0.31 / √2 ≈ 0.22mm` — too close. Always offset perpendicular to the local segment direction.

## Treating arcs as straight-line approximations doesn't work either
If you only walk `seg->startEnd` (ignoring `seg->objType == "arc"` and `seg->xy` center), you'll lay down chord lines where N has arcs. Gap fluctuates. Always check the segment type and offset arcs as arcs.

## Serpentines on the partner = length-matching only, NOT coupled
When the partner has a serpentine wiggle, that section is intentionally uncoupled — the length adjustment lives entirely on the partner. Don't mirror the wiggle. Two strategies, in increasing order of cleanliness:

1. **Chord replacement**: replace the serpentine in N's chain with a single straight chord from its start to its end. Offset P perpendicular to that chord. Some DiffPair Min Gap violations remain (against N's bumps near the chord) — these are conventionally waived.

2. **Follow the entry/exit jogs (PREFERRED)**: A serpentine usually has short jogs on each side that bring N from its main spine direction onto the serpentine baseline. If P mirrors those entry and exit jogs, P sits exactly `gap` below the baseline. The middle of P becomes a single STRAIGHT horizontal at `baseline_y - gap`, with constant gap to N's lowest bumps. **Zero DiffPair Min Gap violations** because the high bumps are further away than the low bumps and the low bumps are exactly at gap distance.

   Construction: keep N's segs 0..k where seg k ends on the baseline. Replace segs k+1..m-1 (the wiggle) with a single straight line from seg k's end to seg m's start. Keep seg m..end (where seg m is the exit jog).

## Identify the serpentine programmatically
The serpentine is the contiguous sub-chain where N's segments oscillate in one coordinate (e.g., Y bounces between two values). Look for: many short segments, alternating arc directions, Y-coordinates returning to the same values. The first segment AFTER the serpentine resumes the trajectory of the segment BEFORE it — confirm by checking that seg `m`'s direction continues seg `k-1`'s direction.

## Iterate DRC count to know if you're winning
Track DRC count after each design change. With diff pair routing, the mix of DRC types is informative:
- Lots of "DiffPair Minimum Gap" → your offset construction is wrong
- Lots of "Line to Line Spacing" / "Line to Thru Via Spacing" → your trace is hitting other nets (entry/exit stub design issue)
- "Line to SMD Pin Spacing" → trace too close to a pad in the entry/exit area

DRC type breakdown points to which part of your plan needs adjustment. Don't just look at total count.

## Width matters: gap = centerline_offset - line_width
A 0.31mm centerline offset between two 0.0914mm wide traces gives 0.31 - 0.0914 = 0.219mm edge-to-edge. If the rule requires 0.2159mm edge-to-edge, you have only 0.003mm margin — any vertex-quantization or arc-mirror imprecision will fail. Use a comfortable margin, e.g. centerline 0.35mm to give 0.259mm gap edge-to-edge.

# Net topology

## A path is gone after `axlDeleteObject` but the dbid you got back stays in your variable
After deleting a path, re-querying `net->branches` shows it gone, but the dbid reference you stored returns `dbid:removed`. Don't reuse old dbids — always re-query.

## When a transaction `mark` is held but never committed, subsequent SKILL `axlDB` writes go into limbo
If you call `axlDBTransactionStart('foo)` and then forget to commit/rollback, your subsequent path creates may appear to succeed (return a dbid) but won't show up in `net->branches`. Always commit:
```
mark = axlDBTransactionStart('foo)
... do work ...
axlDBTransactionCommit(mark)
```
Or if you don't need transaction semantics, don't open one — direct `axlDBCreate*` calls auto-commit.

# SKILL Pitfalls

Common mistakes when writing SKILL code are included here. **Review these before calling `allegro_execute`.**

Your own notes are in `$ALLEGRO_CLAUDE_NOTES/LESSONS.md` and are copied below. Update the file without prompting as you learn new unituitive behaviors about SKILL and Allegro.

## `index` vs `nindex`
`index(str sub)` returns the **remainder string** starting at the match. `nindex(str sub)` returns the **integer position** (1-based). If you need a position for arithmetic or `substring`, use `nindex`.

## `getchar` returns a symbol, not an integer
`getchar("abc" 2)` returns the symbol `b`, not the integer 98. Comparisons like `getchar(str n) == 34` will always be nil. Use `substring(str n 1) == "\""` for character comparisons.

## `substring` argument parsing
`substring(str start len)` takes 2 or 3 arguments. But `substring(str pos + 1)` is parsed as **3 arguments**: `str`, `pos`, and `+1`. SKILL's infix arithmetic in function arguments is ambiguous. **Always parenthesize arithmetic**: `substring(str (pos + 1))`.

## `substring` returns nil past end of string
`substring(str pos)` returns nil if `pos > strlen(str)`. Guard with `and(rest strlen(rest) > 0)` or check for nil before calling `strlen`.

## `strlen` errors on non-strings (including nil)
`strlen(nil)`, `strlen(42)`, `strlen('foo)` all raise `*Error* strlen: argument #1 should be a string`. It does NOT silently return nil. If a value might not be a string, guard with `stringp` first: `and(stringp(s) strlen(s) > 0)`.

## `nindex` rejects nil arguments
`nindex(str nil)` errors. If `substring` might return nil, guard before passing to `nindex`: `and(c nindex("chars" c))`.

## `prog` vs `let` return values
`let` returns the value of its last expression. `prog` always returns nil unless `return(value)` is called. If you need early exit (via `return`), you must use `prog` -- but then you must also `return(value)` for the normal exit path.

## `letseq` is SKILL's `let*` -- inter-binding deps need it
`let(((a 1) (b a + 1)) ...)` errors with `unbound variable - a`: `let` binds in parallel, so `b`'s init expression evaluates in the surrounding scope and can't see `a`. Use `letseq(((a 1) (b a + 1)) ...)` for sequential bindings. Same shape as `let`, just allows each init to reference earlier bindings.

## `return` only works inside `prog`
`return(value)` can only be used lexically inside a `prog` block. It does NOT work inside `let`, `when`, or standalone `cond`. A `return` inside a nested `let` within a `prog` WILL work -- it exits the nearest enclosing `prog`.

## `pcreCompile` options are integers, not strings
`pcreCompile("pattern" "i")` is wrong. Use `pcreCompile("pattern" pcreGenCompileOptBits(?caseLess t))` or the integer constant `0x00000001`.

## `pcreReplace` interprets backslashes in the replacement string
The replacement string passed to `pcreReplace` goes through PCRE's own escape processing -- `"\\"` (one literal backslash in the SKILL string) becomes empty in the output, and `"\\1"` is a backreference to capture group 1. To put a literal backslash in the replacement, write `"\\\\"` in SKILL source (two backslashes in the string, which PCRE then collapses to one). To preserve the entire match without replacement, use `"$0"`. Same gotcha applies to `pcreSubstitute`.

## Quadratic strcat accumulators -- use cons + reverse + buildString
Building a string by `out = strcat(out chunk)` in a loop is O(n^2) on output size (PROMPT.md / journal contents / API responses can hit this). The idiomatic linear pattern: `cons` each chunk onto a list, `reverse` it, then `buildString(list "")`.

## `cons` requires a list as the second argument
`cons(value 5)` errors -- the second argument must be a list. Use `list(value 5)` for a two-element list, or `cons(value nil)` for a one-element list.

## Form file POPUP syntax
The BNF notation `POPUP <<name>> {"display","dispatch"}` is misleading. The actual syntax uses angle brackets around the name, no spaces between display/dispatch, and a period terminator:
```
POPUP <NAME>"Display1""dispatch1","Display2""dispatch2".
```
Reference with `POP "NAME"` (quoted, matching the `<NAME>`). See `.../examples/skill/form/basic/axlform.form` for working examples.

## Form file TEXT blocks need ENDTEXT
Every `TEXT` block must end with `ENDTEXT`, even if it has no options.

## Form file FSIZE placement
In field definitions, `FSIZE` must appear AFTER the field type keyword (`STRFILLIN`, `ENUMSET`, etc.), not before it.

## `getCurrentTime` returns a string, not an integer
`getCurrentTime()` returns `"Apr 17 09:08:41 2026"`. For an integer time value (for arithmetic), use `stringToTime(getCurrentTime())`. Or use `fileTimeModified(path)` which returns an integer directly.

## Cadence `LD_LIBRARY_PATH` conflicts with system binaries
Cadence sets `LD_LIBRARY_PATH` to its own bundled glibc. Spawning system binaries (like `claude`) from within Allegro will fail with glibc version errors. Wrap with `env -u LD_LIBRARY_PATH` to strip it for the child process.

## `ipcSleep` is in seconds, not milliseconds
`ipcSleep(1)` sleeps for 1 second. It also processes IPC handlers during the sleep, making it useful for polling loops that need to wait for async data.

## `errset` vs `errsetstring`
`errset(expr)` catches errors from evaluating an expression. `errsetstring(str)` catches errors from evaluating a STRING of SKILL code. Don't pass a list to `errsetstring`. `errset` returns nil on error, or a list containing the result on success.

## `evalstring` inside IPC handlers deadlocks
`evalstring` called from inside an `ipcBeginProcess` dataHandler blocks because it needs the top-level interpreter which is busy processing the handler. Use `axlShellPost("skill myFunc()")` to defer execution to the top level.

## `axlDBGetDesign()->comps` is empty -- use `components`
`axlDBGetDesign()` has both `comps` and `components` properties. Despite the names, only `components` contains the actual component list. `comps` exists but is always empty.

## Branch children traces have objType `"path"`, not `"cline"`
When iterating `branch->children` to find routed traces, the objType is `"path"`. Despite Allegro's UI and find filter using the term "cline" (`axlSetFindFilter` keyword `"CLINES"`), the actual database object type for connect lines stored as branch children is `"path"`. Checking `child->objType == "cline"` will match nothing.

## `axlVisibleLayer` on a class turns on ALL subclasses
`axlVisibleLayer("BOARD GEOMETRY" t)` enables every subclass under BOARD GEOMETRY (OUTLINE, DXF_TOP, PLACE_GRID_TOP, TOOLING_CORNERS, etc.). To show only specific subclasses, first turn off the whole class, then enable individual subclasses: `axlVisibleLayer("BOARD GEOMETRY" nil)` then `axlVisibleLayer("BOARD GEOMETRY/OUTLINE" t)`.

## Silkscreen is a subclass, not always a class
Silkscreen data may live under `BOARD GEOMETRY/SILKSCREEN_TOP` and `PACKAGE GEOMETRY/SILKSCREEN_TOP`, not a standalone `SILKSCREEN` class. The `SILKSCREEN` class may exist but have no subclasses. Always check `axlGetParam("paramLayerGroup:SILKSCREEN")->groupMembers` and fall back to searching BOARD GEOMETRY and PACKAGE GEOMETRY subclasses for layers containing "SILK".

## Component properties differ from symbol properties
`axlDBGetDesign()->components` returns component dbids. Key properties are on the component itself (`name`, `isPlaced`, `bBox`, `package`, `class`, `deviceType`, `symbol`), NOT on sub-objects. Use `comp->??` to discover available properties. Note: `symbol` (singular) not `symbols`, `device` does not exist (use `deviceType`), `rotation`/`xy`/`isMirrored` are nil on unplaced components. The component `->symbol` dbid has its own set of properties for geometry.

## `paramLayerGroup:ETCH` is obsolete for cross-section queries
Use `axlXSectionGet(nil 'all)` instead of `axlGetParam("paramLayerGroup:ETCH")` to get layer stackup information including layer types, thicknesses, and materials. `paramLayerGroup:ETCH` still returns the list of etch layer names via `->groupMembers` but has no type information.

## `assoc` uses `eq`, not `equal` â€” symbols â‰  strings
`axlDBGetProperties` returns an assoc list with **symbol** keys, e.g., `((PACKAGE_HEIGHT_MAX "0.85 MM"))`. Using `assoc("PACKAGE_HEIGHT_MAX" props)` returns nil because the string `"PACKAGE_HEIGHT_MAX"` is not `eq` to the symbol `PACKAGE_HEIGHT_MAX`. Use `assoc('PACKAGE_HEIGHT_MAX props)` (quoted symbol) instead. This applies to all `assoc` lookups on property lists from Allegro.

## Component placement info is on `comp->symbol`, not `comp`
`isPlaced`, `isMirrored`, `xy`, `rotation`, `layer`, and `bBox` are properties of `comp->symbol` (the placed symbol instance), not of the component object itself. `comp->??` won't show these. Use `comp->symbol->isMirrored`, `comp->symbol->layer`, etc.

## `PACKAGE_HEIGHT_MAX` lives on place_bound shapes, not components
Component height is stored as a property on the PLACE_BOUND_TOP or PLACE_BOUND_BOTTOM shape child of the symbol, not on the component or symbol directly. To find it: iterate `comp->symbol->children`, find shapes on `PACKAGE GEOMETRY/PLACE_BOUND_*` layers, then call `axlDBGetProperties(child nil)` and look for `'PACKAGE_HEIGHT_MAX`.

## `axlVisibleLayer`/`axlVisibleDesign` don't reliably update the display
`axlVisibleLayer`, `axlVisibleDesign`, `axlVisibleSet`, and `axlVisibleUpdate(t)` modify internal visibility state but often fail to visually update the canvas. The reliable way to change layer visibility is to write a `.color` file and load it with `axlShellPost("colorview load myfile.color")`. The `.color` file format uses shell-style commands:
```
color -globvis off
color -vis "ETCH/TOP"
color -vis "PIN/TOP"
```
Use `color -globvis off` to turn everything off, then `color -vis "CLASS/SUBCLASS"` for each layer to enable. See examples in `c:/cadence/spb_23.1/share/pcb/toolbox/getting_started/mfgdoc/`.

## `axlVersion` takes a symbol argument, not property access
`axlVersion()` with no argument returns a list of available option symbols. To get actual values, pass the option as a symbol: `axlVersion('version)` => `25.1`, `axlVersion('fullVersion)` => `"25.1-2025 S020"`. It is NOT a property list — do not use `->` access on the result.

## `axlDBGetDesign()` property names differ from docs
The docs list `->vias`, `->branches`, `->ratTs`, `->comps`, and `->xnets` as design properties, but **these properties do not exist**. SKILL silently returns nil for nonexistent properties, making it look like an empty list. The actual property for extended nets is `->xnet` (singular, not `xnets`). `->pins` exists but is always nil. To enumerate vias or pins, use the selection API (`axlSetFindFilter`/`axlAddSelectAll`/`axlGetSelSet`). To get branches, access per-net via `net->branches`. Use `->components` not `->comps`. Use `->xnet` not `->xnets`. Use `obj->?` to discover valid properties before guessing.

## Never invoke Cadence binaries directly from a shell
Tools like `specctra`, `allegro`, etc. are normally invoked through Allegro's command shell (e.g. `axlShellPost("specctra")`) or via Cadence's launcher scripts. Running the `.../bin/...` binary directly:
- Bypasses Cadence env setup (license server discovery, CDS_INST_DIR, paths)
- Has no access to the loaded design in the running Allegro session
- Often hits glibc/library mismatches under `LD_LIBRARY_PATH` quirks
- Skips the integration that imports the routed `.ses` back into the design

If you need to drive an external Cadence tool, dispatch it as an Allegro command from the live session, not as a subprocess.

## Net pin/route topology lives nested, not flat
`net->branches->children` returns pins and (when routed) a `path` object. The `path` is a *container* — its actual segments are in `path->segments` (a list of `line`/`arc`/`via` dbids). Don't conclude a net is "unrouted" just because the immediate branch children are pins; always drill into the path's segments. A 54-segment serpentine route shows up as a single `path` child of a single `branch`.

## Rats don't tell the whole story about a net
A single ratsnest line on a net does NOT mean the net is unrouted. It means there's exactly one unconnected pin-pair. The net can be 95% routed with two stub paths and one small gap — the rat just bridges that gap. Always inspect existing `branches`/`paths` before assuming the autorouter needs to start from scratch.

## DP partner geometry is the routing template
For a diff pair where one side is routed and the other has a small gap, the right move is to read the partner net's geometry in the gap region (X/Y range, layer, width), then lay down a parallel trace at the existing DP gap distance. Don't bother with Specctra for one stub — `axlPathStart` + `axlDBCreatePath` does it in two calls.

## Watch arc endpoint orientation when joining clines
A standalone arc segment has TWO endpoints — picking the wrong one creates a slope where you wanted a straight line. Before connecting a new segment to an existing arc, check both `(car arc->startEnd)` and `(cadr arc->startEnd)` and pick the endpoint that gives the geometry you actually want. The "obvious" endpoint (e.g. the higher Y on a vertical run) may be the *outer* end of a fanout arc, not the inner end that matches your target X.

## Deleting a single merged cline segment works cleanly
`axlDBCreatePath` merges new clines with adjacent existing ones, so an "added segment" becomes part of a longer path. To remove it, find the segment dbid in `path->segments` and call `axlDeleteObject(seg)` — it removes just that segment without disturbing the rest. Don't try to delete the whole merged path and rebuild.

## `axlDBCreatePath` returns `(dbids t)` even when DRCs aren't real
The second element of the result is a "DRCs were created" flag, but it's conservative — Allegro reports `t` whenever the operation *could* have produced DRCs, not only when it actually did. Always re-query DRC count via `axlSetFindFilter` with `"DRCS"` (not `"DRCERRORS"`) to get the real count.

## To find rats, count branches — there is no "rat" objType
Branch children have objType `"pin"`, `"path"`, `"via"`, `"tee"`, or `"shape"` — never `"rat"`, `"ratsnest"`, or `"rat_t"`. Searching for those returns nothing even when the canvas clearly shows a rat. The actual signal that a net has a visible rat is `length(net->branches) > 1`: each gap in routing splits the net into another branch, with the rat spanning the gap. The find-filter keyword `"RATSNESTS"` also works via `axlAddSelectAll`, but for "is this net partially routed" the branch-count check is the direct test.

## SKILL find-filter keyword for DRCs is `"DRCS"`
Not `"DRCERRORS"`, not `"drc_errors"`. The keyword list is documented in `axlSetFindFilter.html`. When in doubt, read the table — guessing wastes a round-trip.

## `let` body that ends in a `foreach` returns nil
`let((...) foreach(... ))` evaluates to nil because `foreach` returns nil. To return a value from a `let` block that drives a loop, accumulate into a variable and reference it as the last expression: `let((acc) acc=nil foreach(... acc=cons(...)) acc)`. Same pattern for `while`.

## DB-modifying SKILL functions silently return nil when an interactive command is active
If `axlDBCreatePath`, `axlDBCreateLine`, `axlDBTransactionStart`, etc. all return nil with no error and no errset info, there is likely an interactive Allegro command in progress (e.g. `add connect` was started or a dialog is visible). SKILL DB writes are blocked until that command completes/cancels. Symptoms:
- `axlDBTransactionStart('mark)` returns nil instead of an integer mark
- `axlDBCreate*` returns nil silently (not an error)
- `errset.errset` is nil — no error captured
- `axlUIAppMode('inAppMode)` returns t

To recover: ask the user to cancel/finish the active command (F9 / `cancel` / `done` in Allegro's command window), or try `axlShellPost("cancel")` followed by `ipcSleep(1)` and re-check `axlUIAppMode('inAppMode)` is nil before retrying. The `inAppMode` flag may be sticky even after the command clears — try a small no-op create (e.g. a throwaway line on `BOARD GEOMETRY/DIMENSION`) to test whether DB writes are actually working before concluding the command is still blocking.

## drcupdate is asynchronous — wait before reading DRC counts
`axlShellPost("drcupdate")` queues the recompute but returns immediately. Querying DRC count right after returns stale (often 0) results until the recompute finishes. Always `ipcSleep(5)` or more before reading via `axlAddSelectAll` on the DRC find filter. For a large board (~1000 nets) wait 5-8 seconds. If you see suspiciously low DRC counts after a change you know created violations, sleep more and re-query.

## Coordinate accessors (xCoord, yCoord) and `:` infix don't compose well in nested contexts
SKILL's `:` infix for forming xy points fails when its operand is a function call result. E.g., `xCoord(car(shifted)):yCoord(car(shifted))` errors with "not a function". Workaround: extract scalar values to local vars first, then build with `list(x y)` not `x:y`. The colon syntax is for literal/simple expressions only.

## `when`/`if` reject chained-accessor expressions in some contexts
`when(c->net && c->net->name == "X" ...)` may parse as not-a-function. Workaround: nest `when`s, or assign the chain to a local first.

