vim9script

# vim9ls - the checker: a Vim of its own that reads a script without running
# it and reports what does not compile
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>
#
# compile.vim starts this with --stdio-channel and sends it the text of a
# script.  Nothing in the script runs: what is sourced is the script with its
# definitions only (see defs.vim), and ":defcompile" compiles its functions.
# A script it imports is read the same way first, so that the import finds
# it and does not run the file.  With util.DRYRUN set the script is read
# with ":source ++dryrun" instead.  What Vim reports comes back with the
# line it is about.  Reading the script, and the command that is meant to
# fail, carry ":silent!": an error would abort the ":def" it runs in, while
# what is reported still reaches ":redir".

import autoload './util.vim'
import autoload './parse.vim'
import autoload './defs.vim'
import autoload './selection.vim'

const DRYRUN = util.DRYRUN

var conn: channel

const SELF = expand('<sfile>:p')
# The directory of the scripts of vim9ls, which are running here.
const OWN = util.FullPath(fnamemodify(SELF, ':h'))
const RUNTIMEPATH = &runtimepath

# The buffer for "path" with "lines" as its text.  The same buffer serves
# the same path again, so that Vim sees one script sourced once more and
# lets it redefine its functions.  A script in a plugin directory has the
# plugin put on 'runtimepath', for what it imports by name, and no plugin
# checked before, so that what is found does not depend on what came first.
# An "after" directory goes last, its parent first: Vim does not import from
# an "after" directory.
def Load(path: string, lines: list<string>)
  var root = util.PluginRoot(path)
  if root == ''
    &runtimepath = RUNTIMEPATH
  elseif root =~ '[/\\]after$'
    &runtimepath = fnamemodify(root, ':h') .. ',' .. RUNTIMEPATH .. ',' .. root
  else
    &runtimepath = root .. ',' .. RUNTIMEPATH
  endif
  if bufexists(path)
    execute 'silent! keepalt buffer!' bufnr(path)
  else
    execute 'silent! keepalt edit!' fnameescape(path)
  endif
  silent! :%delete _
  setline(1, lines)
enddef

# Vim names the source of an error only when it differs from the last one;
# an error of our own, thrown away, makes sure the next one is named.
def Reset()
  var discard = ''
  redir => discard
  silent! execute 'eval NoSuchFunctionVim9ls()'
  redir END
enddef

# The file of each script read so far, with its time and size when it was
# read, and the highest script ID noted there.
var read_as: dict<string> = {}
var noted_sid = 0
# When the scripts were last looked at.
var refreshed = reltime()
const REFRESH_SECONDS = 2.0
# The script checked last changed, and was not read again for that: the next
# check looks at the scripts.
var stale = false
# The scripts last read from a document that differs from their file, to be
# read from the file before another script is checked.
var from_text: dict<bool> = {}
# The scripts this Vim loaded itself, such as $VIMRUNTIME/syntax/vim.vim,
# which Vim does not read with a dry run (E1588) and which are not to be
# read again here.
var loaded_here: dict<bool> = {}

def Stamp(file: string): string
  return getftime(file) .. ':' .. getfsize(file)
enddef

# Whether "file" is a script of vim9ls.
def Own(file: string): bool
  return strpart(file, 0, strlen(OWN)) == OWN
enddef

# The file of "info" when it is one to note, but for the one at "path".
def FileOf(info: dict<any>, path: string): string
  var file = FullPath(info.name)
  return file == path || Own(file) || !filereadable(file) ? '' : file
enddef

# Reads the script at "file" again, as it is now.
def ReadAgain(file: string)
  if DRYRUN
    silent! execute 'source ++dryrun' fnameescape(file)
  else
    ReadDefinitions(file, {})
  endif
enddef

# The file "spec" of an import in the script at "importer" names, "" when it
# is not found: relative to the script, or in an "import" directory of the
# plugin or of 'runtimepath'.
def ImportFile(importer: string, spec: string): string
  var file = ''
  if spec =~ '^\.\.\=/'
    file = fnamemodify(importer, ':h') .. '/' .. spec
  elseif spec =~ '^\%(/\|\a:[/\\]\|\~\)'
    file = expand(spec)
  else
    var root = util.PluginRoot(importer)
    var found = globpath((root == '' ? '' : root .. ',') .. RUNTIMEPATH,
      'import/' .. spec, true, true)
    file = found->empty() ? '' : found[0]
  endif
  return file != '' && filereadable(file) ? FullPath(file) : ''
enddef

const IMPORT = '^\s*\%(export\s\+\)\=import\s\+\(autoload\s\+\)\=\([''"]\)'
  .. '\(.\{-}\)\2'

# The files of the imports in "lines", the script at "path", that are not
# autoload imports.
def Imports(path: string, lines: list<string>): list<string>
  var files: list<string> = []
  for line in lines
    var m = matchlist(line, IMPORT)
    if !m->empty() && m[1] == ''
      var file = ImportFile(path, m[3])
      if file != ''
        add(files, file)
      endif
    endif
  endfor
  return files
enddef

# The files of the scripts read so far.
def ReadFiles(): dict<bool>
  var read: dict<bool> = {}
  for info in getscriptinfo()
    read[FullPath(info.name)] = true
  endfor
  return read
enddef

# "lines" of the script at "path" with every import of a script that has not
# been read made an autoload import, which reads nothing until it is used:
# the file is not to run.
def Guarded(path: string, lines: list<string>): list<string>
  var read = ReadFiles()
  return lines->mapnew((_, line) => {
    var m = matchlist(line, IMPORT)
    if m->empty() || m[1] != '' || read->has_key(ImportFile(path, m[3]))
      return line
    endif
    return substitute(line, '\<import\s\+', 'import autoload ', '')
  })
enddef

# Reads the scripts "lines", the script at "path", imports that have not been
# read, see ReadDefinitions().
def ReadImports(path: string, lines: list<string>, visiting: dict<bool>)
  var read = ReadFiles()
  for file in Imports(path, lines)
    if !read->has_key(file)
      ReadDefinitions(file, visiting)
    endif
  endfor
enddef

# Reads the script at "file" with its definitions only, under its own name,
# after what it imports, so that an import of it finds it and does not run
# the file.  "visiting" are the scripts on the way here.
def ReadDefinitions(file: string, visiting: dict<bool>)
  if visiting->has_key(file) || Own(file) || loaded_here->has_key(file)
    return
  endif
  visiting[file] = true
  var lines: list<string>
  try
    lines = readfile(file)
  catch
    return
  endtry
  lines = RenameDictFuncs(lines)
  var definitions = defs.Lines(parse.Parse(lines), lines).lines
  ReadImports(file, definitions, visiting)
  Load(file, Guarded(file, definitions))
  Source(':%source')
  read_as[file] = Stamp(file)
enddef

# Has the scripts read before that changed since then read again, but for
# the one at "path": Vim does not read a script again for an import, so the
# import would find what it was.
def Refresh(path: string)
  stale = false
  for info in getscriptinfo()
    var file = FileOf(info, path)
    if file == ''
      stale = stale || (FullPath(info.name) == path
        && read_as->get(path, Stamp(path)) != Stamp(path))
      continue
    endif
    var stamp = Stamp(file)
    if read_as->has_key(file) && read_as[file] != stamp
      ReadAgain(file)
    endif
    read_as[file] = stamp
    noted_sid = max([noted_sid, info.sid])
  endfor
  refreshed = reltime()
enddef

# Notes the scripts read since the last were noted, but for the one at
# "path".  One written since "started", the time the check started, may have
# been read before it was written, and is noted to be read again.
def NoteNew(path: string, started: number)
  while true
    var found = getscriptinfo({sid: noted_sid + 1})
    if found->empty()
      return
    endif
    noted_sid += 1
    var file = FileOf(found[0], path)
    if file != ''
      read_as[file] = getftime(file) >= started ? '' : Stamp(file)
    endif
  endwhile
enddef

# The commands defined in place of user commands, see Source().
var placeholders: list<string> = []

# The names that can be user commands in "messages" reported as invalid,
# not defined and not tried before, but for an assignment to a variable.
def UnknownCommands(messages: string): list<string>
  var names: list<string> = []
  for line in split(messages, "\n")
    var name = matchstr(line, '^E476: Invalid command: \zs\u[[:alnum:]]*\ze'
      .. '\%(!\|\s\+\%(\%([-+*/%]\|\.\.\)\==[^=~]\)\@!\|$\)')
    if name != '' && exists(':' .. name) != 2 && index(names, name) < 0
        && index(placeholders, name) < 0
      names->add(name)
    endif
  endfor
  return names
enddef

# Reads the buffer with "cmd" and returns what Vim reported.  A user command
# that is not defined is defined to do nothing and the buffer read again:
# the compilation it fails would leave the rest of its statement to be read
# as commands.
def Source(cmd: string): string
  while true
    var messages = ''
    Reset()
    redir => messages
    silent! execute cmd
    redir END
    var names = UnknownCommands(messages)
    if names->empty()
      return messages
    endif
    for name in names
      silent! execute 'command -nargs=* -bang -range' name ':'
    endfor
    placeholders += names
  endwhile
  return ''
enddef

def ForgetPlaceholders()
  for name in placeholders
    silent! execute 'delcommand' name
  endfor
  placeholders = []
enddef

# A path spelled the way the server spells them: on MS-Windows with "/".
def FullPath(path: string): string
  var full = simplify(fnamemodify(path, ':p'))
  return has('win32') ? substitute(full, '\\', '/', 'g') : full
enddef

# The line a function starts on in "path", 1-based, or 0 when it is not in
# that file or not found.  A lambda is gone once its compilation failed.
# Vim names the file with "~" for the home directory.  A method, named
# "<SNR>5_Class.Method", is not listed by ":function"; its "def" is looked
# for in the buffer, inside its class.
def StartLine(name: string, path: string): number
  var m = matchlist(name, '^<SNR>\d\+_\(\h\w*\)\.\(\h\w*\)$')
  if !empty(m)
    var inside = false
    var lnum = 0
    for line in getline(1, '$')
      lnum += 1
      if !inside
        inside = line =~ '^\s*\%(\%(export\|abstract\)\s\+\)*'
          .. '\%(class\|interface\|enum\)\s\+' .. m[1] .. '\>'
      elseif line =~ '^\s*end\%(class\|interface\|enum\)\>'
        return 0
      elseif line =~ '^\s*\%(static\s\+\)\=def\s\+' .. m[2] .. '\>'
        return lnum
      endif
    endfor
    return 0
  endif
  try
    m = matchlist(execute('verbose function ' .. name),
      'Last set from \(.*\) line \(\d\+\)')
  catch
    return 0
  endtry
  return empty(m) || FullPath(m[1]) != path ? 0 : str2nr(m[2])
enddef

# The 0-based line of an error, from the context Vim named for it and the
# line within that context.  The context is a chain like
#   script /path/file.vim[11]..function <SNR>6_Outer[1]..<lambda>3
# read from the end: a lambda adds the line it started on in the function
# around it, until a function that can be found or the script itself.
def Where(context: string, lnum: number, path: string): number
  var offset = lnum
  var elements = split(context, '\.\.')
  for i in range(len(elements) - 1, 0, -1)
    var m = matchlist(elements[i],
      '^\%(function \|script \)\=\(.\{-}\)\%(\[\(\d\+\)\]\)\=$')
    if empty(m)
      return -1
    endif
    var [name, at] = [m[1], str2nr(m[2])]
    if FullPath(name) == path
      return at + offset - 1
    endif
    if name !~ '^<lambda>'
      var start = StartLine(name, path)
      if start > 0
        return start + at + offset - 1
      endif
    endif
    offset += at
  endfor
  return -1
enddef

# The line of the document for each line of the definitions read last, see
# defs.Lines(), and how many lines the document has.  Empty when each line
# of the definitions is the line of the document.
var origin: list<number> = []
var origin_count = 0

# The line of the document for "line" of the text read: after the
# definitions comes the script level, from the line of its header.
def FromText(line: number): number
  if origin->empty() || line < 0
    return line
  endif
  return line < len(origin) ? origin[line] : line - len(origin) + origin_count
enddef

# The line of the text read for "line" of the document.
def ToText(line: number): number
  if origin->empty()
    return line
  endif
  return line >= origin_count ? line - origin_count + len(origin)
    : index(origin, line)
enddef

# The errors in what Vim reported, as {line, message}, in the order of the
# lines.
def Errors(messages: string, path: string): list<dict<any>>
  var errors: list<dict<any>> = []
  var context = ''
  var lnum = 0
  for line in split(messages, "\n")
    var m = matchlist(line,
      '^Error detected while \%(compiling\|processing\) \(.*\):$')
    if !empty(m)
      [context, lnum] = [m[1], 0]
      continue
    endif
    m = matchlist(line, '^line\s\+\(\d\+\):$')
    if !empty(m)
      lnum = str2nr(m[1])
      continue
    endif
    if line !~ '^E\d\+:'
      continue
    endif
    # The summary of a failed compilation, after the error that caused it.
    # It is only reported with ":silent!".  A line defs.vim added is no
    # command once the class it is in failed.
    if line =~ '^E1028:' || line =~ '\<_Vim9lsCheck\d'
      continue
    endif
    var at = FromText(Where(context, lnum, path))
    var error = {line: at, message: line}
    if at >= 0 && index(errors, error) < 0
      errors->add(error)
    endif
  endfor
  return sort(errors, (a, b) => a.line - b.line)
enddef

# The script ID of the script at "path", 0 when it was not read.
def ScriptId(path: string): number
  for info in getscriptinfo()
    if FullPath(info.name) == path
      return info.sid
    endif
  endfor
  return 0
enddef

# The fewest and the most arguments the function of getinfo() "info" takes,
# the most -1 when there is no limit.
def Arity(info: dict<any>): list<number>
  if info.kind == 'builtin'
    return [info.minargs, info.maxargs]
  endif
  var args: list<dict<any>> = info.args
  return [args->copy()->filter((_, a) => !a->has_key('default'))->len(),
    info->has_key('varargs') ? -1 : len(args)]
enddef

# The errors of the calls in keys that names.KeyCalls() found in the script
# at "path", looked up where the keys will find them when typed.  A
# capitalized name found nowhere may be a global function of another script
# and is left alone.
def KeyCallErrors(path: string, calls: list<any>): list<dict<any>>
  var errors: list<dict<any>> = []
  var sid = ScriptId(path)
  if calls->empty() || sid == 0
    return errors
  endif
  for c in calls
    var name = substitute(c.name, '^<SID>', '', '')
    var local = getinfo('function', $'<SNR>{sid}_{name}')
    var info = c.scope == 'global' ? {} : local
    if info->empty() && c.scope != 'sid'
      info = getinfo('function', name)
    endif
    var message = ''
    if info->empty()
      if c.scope == 'sid' || name =~ '^\l' || !local->empty()
        message = 'E117: Unknown function: ' .. c.name
      endif
    elseif c.argc >= 0
      var [least, most] = Arity(info)
      if most >= 0 && c.argc > most
        message = 'E118: Too many arguments for function: ' .. c.name
      elseif c.argc < least
        message = 'E119: Not enough arguments for function: ' .. c.name
      endif
    endif
    if message != ''
      add(errors, {line: c.line, col: c.col, end_col: c.end_col,
        message: message})
    endif
  endfor
  return errors
enddef

# "wrapped" with the declarations put back that wrap.vim made assignments,
# where Vim reports no such variable: they are in a lambda, which the parser
# does not follow.  "errors" are on the lines of "wrapped".
def Declarations(lines: list<string>, wrapped: list<string>,
    errors: list<dict<any>>): list<string>
  var out = copy(wrapped)
  for e in errors
    var i = e.line
    if i < 0 || i >= len(lines) || i >= len(wrapped)
        || e.message !~ '^\%(E476: Invalid command\|E1089: Unknown variable\):'
      continue
    endif
    if wrapped[i] =~ '\S' && wrapped[i] != lines[i]
        && lines[i] =~ '^\s*\%(export\s\+\)\=var\s'
      out[i] = lines[i]
    endif
  endfor
  return out
enddef

# Without the Dictionary, which a dry run does not make, defining
# "function s:obj.Method()" fails and leaves the body at the script level.
# Such a function is read under a name of its own.
const DICT_FUNC =
  '^\s*fu\%[nction]!\=\s\+\zs\%([gs]:\)\=\h\w*\%(\.\h\w*\)\+\ze\s*('

def RenameDictFuncs(lines: list<string>): list<string>
  return lines->mapnew((i, line) => line =~ DICT_FUNC
    ? substitute(line, DICT_FUNC, 's:Vim9lsDict' .. (i + 1), '') : line)
enddef

# How many times a script is read again for the errors after the first one
# of a function.
const MAX_ROUNDS = 20

# The lines in the body of each ":def" function and method of "lines", past
# its header.  A method of an interface and an abstract one have no body.
def Bodies(lines: list<string>): dict<bool>
  var bodies: dict<bool> = {}
  var starts: list<number> = []
  var interface = false
  for lnum in range(len(lines))
    var line = lines[lnum]
    if stridx(line, 'def') < 0 && stridx(line, 'interface') < 0
      continue
    endif
    if line =~ '^\s*\%(export\s\+\)\=interface\s'
      interface = true
    elseif line =~ '^\s*endinterface\>'
      interface = false
    elseif line =~ '^\s*enddef\>' && !starts->empty()
      for k in range(remove(starts, -1), lnum - 1)
        bodies[k] = true
      endfor
    elseif !interface
        && line =~ '^\s*\%(\%(export\|static\|public\)\s\+\)*def\s'
      add(starts, selection.StatementAt(lines, lnum)[1] + 1)
    endif
  endfor
  return bodies
enddef

# "text" with the statement from line "first" to "last" made harmless, so
# that compiling goes on after it, or an empty list when it cannot be: a
# declaration loses its value, then its type, a condition becomes a
# constant, and another statement is blanked.  "times" is how often it was
# made harmless before.
def Harmless(text: list<string>, first: number, last: number,
    times: number): list<string>
  var line = text[first]
  var indent = matchstr(line, '^\s*')
  var made = ''
  var m = matchlist(line, '^\s*\%(var\|const\|final\)\s\+'
    .. '\(\[[^]]*\]\|\h\w*\)\%(\s*:\s*\([^=]\{-}\)\)\=\s*\%(=\(.*\)\)\=$')
  if !m->empty()
    if times >= 2 || m[3] =~ '^<<'
      return []
    endif
    var type = times == 0 && m[2] != '' ? trim(m[2]) : 'any'
    made = indent .. split(trim(m[1], '[]'), ',\s*')
      ->mapnew((_, n) => 'var ' .. n .. ': ' .. type)->join(' | ')
  elseif times > 0
      || line =~ '^\s*\%(end\h*\|else\|finally\|try\|return\|def\)\>'
      || line =~ '^\s*\%(fu\%[nction]\>\|[{}]\s*$\)'
    return []
  elseif line =~ '^\s*\%(if\|elseif\)\>'
    made = indent .. matchstr(line, '^\s*\zs\a\+') .. ' true'
  elseif line =~ '^\s*while\>'
    made = indent .. 'while false'
  elseif line =~ '^\s*for\s'
    made = indent .. matchstr(line, '^\s*\zsfor\s.\{-}\s\+in\>') .. ' []'
  elseif line =~ '^\s*catch\>'
    made = indent .. 'catch'
  endif
  var out = copy(text)
  out[first] = made
  for lnum in range(first + 1, last)
    out[lnum] = ''
  endfor
  return out
enddef

# The errors of "text", the script at "path" read with "cmd", after
# "first_errors", where Vim stopped each function: the statement of each
# error is made harmless and the text read again, until none can be.
# "lines" is the document; the text has a line for each of its lines, and
# again for the script level after the header line.  An error of a call to
# a function that failed to compile is kept only when the last reading gives
# it too.
def Recover(path: string, cmd: string, text: list<string>,
    lines: list<string>, first_errors: list<dict<any>>,
    started: number): list<dict<any>>
  var count = len(lines)
  var bodies = Bodies(lines)
  var all = copy(first_errors)
  var errors = first_errors
  var current = text
  var tried: dict<number> = {}
  for _ in range(MAX_ROUNDS)
    var changed = false
    for e in errors
      # The line of the document, and how far the text has it further down.
      var lnum = e.line > count ? e.line - count - 1 : e.line
      var shift = e.line - lnum
      # A call of a function that failed compiles once that function does.
      # A line that opens the block of a lambda cannot go without its end.
      if lnum < 0 || lnum >= count || (shift == 0 && !bodies->has_key(lnum))
          || e.message =~ '^E1191:' || lines[lnum] =~ '{\s*$'
        continue
      endif
      # A statement in the block of a lambda is one of its own, though the
      # lines of the lambda go on from the one that opens it.
      var [first, last] = selection.StatementAt(lines, lnum)
      for k in range(lnum - 1, first, -1)
        if lines[k] =~ '{\s*$'
          first = k + 1
          break
        endif
      endfor
      for k in range(lnum + 1, last)
        if lines[k] =~ '^\s*}'
          last = k - 1
          break
        endif
      endfor
      first += shift
      var times = tried->get(first, 0)
      var made = Harmless(current, ToText(first), ToText(last + shift), times)
      if !made->empty()
        current = made
        tried[first] = times + 1
        changed = true
      endif
    endfor
    if !changed
      break
    endif
    Load(path, current)
    errors = Errors(Source(cmd), path)
    NoteNew(path, started)
    for e in errors
      # Vim reports a block left open at the end of the function, the
      # parser on the line that opens it.
      if index(all, e) < 0 && e.message !~ '^E\%(170\|171\|600\|1026\):'
        add(all, e)
      endif
    endfor
  endfor
  return all->filter((_, e) => e.message !~ '^E1191:' || index(errors, e) >= 0)
enddef

# "base" with "wrapped", the script level as a function, appended, and the
# command that compiles the functions when no dry run does.
def Text(base: list<string>, wrapped: any): list<string>
  var text = type(wrapped) != v:t_list ? base
    : base + ['def ScriptLevel()'] + wrapped + ['enddef']
  return DRYRUN ? text : text + ['defcompile']
enddef

# What Vim reports for "lines" as the script at "path".  "wrapped" is the
# script level of a Vim9 script as the body of a function, see wrap.vim; it
# is appended to the script, so that it is compiled along with the rest.
# An error in it is reported on the line of the script it came from.
# "definitions" are "lines" with the definitions only, see defs.vim, made
# here when empty.  Looking at every script read is slow when many were, so
# it is done when "refresh" is true, the server knowing of a change, and
# every REFRESH_SECONDS for what it does not know of.
def Check(path_arg: string, lines: list<string>, wrapped: any,
    refresh: bool, calls: list<any>,
    definitions: dict<any>): list<dict<any>>
  var path = FullPath(path_arg)
  # A script loaded here is read under another name.  The scripts of vim9ls
  # are running here, their functions cannot be defined again.  So is an
  # autoload script without a dry run: Vim refuses to define its class again.
  if Own(path) || loaded_here->has_key(path)
      || (!DRYRUN && path =~ '[/\\]autoload[/\\]')
    path ..= '.dryrun'
  endif
  var renamed = RenameDictFuncs(lines)
  var started = localtime()
  if refresh || stale || reltimefloat(reltime(refreshed)) >= REFRESH_SECONDS
    Refresh(path)
  endif
  for file in keys(from_text)
    if file != path
      remove(from_text, file)
      ReadAgain(file)
      read_as[file] = Stamp(file)
    endif
  endfor
  var base = renamed
  # The range needs the colon: ":execute" from a ":def" reads the Vim9 way.
  var cmd = ':%source ++dryrun'
  origin = []
  if !DRYRUN
    var made = definitions->empty()
      ? defs.Lines(parse.Parse(lines), lines) : definitions
    var only = RenameDictFuncs(made.lines)
    ReadImports(path, only, {[path]: true})
    base = Guarded(path, only)
    cmd = ':%source'
    origin = made.origin
    origin_count = len(lines)
  endif
  var text = Text(base, wrapped)
  Load(path, text)
  var messages = Source(cmd)
  if DRYRUN && messages =~ '\<E1588:'
    loaded_here[path] = true
    path ..= '.dryrun'
    Load(path, text)
    messages = Source(cmd)
  endif
  var errors = Errors(messages, path)
  NoteNew(path, started)
  if type(wrapped) == v:t_list
    var declared = Declarations(lines, wrapped,
      errors->mapnew((_, e) => e->copy()->extend(
        {line: e.line - len(lines) - 1})))
    if declared != wrapped
      text = Text(base, declared)
      Load(path, text)
      errors = Errors(Source(cmd), path)
      NoteNew(path, started)
    endif
  endif
  if !DRYRUN && !errors->empty()
    errors = Recover(path, cmd, text, lines, errors, started)
  endif
  for e in errors
    if e.line > len(lines)
      e.line -= len(lines) + 1
    endif
  endfor
  errors += KeyCallErrors(path, calls)
  ForgetGlobalFunctions(path)
  ForgetPlaceholders()
  if filereadable(path)
    var file = readfile(path)
    if lines != file && lines != file + ['']
      from_text[path] = true
    endif
  endif
  return sort(errors, (a, b) => a.line - b.line)
enddef

# Deletes the global functions the script at "path" defined: a script checked
# later may define a class of the same name, which Vim refuses while the
# function is there.
def ForgetGlobalFunctions(path: string)
  var sid = ScriptId(path)
  if sid == 0
    return
  endif
  for name in getscriptinfo({sid: sid})[0].functions
    if name !~ '^<SNR>'
      silent! execute 'delfunction g:' .. name
    endif
  endfor
enddef

# A check that fails is answered with the error, so that the server does not
# wait for it until its time runs out.
def OnMessage(ch: channel, msg: any)
  if get(msg, 'method', '') == 'check'
    try
      ch_sendexpr(ch, {id: msg.id, result: {
        errors: Check(msg.params.path, msg.params.lines, msg.params.wrapped,
          msg.params->get('refresh', true), msg.params->get('calls', []),
          msg.params->get('definitions', {})),
      }})
    catch
      ch_sendexpr(ch, {id: msg.id, error: {code: -32603,
        message: v:exception}})
    endtry
  endif
enddef

def OnClose(_: channel)
  qall!
enddef

export def Start()
  # Nothing the script defines must run here, and nothing it reads must be
  # kept.
  set eventignore=all undolevels=-1 nomodeline
  silent! language messages C
  if !DRYRUN
    for info in getscriptinfo()
      loaded_here[FullPath(info.name)] = true
    endfor
  endif
  conn = ch_open('stdio', {mode: 'lsp', callback: OnMessage,
    close_cb: OnClose})
  if ch_status(conn) != 'open'
    cquit
  endif
enddef

if index(v:argv, '--stdio-channel') >= 0
  Start()
endif

# test/run sets this to have every :def compiled as the script is read.
if $VIM9LS_COMPILE_CHECK != ''
  defcompile
endif

# vim: ts=2 sw=0 et
