# Roblox Lua Style Guide (Notes)

Condensed reference based on the [Roblox Lua Style Guide](https://roblox.github.io/lua-style-guide/).
Goal: keep Lua code at Roblox consistent, readable, and free of "magic."

## Guiding Principles

- The point of a style guide is to prevent arguments — pick one reasonable convention and stick with it.
- Optimize for reading, not writing. Code gets read far more than it gets written. Keep diffs clean.
- Avoid surprising/dangerous features (e.g. use metatables sparingly and carefully).
- Favor idiomatic Lua when it doesn't conflict with the above.

## File Structure

Order of contents in a file:

1. Optional block comment explaining why the file exists (no name/author/date — that's what VCS is for)
2. Services obtained via `GetService`
3. Module imports via `require`
4. Module-level constants
5. Module-level variables/functions
6. The object the module returns
7. `return` statement

## Requires

- All `require`s go at the top of the file (static dependencies).
- Sort requires alphabetically by module name.
- Group requires into blocks, in order: common ancestor definition → imported packages → definitions derived from packages → modules from the same project (recursively by subfolder).
- Sort blocks alphabetically by subfolder, then module name. Give shared-path requires their own block.

**Libraries** (projects exposing a stable public API):
- Internally, require public/private modules directly.
- Externally, require the library's API root, then path into public modules from there.

```lua
-- library internals
local MyLibrary = script.Parent
local MyModule = require(MyLibrary.MyModule)

-- library consumers
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MyLibrary = require(ReplicatedStorage.MyLibrary)
local MyModule = MyLibrary.MyModule
```

## Metatables

Use only for:
- Prototype-based classes
- Guarding against typos (throwing on missing keys, e.g. enum-like tables)

### Prototype-based class pattern

```lua
local MyClass = {}
MyClass.__index = MyClass

export type ClassType = typeof(setmetatable(
    {} :: { property: number },
    MyClass
))

function MyClass.new(property: number): ClassType
    local self = { property = property }
    setmetatable(self, MyClass)
    return self
end

function MyClass.addOne(self: ClassType)
    self.property += 1
end
```

Optional extras: `__tostring` for debugging, `__` prefix for quasi-private members, an `isMyClass` type-check helper.

### Guarding against typos

```lua
local MyEnum = { A = "A", B = "B", C = "C" }

setmetatable(MyEnum, {
    __index = function(self, key)
        error(string.format("%q is not a valid member of MyEnum", tostring(key)), 2)
    end,
})
```

## General Punctuation

- No semicolons.

## General Whitespace

- Indent with tabs.
- Keep lines under 100 columns (assume 4-wide tabs); prefer StyLua over Luacheck for tab accuracy.
- Wrap comments to 80 columns.
- No trailing whitespace; end files with a newline.
- No vertical alignment of `=` signs, etc.
- Use a single blank line to separate logical groups; don't open a block with a blank line.
- One statement per line; put function bodies on their own lines (including single-line `if` bodies).
- Space around operators; space after commas.
- Inline opening syntax (`{`, `then`, `do`) rather than putting them on their own line.
- Don't put a table's opening `{` on its own line — keep it on the same line as the assignment/call.

### Newlines in Long Expressions

- Prefer breaking up the expression itself over adding newlines when reasonable.
- Break tables with 2+ keys or nested subtables onto multiple lines; add a trailing comma.
- List-like tables can be grouped for meaningful clusters.
- For long argument lists / nested tables, fully expand subtables for clean diffs.
- For long boolean expressions, put the operator at the start of the continuation line.
- For long `if` conditions, indent the condition and put `then` on its own line:

```lua
if
    someReallyLongCondition
    and someOtherReallyLongCondition
    and somethingElse
then
    doSomething()
end
```

### if-then-else expressions

- Prefer `if-then-else` expressions over `x and y or z` for selecting a value (safer, clearer).
- Keep them to one line when possible; put `then`/`elseif`/`else` at the start of new indented lines when they don't fit.
- If it doesn't fit on ~3 lines, convert to a full `if` statement — unless doing so would require restructuring a much larger surrounding expression.
- Use a helper variable if the condition itself is too long.
- Use `elseif` sparingly inside `if` expressions.

## Blocks

- No parentheses around conditions in `if`/`while`/`repeat`.
- Use `do` blocks to scope a variable when useful.

## Literals

- Use double-quoted strings by default (avoids escaping apostrophes; empty strings are clearer).
- Single quotes are fine when the string itself contains double quotes.

## Tables

- Don't mix list-like and dictionary-like keys in one table.
- Iterate list-like tables with `ipairs`, dictionary-like tables with `pairs`.
- Add trailing commas in multi-line tables.

## Functions

- Keep argument counts small (ideally 1–2).
- Always use parentheses in calls, even for a single string/table argument.
- Declare named functions with `local function ...`; avoid globals and `local x = function() end`.
  - Exception: late-initialized functions assigned conditionally.
- Inside tables, use `function Table.name()` / `function Table:name()` to signal calling convention (`.` = static call, `:` = method call).

## Comments

- Wrap to 80 columns; use consecutive single-line comments for multi-line notes.
- Use block comments (`--[[ ]]`) at the top of files and before functions/objects to document intent.
- Explain *why*, not *what*.
- Avoid section-header comments — split files/functions instead, or attach section context to the first item's doc comment.

## Naming

- Spell words out fully; avoid abbreviations.
- `PascalCase` for classes, enum-like objects, and all Roblox APIs.
- `camelCase` for local variables, member values, functions.
- Acronyms inside names aren't fully capitalized (`aJsonVariable`, `MakeHttpCall`), except when representing a set like `RGB`/`XYZ` (`anRGBValue`, `GetXYZ`).
- `LOUD_SNAKE_CASE` for local constants.
- Prefix private members with `_`.
- File name should match what it exports (a module exporting `doSomething` lives in `doSomething.lua`).

## Yielding

- Never call yielding functions on the main task; wrap in `coroutine.wrap`/`delay`, or expose a Promise-like async interface.
- Unintended yielding inside a callback can cause subtle data races.

## Error Handling

- Prefer `return success, result`, a `Result` type, or an async primitive like `Promise` over throwing.
- Only throw for invalid usage (bad arguments, programmer error).
- Wrap calls to throwing functions in `pcall`, and comment on what errors are expected.

```lua
local function thisCanFail(someValue)
    assert(typeof(someValue) == "string", "someValue must be a string!")

    if success() then
        return true, "Congratulations! You won!"
    else
        return false, Error.new("ERR_BLAH", "Something horrible failed!")
    end
end
```

## General Roblox Best Practices

- Reference all services via `game:GetService` at the top of the file.
- Name imported module variables after the module itself.

---
Source: https://roblox.github.io/lua-style-guide/ (also see the companion Gotchas and Roact pages).
