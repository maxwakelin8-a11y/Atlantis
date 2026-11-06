import { EditorContent, useEditor } from '@tiptap/react'
import { useEffect, useMemo, useRef } from 'react'
import { atlantisExtensions } from './extensions'
import { DocSession } from './session'
import { bridge } from './bridge'

export function DocsEditor() {
  const extensions = useMemo(atlantisExtensions, [])
  const sessionRef = useRef<DocSession | null>(null)
  const loadingRef = useRef(false)

  const editor = useEditor({
    extensions,
    content: '',
    editorProps: { attributes: { class: 'doc-editor', spellcheck: 'true' } },
    onUpdate: ({ transaction }) => {
      if (!loadingRef.current && !transaction.getMeta('uiOnly')) bridge.changed()
    },
  })

  useEffect(() => {
    if (!editor) return
    const session = new DocSession(editor)
    sessionRef.current = session
    bridge.attach({
      load: (raw) => {
        loadingRef.current = true
        try {
          session.load(raw)
        } finally {
          loadingRef.current = false
        }
        editor.commands.focus('start')
      },
      serialize: () => session.serialize(),
      serializeWithoutShortcut: () => session.serializeWithoutShortcut(),
      hasSourceMap: () => session.hasSourceMap,
    })
  }, [editor])

  return <EditorContent editor={editor} className="doc-host" />
}
