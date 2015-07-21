{BufferedProcess, CompositeDisposable, Point} = require 'atom'
temp = require('temp').track()
fs = require 'fs'

lines = (data) ->
  data.split "\n"

NimExe = "nim"

NimSymbolsTypes =
  skParam: 'variable'
  skVar: 'variable'
  skLet: 'variable'
  skTemp: 'variable'
  skForVar: 'variable'
  skResult: 'variable'
  skConst: 'constant'
  skGenericParam: 'type'
  skType: 'type'
  skField: 'property'
  skProc: 'function'
  skMethod: 'method'
  skIterator: 'function'
  skConverter: 'function'
  skMacro: 'function'
  skTemplate: 'function'
  skEnumField: 'constant'

moduleToCheck = (editor) ->
  result = editor.getPath()
      
  # Included files need to be checked through the
  # file, which includes them. Unfortunately, there
  # is no way to discover this file automatically and
  # we have to resort to a clumsy work-around.
  # The user must provide a comment, indicating the
  # file which is including the current file.
  editor.scan /\#\s*included from\s+(\w+)/, (iter) ->
    result = iter.match[1]
    iter.stop()

  result

callCaas = (editor, cmd, caasCb) ->
  fileToCheck = moduleToCheck editor

  withDirty = (cb) ->
    temp.open 'nim_tmp', (err, info) ->
      cb err if err
      fs.write info.fd, editor.getText(), (err, written, str) ->
        cb err if err
        fs.close info.fd
        cb null, info.path
      
  cursor = editor.getCursorBufferPosition()
  trackArg = "--track:#{editor.getPath()},#{cursor.row+1},#{cursor.column}"

  invokeNim = (cb) ->
    results = []
    args = ["idetools", "--#{cmd}", "--listFullPaths", "--colors:off", "--verbosity:0", trackArg, fileToCheck]
    console.log "args", args
    process = new BufferedProcess
      command: NimExe
      args: args
      stderr: (data) ->
        results.push(lines(data)...)
      stdout: (data) ->
        results.push(lines(data)...)
      exit: (code) ->
        cb null, code, results

    process.onWillThrowError ({error,handle}) =>
      atom.notifications.addError "Failed to run #{NimExe}",
        detail: "#{error.message}"
        dismissable: true
      handle()
      cb error

  if editor.isModified()
    withDirty (err, path) ->
      caasCb err if err
      trackArg = "--trackDirty:#{path},#{editor.getPath()},#{cursor.row+1},#{cursor.column}"
      invokeNim caasCb
  else
    invokeNim caasCb

hasCachedResults = (editor, bufferPosition, prefix) ->
  return false if not editor.nimSuggestCache
  cachePos = editor.nimSuggestCache.pos
  return cachePos.row == bufferPosition.row and
         cachePos.column + prefix.length == bufferPosition.column

prettifyDocStr = (str) ->
  str.replace /\\x([0-9A-F]{2})/g, (match, hex) ->
        String.fromCharCode(parseInt(hex, 16))
     .replace /\`\`?([^\`]+)\`?\`/g, (match, ident) -> ident
     .replace /\\([^\\])/g, (match, escaped) -> escaped

navigateToFile = (file, line, col) ->
  # This function uses Nim coordinates
  atomLine = line - 1
  atom.workspace.open(file)
    .done (ed) ->
      pos = new Point(atomLine, col)
      ed.scrollToBufferPosition(pos, center: true)
      ed.setCursorBufferPosition(pos)
  
module.exports =
  config:
    nimExecutablePath:
      type: 'string'
      default: ''
    
    nimCheckOptions:
      type: 'string'
      default: ''

  activate: (state) ->
    console.log "Nim mode activated"
    
    atom.commands.add 'atom-text-editor',
      'nim:goto-definition': (ev) ->
        editor = @getModel()
        return if not editor
        callCaas editor, "def", (err, code, lines) ->
          return if (err or lines.length < 1)
          firstMatch = lines[0]
          datums = firstMatch.split "\t"
          return unless datums.length >= 8
          [type, symbolType, name, sig, path, line, col, docs] = datums
          navigateToFile path, line, col

    @subscriptions = new CompositeDisposable
    @subscriptions.add atom.config.observe 'language-nim.nimExecutablePath',
      (path) =>
        NimExe = path || "nim"

  deactivate: ->
    console.log "Nim mode deactivated"
    @subscriptions.dispose()

  nimLinter: ->
    grammarScopes: ['source.nim']
    scope: 'file'
    lintOnFly: false
    lint: (editor) =>
      return new Promise (resolve, reject) =>
        fileToCheck = moduleToCheck editor
        results = []
        
        handleLine = (line) ->
          match = line.match ///
            ^(.+) # path 
            \((\d+), \s (\d+)\) # line and column
            \s (Warning|Error|Hint): \s
            (.*) # message
            ///
          
          if match
            [_, path, line, col, type, msg] = match
            type = "Trace" if type == "Hint"
            line = line - 1 # convert to number
            col  = col - 1
         
            results.push
              filePath: path
              type: type
              text: msg
              range: [[line, col],[line, col]]

        process = new BufferedProcess
          command: NimExe
          args: ["check", "--listFullPaths", "--colors:off", "--verbosity:0", fileToCheck]
          stderr: (data) ->
            lines(data).forEach handleLine
          stdout: (data) ->
            lines(data).forEach handleLine
          exit: (code) ->
            return resolve [] if code == 0
            resolve results

        process.onWillThrowError ({error,handle}) ->
          atom.notifications.addError "Failed to run #{NimExe}",
            detail: "#{error.message}"
            dismissable: true
          handle()
          resolve []

  nimAutoComplete: ->
    selector: '.source.nim'
    disableForSelector: '.source.nim .comment'

    # This will take priority over the default provider, which has a priority of 0.
    # if `excludeLowerPriority` is set to true, this will suppress any providers
    # with a lower priority (i.e. The default provider will be suppressed)
    inclusionPriority: 10
    excludeLowerPriority: false
    
    # Required: Return a promise, an array of suggestions, or null.
    getSuggestions: ({editor, bufferPosition, scopeDescriptor, prefix}) ->
      console.log "PREFIX |#{prefix}|"
      if hasCachedResults(editor, bufferPosition, prefix)
        fuzzyMathingRegex = new RegExp(".*" + prefix.split("").join(".*"), "i")
        # XXX:
        # Something quite weird is going on here. If we don't create fresh
        # objects on every call to getSuggestions, the menu won't get updated
        # correctly. Since Atom used to be based on React, maybe the manu is
        # relying on somethin similar to virtual-DOM, which behaves buggy here. 
        results = []
        for sym in editor.nimSuggestCache.symbols
          if sym.text.match(fuzzyMathingRegex)
            results.push
              text: sym.text
              type: sym.type
              rightLabel: sym.rightLabel
              description: sym.description
        return results
        
      if prefix.endsWith "."
        callCaas editor, "suggest", (err, code, lines) ->
          return if err # XXX: how can we report this?
          
          symbols = for ln in lines
            datums = ln.split "\t"
            continue unless datums.length >= 8
            [type, symbolType, name, sig, path, line, col, docs] = datums
            
            # Skip the name of the owning module (e.g. system.len)
            shortName = name.substr(name.indexOf(".") + 1)
            
            # Remove the enclosing string quotes ("...")
            docs = docs.slice(1, -1) if docs[0] == '"'
            
            text: shortName
            rightLabel: sig
            type: NimSymbolsTypes[symbolType] || "tag"
            description: prettifyDocStr docs

          editor.nimSuggestCache =
            pos: bufferPosition
            symbols: symbols

      return []
        
    # (optional): called _after_ the suggestion `replacementPrefix` is replaced
    # by the suggestion `text` in the buffer
    # onDidInsertSuggestion: ({editor, triggerPosition, suggestion}) ->

    # (optional): called when your provider needs to be cleaned up. Unsubscribe
    # from things, kill any processes, etc.
    # dispose: ->

