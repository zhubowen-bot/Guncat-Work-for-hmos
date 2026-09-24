export declare namespace common {
  interface ResourceManager { getRawFileContent(path: string): Promise<Uint8Array>; }
  class UIAbilityContext { filesDir: string; cacheDir: string; resourceManager: ResourceManager; }
}
