# SKILL Pitfalls

Common mistakes when writing SKILL code are included here. **Review these before emitting `<allegro_execute>` blocks.**

Your own notes are in `$ALLEGRO_CLAUDE_NOTES/LESSONS.md` and are copied below. Update the file without prompting as you learn new unituitive behaviors about SKILL and Allegro.

## `index` vs `nindex`
`index(str sub)` returns the **remainder string** starting at the match. `nindex(str sub)` returns the **integer position** (1-based). If you need a position for arithmetic or `substring`, use `nindex`.

## `getchar` returns a symbol, not an integer
`getchar("abc" 2)` returns the symbol `b`, not the integer 98. Comparisons like `getchar(str n) == 34` will always be nil. Use `substring(str n 1) == "\""` for character comparisons.

## `substring` argument parsing
`substring(str start len)` takes 2 or 3 arguments. But `substring(str pos + 1)` is parsed as **3 arguments**: `str`, `pos`, and `+1`. SKILL's infix arithmetic in function arguments is ambiguous. **Always parenthesize arithmetic**: `substring(str (pos + 1))`.

## `substring` returns nil past end of string
`substring(str pos)` returns nil if `pos > strlen(str)`. Guard with `and(rest strlen(rest) > 0)` or check for nil before calling `strlen`.

## `nindex` rejects nil arguments
`nindex(str nil)` errors. If `substring` might return nil, guard before passing to `nindex`: `and(c nindex("chars" c))`.

## `prog` vs `let` return values
`let` returns the value of its last expression. `prog` always returns nil unless `return(value)` is called. If you need early exit (via `return`), you must use `prog` -- but then you must also `return(value)` for the normal exit path.

## `return` only works inside `prog`
`return(value)` can only be used lexically inside a `prog` block. It does NOT work inside `let`, `when`, or standalone `cond`. A `return` inside a nested `let` within a `prog` WILL work -- it exits the nearest enclosing `prog`.

## `pcreCompile` options are integers, not strings
`pcreCompile("pattern" "i")` is wrong. Use `pcreCompile("pattern" pcreGenCompileOptBits(?caseLess t))` or the integer constant `0x00000001`.

## `cons` requires a list as the second argument
`cons(value 5)` errors -- the second argument must be a list. Use `list(value 5)` for a two-element list, or `cons(value nil)` for a one-element list.

## Form file POPUP syntax
The BNF notation `POPUP <<name>> {"display","dispatch"}` is misleading. The actual syntax uses angle brackets around the name, no spaces between display/dispatch, and a period terminator:
```
POPUP <NAME>"Display1""dispatch1","Display2""dispatch2".
```
Reference with `POP "NAME"` (quoted, matching the `<NAME>`). See `/opt/cadence/SPB251/share/pcb/examples/skill/form/basic/axlform.form` for working examples.

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
