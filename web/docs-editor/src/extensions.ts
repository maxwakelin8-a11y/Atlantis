// The editor's extensions: GenOffice's set with its AI pieces removed.
import { buildExtensions } from '../vendor/genoffice/renderer/editor/extensions'

export function atlantisExtensions() {
  return buildExtensions({
    slashController: {
      onOpen: () => {},
      onUpdate: () => {},
      onKeyDown: () => false,
      onClose: () => {},
    },
    slashItems: () => [],
  })
}
