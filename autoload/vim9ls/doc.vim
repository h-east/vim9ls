vim9script

# vim9ls - documentation, taken from Vim's own help files
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>

# Every help tag, so that a word is only looked up when it is one.  Vim
# would otherwise settle for the nearest tag it can find.
var tags: dict<bool> = {}
var tags_loaded = false

def LoadTags()
  for line in readfile($VIMRUNTIME .. '/doc/tags')
    var tab = stridx(line, "\t")
    if tab > 0
      tags[line[: tab - 1]] = true
    endif
  endfor
  tags_loaded = true
enddef

export def HasTag(tag: string): bool
  if !tags_loaded
    LoadTags()
  endif
  return tags->has_key(tag)
enddef

var cache: dict<string> = {}

# The text of the help entry "tag" points at, or an empty string.  The entry
# runs from the tag line to the next one that starts in the first column; an
# empty line ends it unless the text goes on indented after it.
export def HelpText(tag: string): string
  if !HasTag(tag)
    return ''
  endif
  if cache->has_key(tag)
    return cache[tag]
  endif
  var text = ''
  try
    execute 'silent help ' .. escape(tag, ' \|')
    var top_line = line('.')
    # A line that holds only tags belongs to the entry after it.
    if getline(top_line) =~ '^\s*\%(\*[^* \t]\+\*\s*\)\+$'
      top_line += 1
    endif
    var bottom = top_line
    while bottom < line('$') && bottom - top_line < 60
      var following = getline(bottom + 1)
      if following =~ '^=\{10,}' || following =~ '^\s*\%(\*[^* \t]\+\*\s*\)\+$'
          || (following != '' && following !~ '^\s')
        break
      endif
      if following == ''
          && (bottom + 2 > line('$') || getline(bottom + 2) !~ '^\s')
        break
      endif
      bottom += 1
    endwhile
    text = getline(top_line, bottom)
      ->map((_, l) => substitute(l, '\s*\%(\*[^* \t]\+\*\s*\)\+$', '', '')
        ->substitute('^\s\+', '', ''))
      ->join("\n")
      ->trim()
  catch
    text = ''
  finally
    silent! helpclose
  endtry
  cache[tag] = text
  return text
enddef

# The help tag for "word" as what "kind" names it: a function, an option, a
# command or a variable.  Empty when there is no such entry.
export def TagFor(word: string, kind: string): string
  var tag_name = kind ==# 'function' ? word .. '()'
    : kind ==# 'option' ? "'" .. word .. "'"
    : kind ==# 'command' ? ':' .. word
    : word
  # Only a plain name can be a command; fullcommand() would read "g:x" as
  # ":g" with an argument.
  if kind ==# 'command' && !HasTag(tag_name) && word =~ '^\h\w*$'
    var full = fullcommand(word, false)
    tag_name = full == '' ? '' : ':' .. full
  endif
  return HasTag(tag_name) ? tag_name : ''
enddef

# test/run sets this to have every :def compiled as the script is read.
if $VIM9LS_COMPILE_CHECK != ''
  defcompile
endif

# vim: ts=2 sw=0 et
