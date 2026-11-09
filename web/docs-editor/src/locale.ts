// GenOffice's UI strings default to Chinese (its module-level language starts as 'zh' and is
// normally set by its Electron shell). Atlantis is English: render GenOffice's LocaleProvider once
// with 'en', which sets that module-level language for every t() call.
import { createElement } from 'react'
import { flushSync } from 'react-dom'
import { createRoot } from 'react-dom/client'
import { LocaleProvider, t } from '../vendor/genoffice/renderer/i18n/locale'

/** LocaleProvider subscribes to the Electron preload's language events; there are none here. */
export function installLocaleShim(): void {
  const w = window as unknown as { markdownApi?: { onLanguageChanged?: unknown } }
  w.markdownApi ??= {}
  w.markdownApi.onLanguageChanged ??= () => () => {}
}

export function setEnglish(): void {
  installLocaleShim()
  document.documentElement.lang = 'en'
  const root = createRoot(document.createElement('div'))
  flushSync(() => root.render(createElement(LocaleProvider, { initial: 'en', children: null })))
  root.unmount()
  if (t('placeholder') === undefined) throw new Error('GenOffice strings missing')
}
