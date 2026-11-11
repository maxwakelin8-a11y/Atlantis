// Must run before Excalidraw loads: fonts come from the app bundle, never the internet.
;(window as unknown as { EXCALIDRAW_ASSET_PATH: string }).EXCALIDRAW_ASSET_PATH = `${location.protocol}//${location.host}/`
