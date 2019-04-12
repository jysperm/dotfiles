atom.commands.add 'atom-text-editor', 'markdown:paste-as-link', ->
  selection = atom.workspace.getActiveTextEditor().getLastSelection()
  clipboardText = atom.clipboard.read()

  selection.insertText("[#{selection.getText()}](#{clipboardText})")

atom.commands.add 'atom-workspace', 'close-all-projects', ->
  atom.project.setPaths []

atom.commands.add 'atom-workspace', 'open-cloud-code-and-close-other-projects', ->
  atom.project.setPaths [
    '/Users/jysperm/LeanCloud/cloud-code'
  ]

atom.commands.add 'atom-workspace', 'open-my-meta-projects-and-close-other-projects', ->
  atom.project.setPaths [
    '/Users/jysperm/jysperm/blog'
    '/Users/jysperm/jysperm/caipai.fm'
    '/Users/jysperm/jysperm/cats-blog'
    '/Users/jysperm/jysperm/environments'
    '/Users/jysperm/jysperm/jybox.net'
    '/Users/jysperm/jysperm/passwords'
    '/Users/jysperm/jysperm/servers'
  ]
