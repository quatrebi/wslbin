-- wslbin for cmd (Clink): Tab completion for the wrappers.
-- "wslbin --init clink" fills in @EXE@ and writes this file into the Clink scripts folder.
-- A wrapper is found by its file: <folder of wslbin.exe>\<name>.exe, so wrappers made later are
-- completed without writing this file again.

local wslbin_exe = @EXE@
local wslbin_dir = wslbin_exe:match("^(.*)[\\/][^\\/]*$") or "."

-- "C:\tools\Rsync.EXE" -> "rsync"
local function command_name(word)
    local name = word:match("([^\\/]*)$") or word
    name = name:gsub("%.[Ee][Xx][Ee]$", "")
    return name:lower()
end

-- One argument for the command line of wslbin.exe: in quotes, trailing backslashes doubled so
-- that they do not escape the closing quote.
local function quote(word)
    return '"' .. word:gsub("(\\+)$", "%1%1") .. '"'
end

local generator = clink.generator(50)

function generator:generate(line_state, match_builder)
    local count = line_state:getwordcount()
    if count < 1 then
        return false
    end

    local name = command_name(line_state:getword(1))
    if name ~= "wslbin" and not os.isfile(wslbin_dir .. "\\" .. name .. ".exe") then
        return false
    end

    -- Clink breaks a word at = + ; , and brackets, and hands the last word over cut short (only up
    -- to the last path separator, or nothing at all) because it filters the matches by the rest
    -- itself. The utility sees the words as the shell does: pieces that were not separated by
    -- blanks are put back together, and the last word is taken as typed, from the line.
    local last = line_state:getwordinfo(count)
    local typed = line_state:getline():sub(last.offset, line_state:getcursor() - 1)

    local words = {}
    local pending = ""
    local glued = ""        -- what comes before the last piece in the last word, e.g. "--file="
    for i = 1, count do
        local text = (i == count) and typed or line_state:getword(i)
        if i == count then
            glued = pending
        end
        pending = pending .. text
        local delim = line_state:getwordinfo(i).delim
        if i == count or delim == "" or delim:find("^%s") then
            -- The command line goes through cmd.exe, where these characters cannot be quoted safely.
            if pending:find('[%%"^]') then
                return false
            end
            words[#words + 1] = quote(pending)
            pending = ""
        else
            pending = pending .. delim
        end
    end

    -- The last word is the one being completed. It is the empty string when the cursor follows a space.
    local command = '""' .. wslbin_exe .. '" --complete ' .. (#words - 1) .. " " .. table.concat(words, " ") .. ' 2>nul"'
    local handle = io.popen(command)
    if not handle then
        return false
    end

    local added = 0
    for line in handle:lines() do
        line = line:gsub("\r$", "")
        -- wslbin answers with whole words; Clink replaces only the last piece of the word
        if glued ~= "" and line:sub(1, #glued) == glued then
            line = line:sub(#glued + 1)
        end
        -- Two characters cannot be put into the line safely: cmd.exe expands %NAME% even inside quotes,
        -- and a " (a Linux file name may have one) would close the quotes that Clink puts around it.
        if line ~= "" and not line:find('[%%"]') then
            local last_char = line:sub(-1)
            local is_dir = (last_char == "\\" or last_char == "/")
            -- Paths, and names that hold a blank or a character that cmd.exe would act on (& | < > ( ) ^),
            -- are file matches: Clink puts them in quotes, so that cmd.exe reads them as text, and puts no
            -- blank after a directory so that the path can go on. Anything else is a word, as it is.
            local kind = "word"
            if is_dir then
                kind = "dir"
            elseif line:find("[\\/ &|<>()^]") then
                kind = "file"
            end
            match_builder:addmatch({ match = line, type = kind })
            added = added + 1
        end
    end
    handle:close()

    return added > 0
end
