vim9script

# What the scripts of a workspace folder were found to hold, kept on disk so
# that a server started again reads only the scripts that changed.  A script
# is known by its time and size.  What a folder has is dropped when it was
# saved with another key.

# By folder: {file, key, scripts: {path: {stamp, items}}, dirty}.
var folders: dict<dict<any>> = {}

def Dir(): string
  if has('win32')
    return $LOCALAPPDATA == '' ? '' : $LOCALAPPDATA .. '/vim9ls'
  endif
  return ($XDG_CACHE_HOME != '' ? $XDG_CACHE_HOME : $HOME .. '/.cache')
    .. '/vim9ls'
enddef

export def Load(folder: string, key: dict<any>)
  var dir = Dir()
  if folders->has_key(folder) || dir == ''
    return
  endif
  var file = $'{dir}/{sha256(folder)}.json'
  var scripts: dict<any> = {}
  try
    var data = json_decode(readfile(file)->join("\n"))
    if type(data) == v:t_dict && data->get('key', {}) == key
        && type(data->get('scripts', 0)) == v:t_dict
      scripts = data.scripts->filter((p, _) => filereadable(p))
    endif
  catch
  endtry
  folders[folder] = {file: file, key: key, scripts: scripts, dirty: false}
enddef

# The folder "path" is in; the paths of both are full.
def FolderOf(path: string): dict<any>
  var found = ''
  for f in keys(folders)
    if stridx(path, f) == 0 && len(f) > len(found)
      found = f
    endif
  endfor
  return found == '' ? null_dict : folders[found]
enddef

# What was found in the script at "path" when it had "stamp", or null.
export def Get(path: string, stamp: string): any
  var f = FolderOf(path)
  if f == null_dict
    return null
  endif
  var s = f.scripts->get(path, {})
  return s->get('stamp', '') == stamp ? s.items : null
enddef

export def Put(path: string, stamp: string, items: list<dict<any>>)
  var f = FolderOf(path)
  if f != null_dict
    f.scripts[path] = {stamp: stamp, items: items}
    f.dirty = true
  endif
enddef

export def Drop(path: string)
  var f = FolderOf(path)
  if f != null_dict && f.scripts->has_key(path)
    remove(f.scripts, path)
    f.dirty = true
  endif
enddef

export def Clear()
  for f in values(folders)
    f.scripts = {}
    f.dirty = true
  endfor
enddef

export def Save()
  for f in values(folders)
    if !f.dirty
      continue
    endif
    try
      mkdir(fnamemodify(f.file, ':h'), 'p')
      writefile([json_encode({key: f.key, scripts: f.scripts})], f.file)
      f.dirty = false
    catch
    endtry
  endfor
enddef

# vim: ts=2 sw=0 et
