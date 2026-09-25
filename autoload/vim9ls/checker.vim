vim9script

# vim9ls - the checker: a Vim of its own that reads a script with
# ":source ++dryrun" and reports what does not compile
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>
#
# compile.vim starts this with --stdio-channel and sends it the text of a
# script.  Nothing in the script runs: the dry run defines what the script
# defines and compiles its functions.  What Vim reports comes back with the
# line it is about.  The dry run, and the command that is meant to fail,
# carry ":silent!": an error would abort the ":def" it runs in, while what
# is reported still reaches ":redir".

var conn: channel

const SELF = expand('<sfile>:p')

# The buffer for "path" with "lines" as its text.  The same buffer serves
# the same path again, so that Vim sees one script sourced once more and
# lets it redefine its functions.  A script in a plugin directory has the
# plugin put on 'runtimepath', for what it imports by name.
def Load(path: string, lines: list<string>)
  var root = matchstr(path,
    '.*\ze[/\\]\%(autoload\|plugin\|ftplugin\|import\|syntax\|indent\)[/\\]')
  if root != '' && index(split(&runtimepath, ','), root) < 0
    &runtimepath = root .. ',' .. &runtimepath
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

# Reads the buffer with "cmd" and returns what Vim reported.
def Source(cmd: string): string
  var messages = ''
  Reset()
  redir => messages
  silent! execute cmd
  redir END
  return messages
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
    # It is only reported with ":silent!".
    if line =~ '^E1028:'
      continue
    endif
    var at = Where(context, lnum, path)
    var error = {line: at, message: line}
    if at >= 0 && index(errors, error) < 0
      errors->add(error)
    endif
  endfor
  return sort(errors, (a, b) => a.line - b.line)
enddef

# What Vim reports for "lines" as the script at "path".  "wrapped" is the
# script level of a Vim9 script as the body of a function, see wrap.vim; it
# is appended to the script, so that it is compiled along with the rest.
# An error in it is reported on the line of the script it came from.
def Check(path_arg: string, lines: list<string>, wrapped: any): list<dict<any>>
  var path = FullPath(path_arg)
  # This script is running here, its functions cannot be defined again.
  if path == FullPath(SELF)
    path ..= '.dryrun'
  endif
  var text = type(wrapped) != v:t_list ? lines
    : lines + ['def ScriptLevel()'] + wrapped + ['enddef']
  Load(path, text)
  # The range needs the colon: ":execute" from a ":def" reads the Vim9 way.
  var errors = Errors(Source(':%source ++dryrun'), path)
  for e in errors
    if e.line > len(lines)
      e.line -= len(lines) + 1
    endif
  endfor
  return sort(errors, (a, b) => a.line - b.line)
enddef

def OnMessage(ch: channel, msg: any)
  if get(msg, 'method', '') == 'check'
    ch_sendexpr(ch, {id: msg.id, result: {
      errors: Check(msg.params.path, msg.params.lines, msg.params.wrapped),
    }})
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
