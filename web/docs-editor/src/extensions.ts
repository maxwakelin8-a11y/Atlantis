// The editor's extensions: GenOffice's set with its AI pieces removed, plus the few commands the
// Writer's toolbar needs that GenOffice doesn't define.
import { Extension } from '@tiptap/core'
import { buildExtensions } from '../vendor/genoffice/renderer/editor/extensions'

declare module '@tiptap/core' {
  interface Commands<ReturnType> {
    writerHighlight: {
      /** ==highlight== on/off (GenOffice's Highlight mark has no commands of its own). */
      toggleHighlight: () => ReturnType
    }
  }
}

const HighlightCommands = Extension.create({
  name: 'writerHighlight',
  addCommands() {
    return {
      toggleHighlight:
        () =>
        ({ commands }) =>
          commands.toggleMark('highlight'),
    }
  },
  addKeyboardShortcuts() {
    return { 'Mod-Shift-h': () => this.editor.commands.toggleHighlight() }
  },
})

export function atlantisExtensions() {
  return [
    ...buildExtensions({
      slashController: {
        onOpen: () => {},
        onUpdate: () => {},
        onKeyDown: () => false,
        onClose: () => {},
      },
      slashItems: () => [],
    }),
    HighlightCommands,
  ]
}
